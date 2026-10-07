local name, ns = ...
-- VocXP: rolling XP/hr and time-to-level in one tiny readout, plus
-- active XP bonuses. Nothing else.

-- VocDebug guest hook: silent no-op unless the debug addon is loaded.
local dbg = VOCDBG or function() end

VocXPDB = VocXPDB or {}
ns.db = VocXPDB

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
ns.GATE = 30 -- observation before estimates display, seconds

function ns.newTracker(t0)
  return { t0 = t0, events = {}, head = 1, sum = 0 }
end

local function cutoff(tr, now)
  return math.max(tr.t0, now - ns.WINDOW)
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
    windowSeconds = ns.WINDOW,
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
  if est.observedSeconds < ns.WINDOW then
    est.status = "warming-up"
  else
    est.status = "ready"
  end
  est.etaSeconds = est.remainingXp * d / g
  return est
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
frame:SetBackdropBorderColor(1, 0.82, 0)

-- Readout text. Tooltip text hierarchy, straight from the client's own
-- templates (Blizzard_Fonts_Shared/Shared/FontStyles.xml): a header title
-- line, then smaller body lines. Colors set separately via SetTextColor.
-- The body is created before the ETA line so the headless stub (which
-- tells same-template strings apart by creation order) routes them.
local title = frame:CreateFontString(nil, "OVERLAY", "GameTooltipHeaderText")
title:SetPoint("TOPLEFT", 10, -10)
local body = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
local eta = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
eta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
body:SetPoint("TOPLEFT", eta, "BOTTOMLEFT", 0, -4)

-- Session state. The tracker and baseline live here, never in
-- SavedVariables: monotonic timestamps must not cross a reload.
local tracker = ns.newTracker(GetTime())
local baseline = nil
local identity = nil
local paused = false
local lastBonusKey = nil -- VocDebug: emit only on bonus-set change

local function warMode()
  return type(C_PvP) == "table"
    and type(C_PvP.IsWarModeDesired) == "function"
    and C_PvP.IsWarModeDesired()
end

local function rested()
  return GetXPExhaustion() ~= nil
end

-- Fixed-value XP-buff auras by spell ID: WHEE! (Darkmoon carousel and
-- coaster), Darkmoon Top Hat (separate aura, same +10%), Grim Visage /
-- Unburdened (Hallow's End Wickerman, one per faction).
local xpBuffs = {
  { id = 46668, label = "+10% WHEE!" },
  { id = 136583, label = "+10% Darkmoon Top Hat" },
  { id = 24705, label = "+10% Grim Visage" },
  { id = 95987, label = "+10% Unburdened" },
}

local function playerAura(spellID)
  if type(C_UnitAuras) ~= "table" then return nil end
  if type(C_UnitAuras.GetPlayerAuraBySpellID) ~= "function" then return nil end
  return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

-- Bonus-line colors (title stays the template's white).
local GREEN = { 0.25, 1, 0.25 }
local RED = { 1, 0.25, 0.25 }

local function hasAura(spellID) return playerAura(spellID) ~= nil end

-- Warband Mentored Leveling scales 5-25% with max-level characters;
-- the aura's first effect point carries the current value.
local MENTORED_ID = 430191
local function mentoredLabel()
  local aura = playerAura(MENTORED_ID)
  if not aura then return nil end
  local pct = aura.points and aura.points[1]
  if type(pct) == "number" and pct >= 1 and pct <= 100 then
    return ("+%d%% Warband Mentored"):format(pct)
  end
  return "Warband Mentored"
end

local function bonusParts()
  local parts = {}
  if warMode() then parts[#parts + 1] = "+10% War Mode" end
  local mentored = mentoredLabel()
  if mentored then parts[#parts + 1] = mentored end
  for _, buff in ipairs(xpBuffs) do
    if hasAura(buff.id) then parts[#parts + 1] = buff.label end
  end
  if rested() then parts[#parts + 1] = "Rested" end
  return parts
end

local function refresh()
  local o = opts()
  local est = ns.estimate(tracker, GetTime(), baseline, paused)
  if est.status == "capped" then
    frame:SetShown(false)
    return
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
    body:SetTextColor(RED[1], RED[2], RED[3])
    body:SetText("No XP bonus")
  else
    body:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
    body:SetText(table.concat(bonuses, "\n"))
  end
  local w = math.max(title:GetStringWidth(), eta:GetStringWidth(), body:GetStringWidth())
  local h = title:GetStringHeight() + 4 + eta:GetStringHeight() + 4 + body:GetStringHeight()
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
    if gained then ns.addAward(tracker, GetTime(), gained) end
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
      tracker = ns.newTracker(GetTime())
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
    print(name .. ": " .. (o.locked and "locked." or "unlocked. Drag to move."))
  elseif msg == "pause" then
    paused = not paused
    if not paused then
      -- Resume restarts observation: the paused interval holds no
      -- timestamped awards, so history cannot span it.
      tracker = ns.newTracker(GetTime())
      baseline = readSnapshot()
    end
    refresh()
    print(name .. ": " .. (paused and "paused." or "resumed."))
  elseif msg == "reset" then
    tracker = ns.newTracker(GetTime())
    baseline = readSnapshot()
    paused = false
    refresh()
    print(name .. ": session reset.")
  else
    o.shown = not o.shown
    refresh()
    if baseline and baseline.capped then
      print(name .. ": max level (stays hidden).")
    else
      print(name .. ": " .. (o.shown and "shown." or "hidden."))
    end
  end
end
