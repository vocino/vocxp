local name, ns = ...
-- VocXP: rolling XP/hr and time-to-level in one tiny readout, plus
-- active XP bonuses. Nothing else.


VocXPDB = VocXPDB or {}
ns.db = VocXPDB

-- Chat voice shared by every Voc addon (see FAMILY.md): one line, the
-- addon name as a colored prefix, then the message.
ns.PREFIX_COLOR = "ff66ccff" -- the family color, same everywhere
function ns.say(msg)
  print("|c" .. ns.PREFIX_COLOR .. name .. "|r: " .. tostring(msg))
end

-- Confirmation sounds shared by every Voc addon (FAMILY.md "Sounds"):
-- SOUNDKIT names first, the numeric IDs behind them so a Blizzard
-- rename never silences the polish. Presence-gated: no sound API, no
-- sound, never an error.
ns.SOUNDS = {
  on = { "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 },
  off = { "IG_MAINMENU_OPTION_CHECKBOX_OFF", 857 },
  open = { "IG_MAINMENU_OPEN", 850 },
  close = { "IG_MAINMENU_CLOSE", 851 },
}
function ns.play(kind)
  local s = ns.SOUNDS[kind]
  if not s or type(PlaySound) ~= "function" then return end
  local id = type(SOUNDKIT) == "table" and SOUNDKIT[s[1]] or nil
  pcall(PlaySound, type(id) == "number" and id or s[2])
end

-- Palette (FAMILY.md "Palette"), defined once: house gold for the title
-- and frame accent, green and brick red for bonus state only, gray for
-- the missing-buff section. Nothing paints a color at a call site.
ns.COLORS = {
  gold = { 1, 0.82, 0 },
  text = { 1, 1, 1 },
  muted = { 0.5, 0.5, 0.5 },
  red = { 0.9, 0.3, 0.25 },
  green = { 0.25, 0.9, 0.35 },
}
local COLORS = ns.COLORS

-- Defaults: the single source of truth (FAMILY.md "Settings"). A key
-- holding the wrong type resets; unknown keys are left alone.
local defaults = { shown = true, locked = false, hideDefault = true, point = "BOTTOM", x = 0, y = 100 }
ns.defaults = defaults
local function opts()
  if type(ns.db) ~= "table" then ns.db = {} VocXPDB = ns.db end
  for k, v in pairs(defaults) do
    if type(ns.db[k]) ~= type(v) then ns.db[k] = v end
  end
  return ns.db
end
ns.opts = opts

local function fmt(n)
  if n >= 1e6 then return ("%.1fm"):format(n / 1e6) end
  if n >= 1e3 then return ("%.0fk"):format(n / 1e3) end
  return ("%.0f"):format(n)
end

-- Rolling estimator -------------------------------------------------
-- A trailing window over timestamped XP awards. All times are GetTime()
-- seconds: one monotonic clock, never mixed with wall time, and never
-- persisted (monotonic timestamps die with the process).

ns.WINDOW = 600 -- trailing rate window, seconds
ns.ETA_WINDOW = 900 -- ETA basis window, seconds
ns.GATE = 30 -- observation before estimates display, seconds
ns.IDLE_AFTER = 60 -- quiet span before the rate admits staleness, seconds

function ns.newTracker(t0, window)
  return { t0 = t0, window = window or ns.WINDOW, events = {}, head = 1, sum = 0 }
end

local function cutoff(tr, now)
  return math.max(tr.t0, now - tr.window)
end

-- Drop events at or before the cutoff: awards exactly at t - W have
-- expired, and an award stamped exactly at session start is a
-- zero-elapsed-time boundary event, excluded the same way.
local function prune(tr, now)
  local c = cutoff(tr, now)
  local evs = tr.events
  while tr.head <= #evs and evs[tr.head].time <= c do
    tr.sum = tr.sum - evs[tr.head].amount
    tr.head = tr.head + 1
  end
  if tr.head > 256 then ns.compact(tr) end
end

-- Drop leading dead slots; timestamps and sums untouched.
function ns.compact(tr)
  if tr.head <= 1 then return end
  local fresh = {}
  for i = tr.head, #tr.events do fresh[#fresh + 1] = tr.events[i] end
  tr.events, tr.head = fresh, 1
end

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Awards are stamped at receipt on a monotonic clock, so receipt order
-- is time order and the queue stays sorted by construction. Zero and
-- non-finite amounts are ignored, never counted.
function ns.addAward(tr, now, amount)
  if not finite(now) or not finite(amount) or amount <= 0 then return false end
  prune(tr, now)
  tr.events[#tr.events + 1] = { time = now, amount = amount }
  tr.sum = tr.sum + amount
  return true
end

-- Read path: prune even with no new awards, then report the observed
-- duration D and the in-window sum G.
local function observe(tr, now)
  prune(tr, now)
  return now - cutoff(tr, now), tr.sum
end

-- Gap since the freshest surviving in-window award, or nil when the
-- window holds nothing. Called after observe() has pruned, so the
-- last element is the most recent award.
local function lastAwardGap(tr, now)
  local evs = tr.events
  if #evs < tr.head then return nil end
  return now - evs[#evs].time
end

-- A progression snapshot is one atomic read of level, XP in level,
-- requirement, and the capped flag. Anything outside that shape is
-- rejected, never displayed as a misleading estimate.
function ns.validateSnapshot(snap)
  if type(snap) ~= "table" then return false end
  if type(snap.capped) ~= "boolean" then return false end
  if not finite(snap.level) or not finite(snap.xp) then return false end
  if snap.capped then return true end
  if not finite(snap.req) or snap.req <= 0 then return false end
  return snap.xp >= 0 and snap.xp <= snap.req
end

-- Reconstruct the XP gained between two snapshots. Same-level and
-- single-level gains are exact. A multi-level jump has unknown
-- intervening requirements, and a negative same-level delta is a
-- resync, never a negative award: both return nil and add nothing.
function ns.gain(old, new)
  if not ns.validateSnapshot(old) or not ns.validateSnapshot(new) then return nil end
  if new.capped then return nil end
  if new.level == old.level then
    if new.xp >= old.xp then return new.xp - old.xp end
    return nil
  elseif new.level == old.level + 1 then
    return math.max(0, old.req - old.xp + new.xp)
  end
  return nil
end

-- One estimate from the current window and snapshot. XP/hour is the
-- raw rolling rate whenever any time has been observed; the status
-- gates what the ETA may claim. Unknown ETAs stay null with an
-- explicit status; only a genuinely completed threshold reports zero.
function ns.estimate(tr, now, snap, paused)
  local d, g = observe(tr, now)
  local est = {
    status = nil,
    windowSeconds = tr.window,
    observedSeconds = math.max(d, 0),
    windowXp = g,
    idleSeconds = lastAwardGap(tr, now),
    xpPerHour = nil,
    remainingXp = nil,
    etaSeconds = nil,
  }
  if d > 0 then est.xpPerHour = g / d * 3600 end
  if paused then
    est.status = "paused"
    return est
  end
  if type(snap) == "table" and snap.capped then
    est.status = "capped"
    est.xpPerHour = nil
    return est
  end
  if not ns.validateSnapshot(snap) then
    est.status = "unavailable"
    return est
  end
  est.remainingXp = math.max(0, snap.req - snap.xp)
  if est.remainingXp == 0 then
    est.status = "awaiting-level-update"
    est.etaSeconds = 0
    return est
  end
  if est.observedSeconds < ns.GATE then
    est.status = "collecting"
    return est
  end
  if est.observedSeconds < tr.window then
    -- Warming up owns the partial window whatever it holds: an empty
    -- start still fills, and idleness only reads at full span.
    est.status = "warming-up"
  elseif g == 0 then
    est.status = "no-recent-xp"
    return est
  elseif est.idleSeconds ~= nil and est.idleSeconds >= ns.IDLE_AFTER then
    est.status = "idle"
  else
    est.status = "ready"
  end
  if g > 0 then est.etaSeconds = est.remainingXp * d / g end
  return est
end

-- ETA basis: the same awards over longer memory, so one-off bursts
-- don't rewrite the forecast. Only used when the rate window holds
-- earnings, so the longer sum is never empty here.
function ns.etaSeconds(etaTr, now, remainingXp)
  local d, g = observe(etaTr, now)
  if d <= 0 or g <= 0 then return nil end
  return remainingXp * d / g
end

function ns.formatObserved(d)
  local v = math.min(d, ns.WINDOW)
  if v >= 60 then return ("%dm"):format(math.floor(v / 60)) end
  return ("%ds"):format(math.floor(v))
end

function ns.titleText(est)
  if est.status == "paused" then return "Paused" end
  if est.status == "capped" then return "Max level" end
  if est.status == "unavailable" then return "Unavailable" end
  local rate = est.xpPerHour
  -- No pace exists yet on the very first paint (zero elapsed time).
  if rate == nil then return "Collecting data" end
  local head = fmt(rate) .. " XP/hr"
  if est.etaSeconds == nil then return head end
  return head .. " · " .. ns.formatEta(est.etaSeconds)
end

function ns.formatIdle(s)
  return ("%dm"):format(math.max(1, math.floor(s / 60)))
end

function ns.subText(est)
  local s = est.status
  if s == "paused" then return "Tracking paused" end
  if s == "capped" then return "Max level" end
  if s == "unavailable" then return "Waiting for XP data" end
  if s == "awaiting-level-update" then return "Level complete; awaiting update" end
  if s == "collecting" then return "Collecting data" end
  local span = ns.formatObserved(est.windowSeconds)
  if s == "no-recent-xp" then return "No XP in the last " .. span end
  if s == "warming-up" then
    return "Warming up · last " .. ns.formatObserved(est.observedSeconds) .. " of " .. span
  end
  if s == "idle" then
    return "Idle " .. ns.formatIdle(est.idleSeconds or 0) .. " · last " .. span
  end
  return "Last " .. span
end

function ns.formatEta(sec)
  if not finite(sec) then return "-" end
  if sec < 60 then return "<1m" end
  local m = math.ceil(sec / 60)
  local h = math.floor(m / 60)
  local r = m % 60
  if h == 0 then return ("%dm"):format(m) end
  if r == 0 then return ("%dh"):format(h) end
  return ("%dh%02dm"):format(h, r)
end


-- The bar. Built the way Blizzard builds its own ExpStatusBarTemplate:
-- a StatusBar wearing the native XP fill atlases, the native
-- background, prediction-atlas rested and quest overlays, and a
-- TextStatusBarText label. Fixed size: bars don't autofit.
ns.BAR_WIDTH = 320
ns.BAR_HEIGHT = 20
ns.XP_ATLAS = "UI-HUD-ExperienceBar-Fill-Experience"
ns.RESTED_ATLAS = "UI-HUD-ExperienceBar-Fill-Rested"
ns.PREDICT_ATLAS = "UI-HUD-ExperienceBar-Fill-Prediction"
ns.BG_ATLAS = "UI-HUD-ExperienceBar-Background"

local frame = CreateFrame("Frame", "VocXPFrame", UIParent)
frame:SetSize(ns.BAR_WIDTH, ns.BAR_HEIGHT)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true) -- hover tooltip always; lock gates dragging, not looking

local bar = CreateFrame("StatusBar", nil, frame)
bar:SetAllPoints(frame)
bar:SetMinMaxValues(0, 1)
bar:SetValue(0)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")

-- Atlases are Blizzard's own art. A missing atlas hides its layer
-- instead of erroring, so a client without one still shows the bar.
local function setAtlasOrHide(tex, atlas)
  if pcall(function() tex:SetAtlas(atlas) end) then return true end
  tex:Hide()
  return false
end

local bg = bar:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(bar)
setAtlasOrHide(bg, ns.BG_ATLAS)

local restFill = bar:CreateTexture(nil, "ARTWORK", nil, -1)
restFill:SetPoint("LEFT", bar, "LEFT", 0, 0)
restFill:SetPoint("TOP", bar, "TOP", 0, 0)
restFill:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
restFill:SetWidth(0)
setAtlasOrHide(restFill, ns.PREDICT_ATLAS)
restFill:Hide()

local questFill = bar:CreateTexture(nil, "ARTWORK", nil, 0)
questFill:SetPoint("TOP", bar, "TOP", 0, 0)
questFill:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
questFill:SetWidth(0)
setAtlasOrHide(questFill, ns.PREDICT_ATLAS)
questFill:Hide()

local label = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
label:SetPoint("CENTER", bar, "CENTER", 0, 0)

-- Session state. Both trackers and the baseline live here, never in
-- SavedVariables: monotonic timestamps must not cross a reload.
local rateTracker = ns.newTracker(GetTime())
local etaTracker = ns.newTracker(GetTime(), ns.ETA_WINDOW)
local baseline = nil
local identity = nil
local paused = false

local function resetTrackers()
  rateTracker = ns.newTracker(GetTime())
  etaTracker = ns.newTracker(GetTime(), ns.ETA_WINDOW)
end

local function warMode()
  return type(C_PvP) == "table"
    and type(C_PvP.IsWarModeDesired) == "function"
    and C_PvP.IsWarModeDesired()
end

-- The Enlisted buff starts at +10% but a Call to Arms for the
-- player's faction raises it, so read the live value instead of
-- hardcoding the base.
local function warModeOffered()
  local pct = 10
  if type(C_PvP) == "table" and type(C_PvP.GetWarModeRewardBonus) == "function" then
    local v = C_PvP.GetWarModeRewardBonus()
    if type(v) == "number" and v >= 1 and v <= 100 then pct = v end
  end
  return pct
end

local function warModePct()
  if not warMode() then return nil end
  return warModeOffered()
end

-- Client flavor. The client loads exactly one of our tocs (the 1.x
-- VocXP_Forever.toc on Forever, the 12.x VocXP.toc on retail), so
-- reading our own loaded Interface version back is literally asking
-- what we're loaded into. Below 20000 is our classic-lineage toc;
-- anything else keeps retail behavior, which is today's behavior
-- everywhere, including flavors we ship no toc for (those clients
-- fall back to the plain toc). An exact match on 16001 would break
-- on the next beta bump; our own toc version moves with the client
-- because we bump it with every Interface change. A missing API
-- falls back to retail, never an error. C_AddOns.GetAddOnInterfaceVersion
-- is documented on the live and forever branches.
function ns.clientFlavor()
  if type(C_AddOns) == "table"
      and type(C_AddOns.GetAddOnInterfaceVersion) == "function" then
    local v = C_AddOns.GetAddOnInterfaceVersion(name)
    if type(v) == "number" and v < 20000 then return "forever" end
  end
  return "retail"
end

local function rested()
  return GetXPExhaustion() ~= nil
end

-- Regalia of Fabled Adventurers, the heirloom set: 2 pieces cut Rested
-- consumption 30% (spell 341381), 6 pieces cut another 30% (341248),
-- 60% total. The bonuses are passive hidden auras, unreadable from
-- the aura container, so count heirloom-quality gear in the eight
-- counting slots instead; weapons and trinkets never count. Retail
-- only: heirlooms predate the set everywhere else, so the count means
-- Regalia only where the set exists (shown on retail, never Forever).
local regaliaSlots = {
  "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot",
  "ChestSlot", "LegsSlot", "Finger0Slot", "Finger1Slot",
}
local HEIRLOOM_QUALITY = 7 -- Enum.ItemQuality.Heirloom, live + forever

function ns.regaliaPieces()
  if type(C_PaperDollInfo) ~= "table"
      or type(C_PaperDollInfo.GetInventorySlotInfo) ~= "function"
      or type(GetInventoryItemQuality) ~= "function" then
    return 0
  end
  local n = 0
  for _, slotName in ipairs(regaliaSlots) do
    local slot = C_PaperDollInfo.GetInventorySlotInfo(slotName)
    if type(slot) == "number"
        and GetInventoryItemQuality("player", slot) == HEIRLOOM_QUALITY then
      n = n + 1
    end
  end
  return n
end

function ns.regaliaReduction(pieces)
  if pieces >= 6 then return 60, "6pc" end
  if pieces >= 2 then return 30, "2pc" end
  return 0, nil
end

-- Fixed-value XP-buff auras by spell ID: WHEE! (Darkmoon carousel and
-- coaster), Darkmoon Top Hat (separate aura, same +10%), Grim Visage /
-- Unburdened (Hallow's End Wickerman, one per faction).
local xpBuffs = {
  { id = 46668, label = "+10% WHEE!", pct = 10 },
  { id = 136583, label = "+10% Darkmoon Top Hat", pct = 10 },
  { id = 24705, label = "+10% Grim Visage", pct = 10 },
  { id = 95987, label = "+10% Unburdened", pct = 10 },
}

local function playerAura(spellID)
  if type(C_UnitAuras) ~= "table" then return nil end
  if type(C_UnitAuras.GetPlayerAuraBySpellID) ~= "function" then return nil end
  return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

-- Every slash toggle confirms audibly (voc-addons principle 3).
local function click(on)
  ns.play(on and "on" or "off")
end

local function hasAura(spellID) return playerAura(spellID) ~= nil end

-- Warband Mentored Leveling scales 5-25% with max-level characters;
-- the aura's first effect point carries the current value.
local MENTORED_ID = 430191
local function mentoredBonus()
  local aura = playerAura(MENTORED_ID)
  if not aura then return nil end
  local pct = aura.points and aura.points[1]
  if type(pct) == "number" and pct >= 1 and pct <= 100 then
    return ("+%d%% Warband Mentored"):format(pct), pct
  end
  return "Warband Mentored", nil
end

-- Aura reads go blind in instances (/dump-verified: the API returns
-- nil there for present world-granted buffs), so both lists gate
-- aura-derived lines on this and say so instead of false absence.
local function inInstance()
  if type(IsInInstance) ~= "function" then return false end
  local inside = IsInInstance()
  return inside == true
end

-- Highest value first; lines without a number trail in insertion
-- order, so the sort is stable. Shared by the active and missing lists.
local function sortByValue(parts)
  table.sort(parts, function(a, b)
    if (a.pct or -1) ~= (b.pct or -1) then return (a.pct or -1) > (b.pct or -1) end
    return a.seq < b.seq
  end)
end

-- Bonus lines, highest value first. Lines without a number (Rested,
-- an unreadable Mentored value) trail in their usual order; ties keep
-- insertion order, so the sort is stable.
-- The Rested line carries the live Regalia burn reduction: the set
-- multiplies Rested duration, not the XP rate, so it annotates Rested
-- instead of joining the valued list, where a 30 would read as +30% XP.
local function restedLabel()
  if ns.clientFlavor() ~= "retail" then return "Rested" end
  local reduction, tier = ns.regaliaReduction(ns.regaliaPieces())
  if reduction <= 0 then return "Rested" end
  return ("Rested · -%d%% use (Regalia %s)"):format(reduction, tier)
end

local function bonusParts()
  local parts = {}
  local function add(pct, label)
    parts[#parts + 1] = { pct = pct, label = label, seq = #parts + 1 }
  end
  local wm = warModePct()
  if wm then add(wm, ("+%d%% War Mode"):format(wm)) end
  local restricted = inInstance()
  local mentored, mentoredPct = nil, nil
  if not restricted then mentored, mentoredPct = mentoredBonus() end
  if mentored then add(mentoredPct, mentored) end
  for _, buff in ipairs(xpBuffs) do
    if not restricted and hasAura(buff.id) then add(buff.pct, buff.label) end
  end
  if rested() then add(nil, restedLabel()) end
  sortByValue(parts)
  local labels = {}
  for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
  return labels
end

-- Buffs the player could be running but isn't: each names its value
-- and a short how-to. Event buffs list
-- year-round with their season tagged; no clean event-active check
-- exists to gate them on. Buffs without a quotable value
-- (Mentored) list with no number. Darkmoon's two buffs are
-- either/or, so only WHEE! is ever recommended. On Forever only
-- Rested is recommended: War Mode, Mentored, and the event buffs
-- are unconfirmed there, so suggesting them would be guessing.
-- Detection stays ungated on every client (a lit War Mode flag or
-- a present aura is real anywhere); only these suggestions gate.
-- Regalia progress is retail-only like the event buffs (the set does
-- not exist on Forever) and teaches the next threshold once at least
-- one heirloom is worn; zero worn is no signal anything is owned, so
-- it stays quiet. Equipment reads work in instances, so no gate there.
-- Confirm more via beta /dumps and extend the gate below.
local function missingParts()
  local parts = {}
  local function add(pct, label)
    parts[#parts + 1] = { pct = pct, label = label, seq = #parts + 1 }
  end
  local forever = ns.clientFlavor() == "forever"
  if not forever and not warMode() then
    local pct = warModeOffered()
    add(pct, ("+%d%% War Mode (toggle in a capital)"):format(pct))
  end
  local restricted = inInstance()
  if not forever and not restricted and not playerAura(MENTORED_ID) then
    add(nil, "Warband Mentored (needs a max-level character)")
  end
  if not forever and not restricted and not hasAura(46668) and not hasAura(136583) then
    add(10, "+10% WHEE! (Faire week)")
  end
  if not forever and not restricted and not hasAura(24705) and not hasAura(95987) then
    add(10, "+10% Wickerman (Hallow's End)")
  end
  if not rested() then add(nil, "Rested (rest in town)") end
  if not forever then
    local pieces = ns.regaliaPieces()
    if pieces == 1 then
      add(nil, "-30% Rested use (Regalia 2pc, one more heirloom)")
    elseif pieces >= 2 and pieces < 6 then
      add(nil, ("-60%% Rested use (Regalia 6pc, %d/6 worn)"):format(pieces))
    end
  end
  if restricted and not forever then add(nil, "Aura scan unavailable in instances") end
  sortByValue(parts)
  local labels = {}
  for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
  return labels
end

-- Bar segments ---------------------------------------------------------
-- Fractions over the current level: where progress ends, how far
-- rested XP reaches, how far ready-to-turn-in quests reach. All
-- clamped to [0, 1]; overlays never start before progress. An
-- invalid or capped snapshot has no bar: nil, never zeros that
-- would paint a misleading empty bar.
function ns.barSegments(snap, restedXp, questXp)
  if not ns.validateSnapshot(snap) or snap.capped then return nil end
  local r = (type(restedXp) == "number" and restedXp > 0) and restedXp or 0
  local q = (type(questXp) == "number" and questXp > 0) and questXp or 0
  local progress = math.max(0, math.min(1, snap.xp / snap.req))
  local restedEnd = math.max(progress, math.min(1, (snap.xp + r) / snap.req))
  local questEnd = math.max(progress, math.min(1, (snap.xp + q) / snap.req))
  return {
    progress = progress,
    restedEnd = restedEnd,
    questEnd = questEnd,
    pct = progress * 100,
    restedPct = r / snap.req * 100,
    questPct = q / snap.req * 100,
  }
end

function ns.barLabel(snap, seg)
  local pct = math.floor(seg.pct + 0.5)
  return ("%d  %s/%s (%d%%)"):format(snap.level, fmt(snap.xp), fmt(snap.req), pct)
end

-- Ready-to-turn-in quest XP --------------------------------------------
-- The payout waiting at quest givers, as raw XP and a quest count.
-- GetQuestLogRewardXP reads the selected entry, so the scan saves and
-- restores the selection and never re-enters: a quest event fired
-- mid-scan re-renders on the previous total instead of recursing. A
-- missing API anywhere in the chain means no overlay, never an error.
local questXp, questCount, scanning = 0, 0, false

function ns.scanQuestXp()
  if scanning then return questXp, questCount end
  if type(C_QuestLog) ~= "table" or type(GetQuestLogRewardXP) ~= "function" then
    questXp, questCount = 0, 0
    return questXp, questCount
  end
  local QL = C_QuestLog
  if type(QL.GetNumQuestLogEntries) ~= "function"
      or type(QL.GetInfo) ~= "function"
      or type(QL.ReadyForTurnIn) ~= "function"
      or type(QL.GetSelectedQuest) ~= "function"
      or type(QL.SetSelectedQuest) ~= "function" then
    questXp, questCount = 0, 0
    return questXp, questCount
  end
  scanning = true
  local ok, total, count = pcall(function()
    local shown = QL.GetNumQuestLogEntries()
    if type(shown) ~= "number" then return 0, 0 end
    local sel = QL.GetSelectedQuest()
    local sum, n = 0, 0
    for i = 1, shown do
      local info = QL.GetInfo(i)
      if type(info) == "table" and not info.isHeader
          and type(info.questID) == "number"
          and QL.ReadyForTurnIn(info.questID) then
        QL.SetSelectedQuest(info.questID)
        local xp = GetQuestLogRewardXP()
        if type(xp) == "number" and xp > 0 then sum, n = sum + xp, n + 1 end
      end
    end
    if type(sel) == "number" and sel ~= 0 then QL.SetSelectedQuest(sel) end
    return sum, n
  end)
  scanning = false
  if ok then questXp, questCount = total, count else questXp, questCount = 0, 0 end
  return questXp, questCount
end

-- Rested XP as a number, or nil when there is none to draw. Blizzard
-- hides the rested layer while XP gain is disabled, so do we; a
-- missing API there means XP assumed enabled, never a missing bar.
local function restedAmount()
  if type(IsXPUserDisabled) == "function" and IsXPUserDisabled() then return nil end
  if type(GetXPExhaustion) ~= "function" then return nil end
  local v = GetXPExhaustion()
  if type(v) ~= "number" or v <= 0 then return nil end
  return v
end

-- The native cluster hides wholesale while ours shows: Blizzard offers
-- no per-bar switch, so watched reputation and honor hide with the XP
-- bar and the setting tooltip says so. Re-applied every refresh
-- because Edit Mode sessions may reshow it; restored the moment we
-- stop hiding, including the max-level shutdown.
local nativeHiddenByUs = false

local function applyNativeBar()
  if type(StatusTrackingBarManager) ~= "table" then return end
  local mgr = StatusTrackingBarManager
  if type(mgr.IsShown) ~= "function" or type(mgr.Hide) ~= "function"
      or type(mgr.Show) ~= "function" then return end
  local o = opts()
  local wantHidden = o.hideDefault and o.shown and not (baseline and baseline.capped)
  if wantHidden then
    if mgr:IsShown() then mgr:Hide() end
    nativeHiddenByUs = true
  elseif nativeHiddenByUs then
    mgr:Show()
    nativeHiddenByUs = false
  end
end

-- Edit Mode cooperation --------------------------------------------------
-- VocXP never joins Edit Mode (no supported API; the evidence lives in
-- .reference/api-verification.md), but an arranging session should
-- include our bar: while Edit Mode is open the bar drags even when
-- locked. Derived, never persisted: a reload mid-session restores the
-- saved lock on its own. No EventRegistry, no cooperation: dragging
-- behaves exactly as it always has.
ns.editModeActive = false

function ns.setEditModeActive(active)
  ns.editModeActive = active and true or false
end

local editSubscribed = false
function ns.subscribeEditMode()
  if editSubscribed then return end
  if type(EventRegistry) ~= "table" then return end
  if type(EventRegistry.RegisterCallback) ~= "function" then return end
  local ok = pcall(EventRegistry.RegisterCallback, EventRegistry, "EditMode.Enter",
    function() ns.setEditModeActive(true) end)
  local ok2 = pcall(EventRegistry.RegisterCallback, EventRegistry, "EditMode.Exit",
    function() ns.setEditModeActive(false) end)
  if ok and ok2 then editSubscribed = true end
end

local function draggable()
  return (not opts().locked) or ns.editModeActive
end

local function refresh()
  local o = opts()
  local now = GetTime()
  local est = ns.estimate(rateTracker, now, baseline, paused)
  if est.status == "capped" then
    frame:SetShown(false)
    applyNativeBar()
    return
  end
  -- The ETA reads the longer basis (which also prunes it); the rate
  -- window still gates whether any ETA shows at all.
  local longEta = ns.etaSeconds(etaTracker, now, est.remainingXp or 0)
  if est.etaSeconds and (est.remainingXp or 0) > 0 then
    est.etaSeconds = longEta or est.etaSeconds
  end
  local seg = ns.barSegments(baseline, restedAmount(), questXp)
  if seg then
    bar:SetValue(seg.progress)
    label:SetText(ns.barLabel(baseline, seg))
    local fill = nil
    if type(bar.GetStatusBarTexture) == "function" then fill = bar:GetStatusBarTexture() end
    if fill ~= nil then
      local atlas = seg.restedEnd > seg.progress and ns.RESTED_ATLAS or ns.XP_ATLAS
      pcall(function() fill:SetAtlas(atlas) end)
    end
    if seg.restedEnd > seg.progress then
      restFill:SetWidth(seg.restedEnd * ns.BAR_WIDTH)
      restFill:Show()
    else
      restFill:Hide()
    end
    if seg.questEnd > seg.progress then
      questFill:ClearAllPoints()
      questFill:SetPoint("LEFT", bar, "LEFT", seg.progress * ns.BAR_WIDTH, 0)
      questFill:SetPoint("TOP", bar, "TOP", 0, 0)
      questFill:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
      questFill:SetWidth((seg.questEnd - seg.progress) * ns.BAR_WIDTH)
      questFill:Show()
    else
      questFill:Hide()
    end
  end
  applyNativeBar()
  frame:SetShown(o.shown)
end

-- The tooltip carries the engine the bar replaced: the rate line, the
-- rested and quest reach, the bonus list, and the missing list. It
-- never fires mid-drag: our own drag flag guards it, which keeps the
-- promise without touching an unverified global.
local dragging = false

function ns.showTip()
  if dragging then return end
  if type(GameTooltip) ~= "table" then return end
  local est = ns.estimate(rateTracker, GetTime(), baseline, paused)
  -- The same longer ETA basis refresh() applies, so the tooltip and
  -- the bar never disagree about time-to-level.
  local longEta = ns.etaSeconds(etaTracker, GetTime(), est.remainingXp or 0)
  if est.etaSeconds and (est.remainingXp or 0) > 0 then
    est.etaSeconds = longEta or est.etaSeconds
  end
  local seg = ns.barSegments(baseline, restedAmount(), questXp)
  GameTooltip:SetOwner(frame, "ANCHOR_TOP")
  GameTooltip:ClearLines()
  GameTooltip:SetText("VocXP", COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
  GameTooltip:AddLine(ns.titleText(est), COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
  GameTooltip:AddLine(ns.subText(est), COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  if seg then
    if seg.restedEnd > seg.progress then
      local pct = math.floor(seg.restedPct + 0.5)
      GameTooltip:AddLine(("Rested: %d%% of level"):format(pct),
        COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
    end
    if questCount > 0 and seg.questEnd > seg.progress then
      local pct = math.floor(seg.questPct + 0.5)
      local noun = questCount == 1 and "quest" or "quests"
      GameTooltip:AddLine(("%d %s ready: %d%% of level"):format(questCount, noun, pct),
        COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
    end
  end
  local bonuses = bonusParts()
  if #bonuses == 0 then
    GameTooltip:AddLine("No XP bonus", COLORS.red[1], COLORS.red[2], COLORS.red[3], true)
  else
    for _, b in ipairs(bonuses) do
      GameTooltip:AddLine(b, COLORS.green[1], COLORS.green[2], COLORS.green[3], true)
    end
  end
  for _, m in ipairs(missingParts()) do
    GameTooltip:AddLine(m, COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  end
  GameTooltip:AddLine("/vxp shows or hides it. /vxp help lists the rest.",
    COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  GameTooltip:Show()
end

-- At max level the addon goes fully dormant: no ticker, no hot
-- events, and the native bar comes back. PLAYER_ENTERING_WORLD stays
-- registered as the wake path (loading screens only); a cap raise
-- restarts everything there.
local ticker
local function shutdown()
  frame:SetShown(false)
  paused = false
  if ticker then ticker:Cancel() ticker = nil end
  frame:UnregisterEvent("PLAYER_XP_UPDATE")
  frame:UnregisterEvent("PLAYER_LEVEL_UP")
  frame:UnregisterEvent("UNIT_AURA")
  frame:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
  frame:UnregisterEvent("UPDATE_EXHAUSTION")
  frame:UnregisterEvent("PLAYER_UPDATE_RESTING")
  frame:UnregisterEvent("QUEST_LOG_UPDATE")
  frame:UnregisterEvent("QUEST_TURNED_IN")
  frame:UnregisterEvent("QUEST_ACCEPTED")
  frame:UnregisterEvent("QUEST_REMOVED")
  frame:UnregisterEvent("QUEST_COMPLETE")
  applyNativeBar()
end

local function readSnapshot()
  local max = UnitXPMax("player")
  return { level = UnitLevel("player"), xp = UnitXP("player"), req = max, capped = (max == 0) }
end

-- The XP bar is the single authoritative award source: each update
-- reconstructs at most one gain from the snapshot delta and stamps it
-- with the receipt time. Actual awarded XP already includes every
-- bonus, so nothing is ever multiplied twice.
local function onXP()
  local snap = readSnapshot()
  if snap.capped then
    baseline = snap
    shutdown()
    return
  end
  if not paused then
    local gained = ns.gain(baseline, snap)
    if gained then
      local stamp = GetTime()
      ns.addAward(rateTracker, stamp, gained)
      ns.addAward(etaTracker, stamp, gained)
    end
  end
  baseline = snap
  refresh()
end

-- Blizzard Settings panel (Settings > AddOns > VocXP): the same
-- options the slash line toggles, bound to the live SavedVariables
-- table so the panel and `/vxp` always agree, applied the moment they
-- change. Built once, after SavedVariables land, and only if the
-- Settings API is present.
function ns.onSettingChanged(setting, fn)
  if setting and type(setting.SetValueChangedCallback) == "function" then
    setting:SetValueChangedCallback(fn)
  end
end

ns.settingsBuilt = false
function ns.ensureSettings()
  if ns.settingsBuilt then return end
  if type(Settings) ~= "table" then return end
  if type(Settings.RegisterVerticalLayoutCategory) ~= "function" then return end
  local category = Settings.RegisterVerticalLayoutCategory("VocXP")
  Settings.RegisterAddOnCategory(category)
  local db = opts() -- bound, defaulted table
  local function check(key, label, tooltip, onChange)
    local s = Settings.RegisterAddOnSetting(
      category, "VocXP_" .. key, key, db, type(defaults[key]), label, defaults[key])
    Settings.CreateCheckbox(category, s, tooltip)
    ns.onSettingChanged(s, onChange)
  end
  check("shown", "Show the bar",
    "Show the XP bar with XP/hr, time to level, and your active XP bonuses. Max-level characters never see it.",
    function() refresh() end)
  check("hideDefault", "Hide the default XP bar",
    "Hide Blizzard's status bar cluster while VocXP shows. Watched reputation and honor bars hide with it.",
    function() refresh() end)
  check("locked", "Lock the position",
    "Keep the bar where it is. Unlocked, drag it anywhere; it remembers.",
    function() refresh() end)
  ns.settingsBuilt = true
  ns.settingsCategory = category
end

function ns.openConfig()
  local ok = pcall(function() Settings.OpenToCategory(ns.settingsCategory:GetID()) end)
  if not ok then ns.say("open Settings > AddOns > VocXP") end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    -- The client replaces the SavedVariables global with the loaded
    -- table after our file ran, so rebind or settings never persist.
    if arg1 ~= name then return end
    if type(VocXPDB) ~= "table" then VocXPDB = {} end
    ns.db = VocXPDB
    ns.ensureSettings()
    return
  elseif event == "PLAYER_LOGIN" then
    ns.ensureSettings() -- in case Settings wasn't up at ADDON_LOADED
    return
  elseif event == "PLAYER_ENTERING_WORLD" then
    ns.db = VocXPDB or ns.db -- client replaced the file-top table
    ns.ensureSettings()
    local snap = readSnapshot()
    local id = UnitGUID("player")
    if id ~= identity or (baseline and baseline.capped) then
      -- New character, first login, or waking from a dormant capped
      -- session: fresh window and a fresh observation gate. Zone loads
      -- on the same character keep history; travel is tracked time.
      identity = id
      resetTrackers()
      paused = false
    end
    if snap.capped then baseline = snap shutdown() return end
    baseline = snap -- zone loads carry no timestamped gains: resync, add nothing
    ns.scanQuestXp()
    ns.subscribeEditMode()
    local o = opts()
    frame:ClearAllPoints()
    frame:SetPoint(o.point, UIParent, o.point, o.x, o.y)
    frame:RegisterEvent("PLAYER_XP_UPDATE")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("UNIT_AURA")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:RegisterEvent("UPDATE_EXHAUSTION")
    frame:RegisterEvent("PLAYER_UPDATE_RESTING")
    frame:RegisterEvent("QUEST_LOG_UPDATE")
    frame:RegisterEvent("QUEST_TURNED_IN")
    frame:RegisterEvent("QUEST_ACCEPTED")
    frame:RegisterEvent("QUEST_REMOVED")
    frame:RegisterEvent("QUEST_COMPLETE")
    if not ticker then ticker = C_Timer.NewTicker(1, refresh) end
    if o.hideDefault and o.shown and not o.barAnnounced then
      o.barAnnounced = true
      ns.say("the default XP bar hides while VocXP shows (/vxp config to change it)")
    end
  else
    if event == "UNIT_AURA" then
      if arg1 ~= "player" then return end
    elseif event == "PLAYER_XP_UPDATE" then
      onXP()
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_TURNED_IN"
        or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED"
        or event == "QUEST_COMPLETE" then
      ns.scanQuestXp()
    end
    -- PLAYER_LEVEL_UP falls through to a bare re-render: the XP path
    -- is the single authoritative award source, so a ding never adds
    -- anything here and event order cannot double-count it.
    -- PLAYER_EQUIPMENT_CHANGED, UPDATE_EXHAUSTION, and
    -- PLAYER_UPDATE_RESTING fall through the same way: a gear swap or
    -- a rest change only re-renders, which refreshes the Regalia,
    -- rested, and quest lines at once.
  end
  refresh()
end)

-- Drag to move; position persists in VocXPDB. Lock gates the drag, and
-- an open Edit Mode session tempers the lock (see cooperation above).
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function()
  if draggable() then dragging = true frame:StartMoving() end
end)
frame:SetScript("OnDragStop", function()
  dragging = false
  frame:StopMovingOrSizing()
  local o = opts()
  local point, _, _, x, y = frame:GetPoint(1)
  o.point, o.x, o.y = point, x, y
end)
frame:SetScript("OnEnter", function() ns.showTip() end)
frame:SetScript("OnLeave", function()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end)

-- The one main action: show or hide the bar. Shared by the bare
-- slash command and the addon compartment.
function ns.toggle()
  local o = opts()
  o.shown = not o.shown
  refresh()
  if baseline and baseline.capped then
    ns.say("max level (stays hidden)")
  else
    ns.play(o.shown and "open" or "close")
    ns.say(o.shown and "shown" or "hidden")
  end
end

function ns.setLocked(on)
  local o = opts()
  o.locked = on
  refresh()
  click(o.locked)
  ns.say(o.locked and "locked" or "unlocked, drag to move")
end

-- Addon compartment (FAMILY.md "Addon compartment"): the toc names
-- these three globals; Blizzard's compartment menu calls them with
-- (addonName, button). Click does what the bare slash does; hover
-- follows the tooltip contract: gold title, one line, the slash hint.
function VocXP_CompartmentClick()
  ns.toggle()
end

function VocXP_CompartmentEnter(_, button)
  if type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  GameTooltip:ClearLines()
  GameTooltip:SetText("VocXP", COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
  GameTooltip:AddLine("Session XP/hr and active XP bonuses on an elegant XP bar.",
    COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
  GameTooltip:AddLine("/vxp shows or hides it. /vxp help lists the rest.",
    COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  GameTooltip:Show()
end

function VocXP_CompartmentLeave()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- Slash grammar shared by every Voc addon (FAMILY.md): the bare command
-- does the one main thing, `config` opens the panel, `help` lists the
-- rest, and anything unrecognized prints help instead of acting.
ns.HELP = {
  "/vxp           show or hide the bar",
  "/vxp lock      lock or unlock the position",
  "/vxp pause     pause or resume tracking",
  "/vxp reset     restart the session",
  "/vxp config    open Settings > AddOns > VocXP",
  "/vxp help      this list (/vocxp works too)",
}

function ns.help()
  ns.say("commands")
  for _, line in ipairs(ns.HELP) do print("  " .. line) end
end

-- Blizzard's slash dispatcher reads SLASH_* globals by name, so these
-- cannot be namespaced (they are declared in .luacheckrc instead).
SLASH_VOCXP1 = "/vxp"
SLASH_VOCXP2 = "/vocxp"
SlashCmdList.VOCXP = function(msg)
  msg = strtrim(msg or ""):lower()
  if msg == "" then
    ns.toggle()
  elseif msg == "lock" then
    ns.setLocked(not opts().locked)
  elseif msg == "pause" then
    paused = not paused
    if not paused then
      -- Resume restarts observation: the paused interval holds no
      -- timestamped awards, so history cannot span it.
      resetTrackers()
      baseline = readSnapshot()
    end
    refresh()
    click(paused)
    ns.say(paused and "paused" or "resumed")
  elseif msg == "reset" then
    resetTrackers()
    baseline = readSnapshot()
    paused = false
    refresh()
    click(true)
    ns.say("session reset")
  elseif msg == "config" then
    ns.openConfig()
  else
    ns.help()
  end
end
