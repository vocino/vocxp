local name, ns = ...
-- VocXP: rolling XP/hr and time-to-level in one tiny readout, plus
-- active XP bonuses. Nothing else.

-- VocDebug guest hook: silent no-op unless the debug addon is loaded.
local dbg = VOCDBG or function() end

VocXPDB = VocXPDB or {}
ns.db = VocXPDB

ns.PREFIX_COLOR = "ff66ccff" -- the family color, same everywhere
function ns.say(msg)
  print("|c" .. ns.PREFIX_COLOR .. name .. "|r: " .. tostring(msg))
end

local defaults = { shown = true, locked = false, point = "CENTER", x = -340, y = 200 }
local function opts()
  for k, v in pairs(defaults) do
    if ns.db[k] == nil then ns.db[k] = v end
  end
  return ns.db
end

local function fmt(n)
  if n >= 1e6 then return ("%.1fm"):format(n / 1e6) end
  if n >= 1e3 then return ("%.0fk"):format(n / 1e3) end
  return ("%.0f"):format(n)
end

-- Rolling estimator -------------------------------------------------
-- A trailing window over timestamped XP awards. All times are GetTime()
-- seconds: one monotonic clock, never mixed with wall time, and never
-- persisted (monotonic timestamps die with the process).

ns.WINDOW = 300 -- trailing window, seconds
ns.ETA_WINDOW = 900 -- ETA basis window, seconds
ns.GATE = 30 -- observation before estimates display, seconds

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
  if g == 0 then
    est.status = "no-recent-xp"
    return est
  end
  if est.observedSeconds < tr.window then
    est.status = "warming-up"
  else
    est.status = "ready"
  end
  est.etaSeconds = est.remainingXp * d / g
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
  if est.status == "collecting" then return "Collecting data" end
  local rate = est.xpPerHour
  if rate == nil then return "Collecting data" end
  local label = " · last " .. ns.formatObserved(est.observedSeconds)
  if est.status == "warming-up" then label = label .. " · warming up" end
  if rate == 0 then return "0 XP/hr" .. label end
  return fmt(rate) .. " XP/hr" .. label
end

function ns.formatEta(sec)
  if not finite(sec) then return "-" end
  if sec < 60 then return "~<1m" end
  local m = math.ceil(sec / 60)
  local h = math.floor(m / 60)
  local r = m % 60
  if h == 0 then return ("~%dm"):format(m) end
  if r == 0 then return ("~%dh"):format(h) end
  return ("~%dh%02dm"):format(h, r)
end

function ns.etaText(est)
  local s = est.status
  if s == "paused" then return "Paused" end
  if s == "capped" then return "Max level" end
  if s == "unavailable" then return "Unavailable" end
  if s == "awaiting-level-update" then return "Level complete; awaiting update" end
  if s == "collecting" then return "Collecting data" end
  if s == "no-recent-xp" then return "No recent XP" end
  return "Next level: " .. ns.formatEta(est.etaSeconds)
end

-- Palette, defined once per the voc-addons skill: house gold for the
-- title and frame accent, soft red/green for bonus state only,
-- gray for the missing-buff section.
local COLORS = {
  gold = { 1, 0.82, 0 },
  green = { 0.25, 1, 0.25 },
  red = { 1, 0.25, 0.25 },
  muted = { 0.5, 0.5, 0.5 },
}

local frame = CreateFrame("Frame", "VocXPFrame", UIParent, "BackdropTemplate")
frame:SetSize(150, 32)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, 0.85)
frame:SetBackdropBorderColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])

-- Readout text. Tooltip text hierarchy, straight from the client's own
-- templates (Blizzard_Fonts_Shared/Shared/FontStyles.xml): a header title
-- line, then smaller body lines. Colors set separately via SetTextColor.
-- The body is created before the ETA line so the headless stub (which
-- tells same-template strings apart by creation order) routes them.
local title = frame:CreateFontString(nil, "OVERLAY", "GameTooltipHeaderText")
title:SetPoint("TOPLEFT", 10, -10)
title:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
local body = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
local eta = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
eta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
body:SetPoint("TOPLEFT", eta, "BOTTOMLEFT", 0, -4)
local missed = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
missed:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -4)
missed:SetTextColor(COLORS.muted[1], COLORS.muted[2], COLORS.muted[3])

-- Session state. Both trackers and the baseline live here, never in
-- SavedVariables: monotonic timestamps must not cross a reload.
local rateTracker = ns.newTracker(GetTime())
local etaTracker = ns.newTracker(GetTime(), ns.ETA_WINDOW)
local baseline = nil
local identity = nil
local paused = false
local lastBonusKey = nil -- VocDebug: emit only on bonus-set change

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

local function rested()
  return GetXPExhaustion() ~= nil
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

-- Checkbox toggle sounds (voc-addons principle 3): every slash toggle
-- confirms audibly. SOUNDKIT constants are primary; the numeric IDs
-- keep working across a Blizzard rename. Fully presence-gated: no
-- sound API, no sound, never an error.
local function click(on)
  if type(C_Sound) ~= "table" or type(C_Sound.PlaySound) ~= "function" then return end
  local id
  if type(SOUNDKIT) == "table" then
    id = on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF
  end
  if type(id) ~= "number" then id = on and 856 or 857 end
  C_Sound.PlaySound(id)
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
  if rested() then add(nil, "Rested") end
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
-- either/or, so only WHEE! is ever recommended.
local function missingParts()
  local parts = {}
  local function add(pct, label)
    parts[#parts + 1] = { pct = pct, label = label, seq = #parts + 1 }
  end
  if not warMode() then
    local pct = warModeOffered()
    add(pct, ("+%d%% War Mode (toggle in a capital)"):format(pct))
  end
  local restricted = inInstance()
  if not restricted and not playerAura(MENTORED_ID) then
    add(nil, "Warband Mentored (needs a max-level character)")
  end
  if not restricted and not hasAura(46668) and not hasAura(136583) then
    add(10, "+10% WHEE! (Faire week)")
  end
  if not restricted and not hasAura(24705) and not hasAura(95987) then
    add(10, "+10% Wickerman (Hallow's End)")
  end
  if not rested() then add(nil, "Rested (rest in town)") end
  if restricted then add(nil, "Aura scan unavailable in instances") end
  sortByValue(parts)
  local labels = {}
  for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
  return labels
end

local function refresh()
  local o = opts()
  local now = GetTime()
  local est = ns.estimate(rateTracker, now, baseline, paused)
  if est.status == "capped" then
    frame:SetShown(false)
    return
  end
  -- The ETA reads the longer basis (which also prunes it); the rate
  -- window still gates whether any ETA shows at all.
  local longEta = ns.etaSeconds(etaTracker, now, est.remainingXp or 0)
  if est.etaSeconds and (est.remainingXp or 0) > 0 then
    est.etaSeconds = longEta or est.etaSeconds
  end
  title:SetText(ns.titleText(est))
  eta:SetText(ns.etaText(est))
  local bonuses = bonusParts()
  local bonusKey = table.concat(bonuses, "|")
  if bonusKey ~= lastBonusKey then
    lastBonusKey = bonusKey
    dbg("vocxp", "bonuses_changed", bonusKey == "" and "none" or bonusKey)
  end
  if #bonuses == 0 then
    body:SetTextColor(COLORS.red[1], COLORS.red[2], COLORS.red[3])
    body:SetText("No XP bonus")
  else
    body:SetTextColor(COLORS.green[1], COLORS.green[2], COLORS.green[3])
    body:SetText(table.concat(bonuses, "\n"))
  end
  local missing = missingParts()
  if #missing == 0 then
    missed:SetText("")
  else
    missed:SetText(table.concat(missing, "\n"))
  end
  local w = math.max(title:GetStringWidth(), eta:GetStringWidth(), body:GetStringWidth())
  local h = title:GetStringHeight() + 4 + eta:GetStringHeight() + 4 + body:GetStringHeight()
  if missed:GetText() ~= "" then
    w = math.max(w, missed:GetStringWidth())
    h = h + 4 + missed:GetStringHeight()
  end
  frame:SetSize(w + 20, h + 20)
  frame:SetShown(o.shown)
end

-- At max level the addon goes fully dormant: no ticker, no hot
-- events. PLAYER_ENTERING_WORLD stays registered as the wake path
-- (loading screens only); a cap raise restarts everything there.
local ticker
local function shutdown()
  frame:SetShown(false)
  paused = false
  if ticker then ticker:Cancel() ticker = nil end
  frame:UnregisterEvent("PLAYER_XP_UPDATE")
  frame:UnregisterEvent("PLAYER_LEVEL_UP")
  frame:UnregisterEvent("UNIT_AURA")
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
      if ns.addAward(etaTracker, stamp, gained) then
        dbg("vocxp", "xp_award", ("gained=%d level=%d"):format(gained, snap.level))
      end
    end
  end
  baseline = snap
  refresh()
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_ENTERING_WORLD" then
    ns.db = VocXPDB or ns.db -- client replaced the file-top table
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
    local o = opts()
    frame:ClearAllPoints()
    frame:SetPoint(o.point, UIParent, o.point, o.x, o.y)
    frame:RegisterEvent("PLAYER_XP_UPDATE")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("UNIT_AURA")
    if not ticker then ticker = C_Timer.NewTicker(1, refresh) end
    frame:EnableMouse(not o.locked)
  else
    if event == "UNIT_AURA" then
      if arg1 ~= "player" then return end
    elseif event == "PLAYER_XP_UPDATE" then
      onXP()
    end
    -- PLAYER_LEVEL_UP falls through to a bare re-render: the XP path
    -- is the single authoritative award source, so a ding never adds
    -- anything here and event order cannot double-count it.
  end
  refresh()
end)

-- Drag to move; position persists in VocXPDB.
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function()
  if not opts().locked then frame:StartMoving() end
end)
frame:SetScript("OnDragStop", function()
  frame:StopMovingOrSizing()
  local o = opts()
  local point, _, _, x, y = frame:GetPoint(1)
  o.point, o.x, o.y = point, x, y
end)

SLASH_VOCXP1 = "/vxp"
SlashCmdList.VOCXP = function(msg)
  msg = strtrim(msg or ""):lower()
  local o = opts()
  if msg == "lock" then
    o.locked = not o.locked
    frame:EnableMouse(not o.locked)
    click(o.locked)
    ns.say(o.locked and "locked." or "unlocked. Drag to move.")
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
    ns.say(paused and "paused." or "resumed.")
  elseif msg == "reset" then
    resetTrackers()
    baseline = readSnapshot()
    paused = false
    refresh()
    click(true)
    ns.say("session reset.")
  else
    o.shown = not o.shown
    refresh()
    if baseline and baseline.capped then
      ns.say("max level (stays hidden).")
    else
      click(o.shown)
      ns.say(o.shown and "shown." or "hidden.")
    end
  end
end
