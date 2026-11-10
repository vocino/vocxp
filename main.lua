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
  rest = { 0.3, 0.6, 1 }, -- rested reach: clear blue over the purple fill
  quest = { 1, 0.84, 0.32 }, -- banked quest XP: bright gold over the prediction grain
}

-- r, g, b (and alpha when given) for a token, so a SetTextColor or
-- SetColorTexture call reads as the token's name.
function ns.rgb(token, alpha)
  return token[1], token[2], token[3], alpha
end

-- Hex for a token, for inline color escapes in tooltip text: the
-- number carries the color while the words stay body text. The
-- escape builds at runtime, so no |cff literal ever sits at a call
-- site -- the palette file stays the single source of color.
function ns.hex(token)
  if type(token) ~= "table" then return "FFFFFF" end
  return ("%02X%02X%02X"):format(math.floor(token[1] * 255 + 0.5),
    math.floor(token[2] * 255 + 0.5), math.floor(token[3] * 255 + 0.5))
end
local COLORS = ns.COLORS

-- Defaults: the single source of truth (FAMILY.md "Settings"). A key
-- holding the wrong type resets; unknown keys are left alone.
local defaults = { shown = true, locked = false, hideDefault = true,
  repMode = true, followLatest = false, alwaysShow = false,
  point = "BOTTOM", x = 0, y = 100 }
ns.defaults = defaults
local VALID_POINTS = {
  TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
  RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
local function opts()
  if type(ns.db) ~= "table" then ns.db = {} VocXPDB = ns.db end
  for k, v in pairs(defaults) do
    if type(ns.db[k]) ~= type(v) then ns.db[k] = v end
  end
  -- A hand-edited anchor the client cannot SetPoint to would error on
  -- every login; fall back to the default instead of breaking the bar.
  if not VALID_POINTS[ns.db.point] then ns.db.point = defaults.point end
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
  if est.status == "untracked" then return "No reputation tracked" end
  if est.status == "rep-capped" then return est.capLabel or "Rank complete" end
  if est.status == "unavailable" then return "Unavailable" end
  local rate = est.xpPerHour
  -- No pace exists yet on the very first paint (zero elapsed time).
  if rate == nil then return "Collecting data" end
  local head = fmt(rate) .. (est.unit == "Rep" and " Rep/hr" or " XP/hr")
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
  if s == "unavailable" then
    return est.unit == "Rep" and "Waiting for rep data" or "Waiting for XP data"
  end
  if s == "untracked" then return "Watch a faction to track it" end
  if s == "rep-capped" then return "Rank complete" end
  if s == "awaiting-level-update" then
    return est.unit == "Rep" and "Rank complete; awaiting update" or "Level complete; awaiting update"
  end
  if s == "collecting" then return "Collecting data" end
  local span = ns.formatObserved(est.windowSeconds)
  if s == "no-recent-xp" then
    return (est.unit == "Rep" and "No rep in the last " or "No XP in the last ") .. span
  end
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

-- Long ETA for the persistent bar text: the same upward rounding as
-- formatEta, but "1h 10m" spacing instead of the tooltip compact form.
function ns.formatEtaLong(sec)
  if not finite(sec) then return "-" end
  if sec < 60 then return "<1m" end
  local m = math.ceil(sec / 60)
  local h = math.floor(m / 60)
  local r = m % 60
  if h == 0 then return ("%dm"):format(m) end
  if r == 0 then return ("%dh"):format(h) end
  return ("%dh %dm"):format(h, r)
end

-- The persistent bar text: the tooltip headline content in bar shape,
-- rate and long ETA joined with " - ". Special statuses keep their
-- short tooltip words; with no pace yet, the bar reads "Collecting
-- data" exactly when the tooltip would show pace alone.
function ns.barText(est)
  if type(est) ~= "table" then return "Collecting data" end
  local s = est.status
  if s == "paused" or s == "capped" or s == "untracked"
      or s == "rep-capped" or s == "unavailable" then
    return ns.titleText(est)
  end
  local rate = est.xpPerHour
  if rate == nil then return "Collecting data" end
  local head = fmt(rate) .. (est.unit == "Rep" and " Rep/hr" or " XP/hr")
  if est.etaSeconds == nil then return head end
  return head .. " - " .. ns.formatEtaLong(est.etaSeconds)
end


-- The bar. Built the way Blizzard builds its own ExpStatusBarTemplate:
-- a StatusBar wearing the native XP fill atlases, the native
-- background, the prediction fill for rested reach (gold-tinted for
-- banked quest reach), and the rested pip. Sized from the live native
-- geometry every refresh, so the stroke and ticks land at 1:1. The
-- frame is the art zone only; the bar label wears the native
-- TextStatusBar face and shows on hover, like the native text.
ns.BAR_WIDTH = 571 -- Mainline container width, the fallback everywhere
ns.TROUGH_WIDTH = 565 -- InitializeBars seats the bar at container minus 6
ns.TROUGH_HEIGHT = 11
ns.MAX_SEGMENTS = 40 -- validation ceiling, twice the widest native bar
ns.ART_HEIGHT = 17 -- the native container height; the frame is exactly this
ns.FILL_HEIGHT = 11 -- the native prediction fill height, bottom-anchored
ns.XP_ATLAS = "UI-HUD-ExperienceBar-Fill-Experience"
ns.RESTED_ATLAS = "UI-HUD-ExperienceBar-Fill-Rested"
ns.BG_ATLAS = "UI-HUD-ExperienceBar-Background"
ns.FRAME_ATLAS = "UI-HUD-ExperienceBar-Frame"
ns.PIP_ATLAS = "UI-HUD-ExperienceBar-Frame-Pip"
ns.PREDICTION_ATLAS = "UI-HUD-ExperienceBar-Fill-Prediction" -- rested reach
ns.DIVIDER_ATLAS = "ui-hud-experiencebar-divider" -- Camelot segment ticks
ns.FLARE_XP_ATLAS = "UI-HUD-ExperienceBar-Flare-XP-2x-Flipbook"
ns.FLARE_RESTED_ATLAS = "UI-HUD-ExperienceBar-Flare-Rested-2x-Flipbook"
ns.LEVELUP_XP_ATLAS = "UI-HUD-ExperienceBar-Fill-Experience-2x-Flipbook"
ns.LEVELUP_RESTED_ATLAS = "UI-HUD-ExperienceBar-Fill-Rested-2x-Flipbook"
-- Reputation fills, one row per reaction like the native watch bar
-- (ReputationBarOverrides.lua): Hated and Hostile burn red, Unfriendly
-- orange, Neutral yellow, everything warmer green; Renown and
-- major-faction Paragon take the blue override instead.
ns.REP_FILL = {
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Red",
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Red",
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Orange",
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Yellow",
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green",
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green",
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green",
  "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green",
}
ns.REP_FILL_BLUE = "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Blue"
ns.REP_FLARE = {
  "UI-HUD-ExperienceBar-Flare-Faction-Orange-2x-Flipbook",
  "UI-HUD-ExperienceBar-Flare-Faction-Orange-2x-Flipbook",
  "UI-HUD-ExperienceBar-Flare-Faction-Orange-2x-Flipbook",
  "UI-HUD-ExperienceBar-Flare-ArtifactPower-2x-Flipbook",
  "UI-HUD-ExperienceBar-Flare-Reputation-2x-Flipbook",
  "UI-HUD-ExperienceBar-Flare-Reputation-2x-Flipbook",
  "UI-HUD-ExperienceBar-Flare-Reputation-2x-Flipbook",
  "UI-HUD-ExperienceBar-Flare-Reputation-2x-Flipbook",
}
ns.REP_FLARE_BLUE = "UI-HUD-ExperienceBar-Flare-Rested-2x-Flipbook"
ns.REP_LEVELUP = {
  "UI-HUD-ExperienceBar-Fill-Honor-2x-Flipbook",
  "UI-HUD-ExperienceBar-Fill-Honor-2x-Flipbook",
  "UI-HUD-ExperienceBar-Fill-Honor-2x-Flipbook",
  "UI-HUD-ExperienceBar-Fill-ArtifactPower-2x-Flipbook",
  "UI-HUD-ExperienceBar-Fill-Reputation-2x-Flipbook",
  "UI-HUD-ExperienceBar-Fill-Reputation-2x-Flipbook",
  "UI-HUD-ExperienceBar-Fill-Reputation-2x-Flipbook",
  "UI-HUD-ExperienceBar-Fill-Reputation-2x-Flipbook",
}
ns.REP_LEVELUP_BLUE = "UI-HUD-ExperienceBar-Fill-Rested-2x-Flipbook"
-- Standing names, Hated to Exalted. English literals like every other
-- line the addon prints; the client localizes, we don't (see the
-- verification record for why no label global is read instead).
ns.STANDING_NAMES = {
  "Hated", "Hostile", "Unfriendly", "Neutral",
  "Friendly", "Honored", "Revered", "Exalted",
}

local frame = CreateFrame("Frame", "VocXPFrame", UIParent)
frame:SetSize(ns.BAR_WIDTH, ns.ART_HEIGHT)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true) -- hover tooltip always; lock gates dragging, not looking

-- The animated template is Blizzard's own XP-bar machinery (gain flare,
-- level-up flash, ding wrap); a client without it gets a plain bar.
local barOk, animatedBar = pcall(CreateFrame, "StatusBar", nil, frame,
  "GradualAnimatedStatusBarTemplate")
-- Animated when the template exists (its mixin methods are
-- presence-gated at every use); a plain StatusBar otherwise.
---@type StatusBar&GradualAnimatedStatusBarMixin
local bar = (barOk and animatedBar) or CreateFrame("StatusBar", nil, frame)
local hasAnimatedBar = barOk and animatedBar ~= nil
-- InitializeBars seats the trough at (1, -1) of the container,
-- resized every refresh from the live native geometry (see below).
bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
bar:SetSize(ns.TROUGH_WIDTH, ns.TROUGH_HEIGHT)
if not hasAnimatedBar then
  -- Plain bars have no SetBarTexture: the file texture plus a 0..1
  -- range until the first refresh paints real values.
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
end

-- Atlases are Blizzard's own art. A missing atlas hides its layer
-- instead of erroring, so a client without one still shows the bar.
local function setAtlasOrHide(tex, atlas, useSize)
  if pcall(function() tex:SetAtlas(atlas, useSize) end) then return true end
  tex:Hide()
  return false
end

local bg = bar:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(bar)
setAtlasOrHide(bg, ns.BG_ATLAS, false)

-- Rested reach wears the native prediction fill: the same atlas
-- Blizzard's ExhaustionLevelFillBar wears, bottom-anchored at the
-- native height, cropped from the left. No tint; the atlas carries
-- its own color. A client without the atlas hides the layer.
local restFill = bar:CreateTexture(nil, "ARTWORK", nil, -1)
restFill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
restFill:SetSize(0, ns.FILL_HEIGHT)
local restOk = setAtlasOrHide(restFill, ns.PREDICTION_ATLAS, false)
restFill:Hide()

-- Banked quest XP has no native counterpart, so it borrows the
-- prediction grain in gold: the same shading language as rested
-- reach, reading as one overlay family instead of a foreign slab.
local questFill = bar:CreateTexture(nil, "ARTWORK", nil, 0)
questFill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
questFill:SetSize(0, ns.FILL_HEIGHT)
local questOk = setAtlasOrHide(questFill, ns.PREDICTION_ATLAS, false)
if questOk then
  questFill:SetVertexColor(ns.rgb(COLORS.quest))
end
questFill:Hide()

-- The stroke around the bar and the rested pip: the same two atlas
-- layers Blizzard's own bar wears; the stroke hangs on the frame.
local frameTex = frame:CreateTexture(nil, "OVERLAY")
frameTex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
frameTex:SetSize(ns.BAR_WIDTH, ns.ART_HEIGHT)
setAtlasOrHide(frameTex, ns.FRAME_ATLAS, false)

local pip = bar:CreateTexture(nil, "OVERLAY", nil, 1)
pip:SetSize(10, 14)
local pipOk = setAtlasOrHide(pip, ns.PIP_ATLAS, false)
pip:Hide()
-- Unknown font objects error at creation, so the label wears the
-- native TextStatusBar face with a small-face fallback.
local function makeFont(parent, template, fallback)
  local ok, fs = pcall(parent.CreateFontString, parent, nil, "OVERLAY", template)
  if ok and fs ~= nil then return fs end
  return parent:CreateFontString(nil, "OVERLAY", fallback)
end
local barText = makeFont(bar, "TextStatusBarText", "GameFontNormalSmall")
barText:SetPoint("CENTER", bar, "CENTER", 0, 1)
barText:SetShadowOffset(1, -1)
-- Hover-only, like the native ShowText/HideText: the bar reads clean
-- until the player asks it a question.
barText:Hide()

function ns.showBarLabel()
  barText:Show()
end

function ns.hideBarLabel()
  -- The persistent text owns its own visibility: hover-off never
  -- hides it, and the toggle-off handler hides it explicitly.
  if opts().alwaysShow then return end
  barText:Hide()
end

-- Show and hide ride the native fade: the container fades over half a
-- second on bar switches. A client without the fader shows and hides
-- at once. The hide is generation-guarded, so a quick re-show never
-- eats a delayed hide.
local hideGen = 0

function ns.barShown(shown)
  if shown then
    hideGen = hideGen + 1
    if not frame:IsShown() then
      frame:SetShown(true)
      if type(UIFrameFadeIn) == "function" then
        pcall(UIFrameFadeIn, frame, 0.5, 0, 1)
      end
    end
    return
  end
  if not frame:IsShown() then return end
  if type(UIFrameFadeOut) ~= "function" then
    frame:SetShown(false)
    return
  end
  hideGen = hideGen + 1
  local gen = hideGen
  pcall(UIFrameFadeOut, frame, 0.5, 1, 0)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    pcall(C_Timer.After, 0.5, function()
      if gen == hideGen then frame:SetShown(false) end
    end)
  else
    frame:SetShown(false)
  end
end

-- Snap every region to the pixel grid: Blizzard rounds layout natively,
-- so fractional widths and drag positions render crisp instead of blurred.
local function snapRegion(region)
  if region ~= nil and type(region.SetRoundLayoutToNearestPixel) == "function" then
    pcall(region.SetRoundLayoutToNearestPixel, region, true)
  end
end
snapRegion(frame)
snapRegion(bar)
snapRegion(bg)
snapRegion(restFill)
snapRegion(questFill)
snapRegion(frameTex)
snapRegion(pip)
snapRegion(barText)

-- Native geometry ------------------------------------------------------
-- The native bar is not one size: Mainline seats a 571x17 container
-- (565x11 trough, no segments) while Camelot seats 1192x17 (1189x14,
-- 20 segments with divider ticks). VocXP reads the live numbers every
-- refresh and wears them, so the stroke, trough, and ticks land at 1:1
-- on whatever client is running. Every read validates and falls back
-- to the Mainline numbers; a missing native bar is never an error.
function ns.nativeGeometry()
  local width, segments, adjust, pipY = nil, nil, nil, nil
  local mgr = StatusTrackingBarManager
  local container = type(mgr) == "table" and mgr.MainStatusTrackingBarContainer or nil
  if type(container) == "table" then
    if type(container.GetWidth) == "function" then
      local ok, w = pcall(container.GetWidth, container)
      if ok and type(w) == "number" and w >= 200 and w <= 3000 then width = w end
    end
    if type(container.GetExpectedSegments) == "function" then
      local ok, s = pcall(container.GetExpectedSegments, container)
      if ok and type(s) == "number" and s >= 1 and s <= ns.MAX_SEGMENTS then
        segments = math.floor(s)
      end
    end
  end
  if width == nil and type(STATUS_BAR_CONTAINER_WIDTH) == "number"
      and STATUS_BAR_CONTAINER_WIDTH >= 200 and STATUS_BAR_CONTAINER_WIDTH <= 3000 then
    width = STATUS_BAR_CONTAINER_WIDTH
  end
  if segments == nil and type(STATUS_BAR_NUM_SEGMENTS) == "number"
      and STATUS_BAR_NUM_SEGMENTS >= 1 and STATUS_BAR_NUM_SEGMENTS <= ns.MAX_SEGMENTS then
    segments = math.floor(STATUS_BAR_NUM_SEGMENTS)
  end
  if type(STATUS_BAR_SIZE_ADJUSTMENT) == "number"
      and STATUS_BAR_SIZE_ADJUSTMENT >= 0 and STATUS_BAR_SIZE_ADJUSTMENT <= 16 then
    adjust = STATUS_BAR_SIZE_ADJUSTMENT
  end
  if type(EXHAUSTION_TICK_OFFSET_Y) == "number"
      and EXHAUSTION_TICK_OFFSET_Y >= -8 and EXHAUSTION_TICK_OFFSET_Y <= 8 then
    pipY = EXHAUSTION_TICK_OFFSET_Y
  end
  width = width or ns.BAR_WIDTH
  segments = segments or 1
  adjust = adjust or 6
  pipY = pipY or 2
  return { width = width, segments = segments,
    troughW = width - adjust, troughH = ns.ART_HEIGHT - adjust, pipY = pipY }
end

-- Segment ticks, Camelot's divider look. The native template draws
-- them when it exists; otherwise a 3x10 frame wears the divider atlas
-- by hand, and hides when the atlas is missing too.
local dividers = {}

local function ensureDivider(i)
  if dividers[i] ~= nil then return dividers[i] end
  local ok, d = pcall(CreateFrame, "Frame", nil, frame, "StatusBarDividerTemplate")
  if ok and d ~= nil then
    snapRegion(d)
    dividers[i] = d
    return d
  end
  local f = CreateFrame("Frame", nil, frame)
  f:SetSize(3, 10)
  local tex = f:CreateTexture(nil, "OVERLAY")
  tex:SetAllPoints(f)
  f.usable = setAtlasOrHide(tex, ns.DIVIDER_ATLAS, false)
  snapRegion(f)
  snapRegion(tex)
  dividers[i] = f
  return f
end

-- Seat the frame, trough, stroke, and ticks on the live native
-- geometry. Runs every refresh but only moves regions when the numbers
-- change (a gamepad toggle resizes native mid-session).
local appliedGeo = nil

function ns.applyGeometry()
  local geo = ns.nativeGeometry()
  if appliedGeo ~= nil and appliedGeo.width == geo.width
      and appliedGeo.segments == geo.segments
      and appliedGeo.troughW == geo.troughW
      and appliedGeo.troughH == geo.troughH then
    return geo
  end
  appliedGeo = geo
  frame:SetSize(geo.width, ns.ART_HEIGHT)
  bar:SetSize(geo.troughW, geo.troughH)
  frameTex:SetSize(geo.width, ns.ART_HEIGHT)
  local ticks = geo.segments - 1
  for i = 1, ticks do
    local d = ensureDivider(i)
    d:ClearAllPoints()
    d:SetPoint("LEFT", frame, "TOPLEFT", geo.width / geo.segments * i, -ns.ART_HEIGHT / 2)
    d:SetShown(d.usable ~= false)
  end
  local i = ticks + 1
  while dividers[i] ~= nil do
    dividers[i]:SetShown(false)
    i = i + 1
  end
  return geo
end

-- Session state. Both trackers and the baseline live here, never in
-- SavedVariables: monotonic timestamps must not cross a reload.
local rateTracker = ns.newTracker(GetTime())
local etaTracker = ns.newTracker(GetTime(), ns.ETA_WINDOW)
local baseline = nil
local identity = nil
local paused = false
local mode = "xp" -- "xp", "rep", or "dormant"; derived from the capped snapshot, never toggled

local function resetTrackers()
  rateTracker = ns.newTracker(GetTime())
  etaTracker = ns.newTracker(GetTime(), ns.ETA_WINDOW)
  ns.clearSummary() -- observation restarts: the old burst never reports
end

-- Net gain summary (Plumber's LootUI pattern, original code: a 0.15s
-- display queue merges deferred balance deltas into one net line).
-- Gains arriving in a burst (dungeon packs, mass turn-ins) or mid-fight
-- share one deferred chat line instead of one line each. Awards still
-- land in the trackers at once: only this line waits, never the data.
ns.SUMMARY_QUIET = 0.15 -- stillness before a burst reports, seconds
local summaryAcc = { count = 0, xp = 0, rep = {}, repOrder = {}, lastAt = 0, busySeen = false }

-- Busy window: combat lockdown. A missing API never reads as busy.
function ns.inCombat()
  if type(InCombatLockdown) == "function" and InCombatLockdown() then return true end
  return false
end

function ns.clearSummary()
  summaryAcc = { count = 0, xp = 0, rep = {}, repOrder = {}, lastAt = 0, busySeen = false }
end

-- One gain joins the pending summary. A quiet spell (no new gains for
-- SUMMARY_QUIET outside combat) closes the previous burst first, so a
-- line never spans two separate bursts; combat holds the burst open.
function ns.noteSummaryGain(now, kind, id, factionName, amount)
  if not finite(now) or not finite(amount) or amount <= 0 then return false end
  if kind ~= "xp" and kind ~= "rep" then return false end
  if kind == "rep" then
    if type(id) ~= "number" then return false end
    if type(factionName) ~= "string" then factionName = "reputation" end
  end
  if summaryAcc.count > 0 and not ns.inCombat()
      and (now - summaryAcc.lastAt) >= ns.SUMMARY_QUIET then
    ns.clearSummary()
  end
  summaryAcc.count = summaryAcc.count + 1
  summaryAcc.lastAt = now
  if ns.inCombat() then summaryAcc.busySeen = true end
  if kind == "xp" then
    summaryAcc.xp = summaryAcc.xp + amount
  else
    local bucket = summaryAcc.rep[id]
    if bucket == nil then
      bucket = { name = factionName, amount = 0 }
      summaryAcc.rep[id] = bucket
      summaryAcc.repOrder[#summaryAcc.repOrder + 1] = id
    end
    bucket.amount = bucket.amount + amount
  end
  return true
end

-- The net line for the pending burst, or nil when nothing reportable
-- waits: single gains stay silent, so slow play gains no new chatter.
function ns.formatSummary()
  if summaryAcc.count < 2 then return nil end
  local parts = {}
  if summaryAcc.xp > 0 then
    parts[#parts + 1] = "+" .. fmt(summaryAcc.xp) .. " XP"
  end
  local total, factions = 0, {}
  for _, id in ipairs(summaryAcc.repOrder) do
    local bucket = summaryAcc.rep[id]
    if bucket ~= nil and bucket.amount > 0 then
      total = total + bucket.amount
      factions[#factions + 1] = bucket.name .. " " .. fmt(bucket.amount)
    end
  end
  if total > 0 then
    if #factions == 1 then
      local only = summaryAcc.rep[summaryAcc.repOrder[1]]
      parts[#parts + 1] = "+" .. fmt(total) .. " rep with " .. only.name
    else
      parts[#parts + 1] = "+" .. fmt(total) .. " rep (" .. table.concat(factions, ", ") .. ")"
    end
  end
  if #parts == 0 then return nil end
  local line = table.concat(parts, ", ")
  if summaryAcc.busySeen then line = line .. " in combat" end
  return line
end

-- Report the pending burst when it is due: at least two gains, no new
-- gains for SUMMARY_QUIET, and no longer busy. Called from refresh(),
-- so no new timer and no new event: the 1s ticker bounds the delay.
function ns.flushSummary(now)
  if summaryAcc.count < 2 then return false end
  if ns.inCombat() then return false end
  if not finite(now) or (now - summaryAcc.lastAt) < ns.SUMMARY_QUIET then return false end
  local line = ns.formatSummary()
  ns.clearSummary()
  if line == nil then return false end
  ns.say(line)
  return true
end

-- Client flavor. The client loads exactly one of our tocs (the 1.x
-- VocXP_Camelot.toc on Forever, the 12.x VocXP.toc on retail), so
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

-- Bonus registry: the effects that change XP gain, one entry per
-- effect. Each entry names the effect, what it grants, and where it
-- comes from, in the player's terms, plus the aura that marks it live.
-- Entries carry the flavors they are verified on: retail and Forever
-- genuinely differ here, so each side lists only its own confirmed
-- effects and its own numbers.
--
-- Forever: the Cozy Sleeping Bag's Well-Rested buff (+1% per stack,
-- up to +3%, on kill and quest XP) and cooked food's Well Fed (+5%
-- kill XP only, and only foods whose tooltip promises it). The
-- rested pool itself needs no entry -- the bar's reach lines already
-- report it -- and neither do the Camp Tent top-up or the Legacy Well
-- Rested perk, which feed the pool rather than paying per kill.
--
-- A short registry that is right beats a long one that is guessed:
-- no War Mode, Mentored, Faire, Wickerman, or Joyous Journeys
-- anywhere, and no Rested line: the bar already answers that.
ns.REGISTRY = {
  {
    aura = 24870, -- one food's spell; the name read below finds every food's
    name = "Well Fed", -- every food's buff shares the name, so the name query sees them all
    label = "Well Fed",
    grant = "kill XP",
    hint = "eat food",
    bagWord = "food", -- any food item grants it; the bag hint looks for food, not one item
    flavors = { "retail" },
  },
  {
    -- No spell ID confirmed on Forever: the name read below is the
    -- only detection (spell names are client-locale, so an in-game
    -- check against the exact buff name is the way to confirm this).
    name = "Well Fed",
    label = "Well Fed",
    grant = "kill XP",
    pct = 5, -- cooked food with the +5% kill-XP line, kills only
    hint = "cooked food with +5% kill XP",
    flavors = { "forever" },
  },
  {
    -- The Cozy Sleeping Bag's buff, separate from normal rested XP.
    -- Stacks read from the aura's applications count; without a
    -- readable count the plain grant line shows instead of a number.
    name = "Well-Rested", -- the bag buff; not the Legacy "Well Rested" perk
    label = "Well-Rested",
    grant = "kill and quest XP",
    stacks = true,
    pctPerStack = 1,
    maxStacks = 3,
    hint = "lie in the bag",
    flavors = { "forever" },
  },
}

function ns.playerAura(spellID)
  if spellID == nil then return nil end
  if type(C_UnitAuras) ~= "table" then return nil end
  if type(C_UnitAuras.GetPlayerAuraBySpellID) ~= "function" then return nil end
  return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

function ns.hasAura(spellID)
  return ns.playerAura(spellID) ~= nil
end

-- Name-based read: every food grants its own Well Fed spell, so one ID
-- only ever covers one dish. The name query
-- (C_UnitAuras.GetAuraDataBySpellName) finds whichever food's buff is
-- live. Presence-gated and pcall-guarded like every other read here;
-- nil when the API is absent or refuses.
function ns.playerAuraByName(spellName)
  if type(C_UnitAuras) ~= "table" then return nil end
  if type(C_UnitAuras.GetAuraDataBySpellName) ~= "function" then return nil end
  local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", spellName)
  if not ok then return nil end
  return aura
end

-- One entry, every food: the name read finds any live Well Fed, and
-- the ID stays as the fallback (spell names are client-locale, IDs are not).
function ns.entryAura(entry)
  if type(entry) ~= "table" then return nil end
  if entry.name then
    local named = ns.playerAuraByName(entry.name)
    if named ~= nil then return named end
  end
  return ns.playerAura(entry.aura)
end

function ns.hasEntryAura(entry)
  return ns.entryAura(entry) ~= nil
end

-- An entry applies on the current client when it names no flavors or
-- names this one. Retail and Forever genuinely differ, so flavored
-- entries never leak across.
function ns.entryApplies(entry)
  if type(entry) ~= "table" then return false end
  if type(entry.flavors) ~= "table" then return true end
  local here = ns.clientFlavor()
  for _, flavor in ipairs(entry.flavors) do
    if flavor == here then return true end
  end
  return false
end

-- Stack count for a stacking entry, clamped to its max, or nil when
-- the aura is absent, the entry does not stack, or the count is
-- unreadable. The count can arrive secret like the stamp below, so
-- the same guard applies.
function ns.entryStacks(entry)
  if type(entry) ~= "table" or not entry.stacks then return nil end
  local aura = ns.entryAura(entry)
  if type(aura) ~= "table" then return nil end
  local app = aura.applications
  if canaccessvalue and not canaccessvalue(app) then return nil end
  if type(app) ~= "number" or app < 1 then return nil end
  return math.min(app, entry.maxStacks or app)
end

-- The entry's current percent, or nil when it has none to print: a
-- fixed pct, or per-stack times the live stack count.
local function entryPct(entry)
  if type(entry) ~= "table" then return nil end
  if type(entry.pct) == "number" then return entry.pct end
  if entry.stacks and type(entry.pctPerStack) == "number" then
    local stacks = ns.entryStacks(entry)
    if stacks ~= nil then return entry.pctPerStack * stacks end
  end
  return nil
end

-- Remaining time on a live aura, in seconds, or nil when the client
-- does not report one. Blizzard's own BuffFrame reads
-- auraData.expirationTime against GetTime() the same way; a missing
-- aura, a missing field, a missing clock, or an expired stamp all read
-- no time, never an error. The stamp can also arrive secret, and a
-- secret errors on compare and arithmetic in addon code:
-- canaccessvalue gates both, presence-gated like every other read.
local function timeLeft(aura)
  -- The aura arrives resolved by the caller; only its stamp is read here.
  if type(aura) ~= "table" then return nil end
  local expires = aura.expirationTime
  if canaccessvalue and not canaccessvalue(expires) then return nil end
  if type(expires) ~= "number" or expires <= 0 then return nil end
  if type(GetTime) ~= "function" then return nil end
  local left = expires - GetTime()
  if type(left) ~= "number" or left <= 0 then return nil end
  return left
end

function ns.auraTimeLeft(spellID)
  return timeLeft(ns.playerAura(spellID))
end

function ns.entryTimeLeft(entry)
  return timeLeft(ns.entryAura(entry))
end

-- Food in the player's bags, read straight from the container API:
-- bag 0 is the backpack, 1..NUM_BAG_SLOTS the worn bags. Without the
-- container or item-info APIs the hint simply stays off.
-- Consumable class 0, Food & Drink subclass 5; GetItemInfoInstant is
-- the ledger-verified read.
ns.FOOD_CLASS = 0
ns.FOOD_SUBCLASS = 5

local function isFoodLink(link)
  if type(link) ~= "string" then return false end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfoInstant) ~= "function" then
    return false
  end
  local ok, _, _, _, _, _, classID, subClassID = pcall(C_Item.GetItemInfoInstant, link)
  return ok and classID == ns.FOOD_CLASS and subClassID == ns.FOOD_SUBCLASS
end

function ns.foodInBags()
  if type(C_Container) ~= "table"
      or type(C_Container.GetContainerNumSlots) ~= "function"
      or type(C_Container.GetContainerItemLink) ~= "function" then
    return false
  end
  local bags = (type(NUM_BAG_SLOTS) == "number" and NUM_BAG_SLOTS) or 4
  for bag = 0, bags do
    local okSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
    if okSlots and type(slots) == "number" then
      for slot = 1, slots do
        local okLink, link = pcall(C_Container.GetContainerItemLink, bag, slot)
        if okLink and isFoodLink(link) then return true end
      end
    end
  end
  return false
end

-- Aura reads go blind in instances: the API returns nil there for
-- present world-granted buffs, so the registry scan gates on this and
-- says so instead of false absence.
function ns.inInstance()
  if type(IsInInstance) ~= "function" then return false end
  return IsInInstance() == true
end

-- Rep buffs, all +10%: the Faire pair, the Wickerman pair, and the
-- Pilgrim's Bounty Spirit of Sharing (rep-only). Reputation bonuses
-- at max level keep the list they already had.
ns.REP_BUFFS = {
  { id = 46668, label = "+10% WHEE!", pct = 10 },
  { id = 136583, label = "+10% Darkmoon Top Hat", pct = 10 },
  { id = 24705, label = "+10% Grim Visage", pct = 10 },
  { id = 95987, label = "+10% Unburdened", pct = 10 },
  { id = 61849, label = "+10% Spirit of Sharing", pct = 10 },
}

-- Every slash toggle confirms audibly (voc-addons principle 3).
local function click(on)
  ns.play(on and "on" or "off")
end

-- Highest value first; lines without a number trail in insertion
-- order, so the sort is stable. Shared by the active and missing lists.
local function sortByValue(parts)
  table.sort(parts, function(a, b)
    if (a.pct or -1) ~= (b.pct or -1) then return (a.pct or -1) > (b.pct or -1) end
    return a.seq < b.seq
  end)
end

-- Bonus lines, highest value first. Leveling lines come from the
-- registry only: one line per live effect, with its remaining time
-- when the client reports one. The bar already shows rested reach,
-- so Rested has no line here; effects the client cannot confirm
-- have no entry at all.
local function bonusParts()
  local parts = {}
  local function add(pct, label)
    parts[#parts + 1] = { pct = pct, label = label, seq = #parts + 1 }
  end
  if mode == "rep" then
    local restricted = ns.inInstance()
    for _, buff in ipairs(ns.REP_BUFFS) do
      if not restricted and ns.hasAura(buff.id) then add(buff.pct, buff.label) end
    end
    local tracked = ns.repTracked()
    local progress = tracked and ns.readRepProgress(tracked) or nil
    if progress and progress.bonus then add(nil, "Bonus rep gain") end
    sortByValue(parts)
    local labels = {}
    for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
    return labels
  end
  if not ns.inInstance() then
    for _, entry in ipairs(ns.REGISTRY) do
      if ns.entryApplies(entry) and ns.hasEntryAura(entry) then
        local pct = entryPct(entry)
        local left = ns.entryTimeLeft(entry)
        local head = entry.label .. " · " .. entry.grant
        if pct then head = "+" .. pct .. "% " .. entry.label end
        if left then head = head .. " (" .. ns.formatEta(left) .. " left)" end
        add(pct, head)
      end
    end
  end
  sortByValue(parts)
  local labels = {}
  for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
  return labels
end

-- The missing half of the registry: one dimmed reminder per effect
-- that is not live, naming where it comes from, with the in-bags hint
-- when the granting food sits in the player's bags. No rested line
-- here either; the bar already answers that. In instances the aura
-- scan goes blind, so the scan line replaces the list instead of
-- guessing absence.
local function missingParts()
  local parts = {}
  local function add(pct, label)
    parts[#parts + 1] = { pct = pct, label = label, seq = #parts + 1 }
  end
  if mode == "rep" then
    if ns.inInstance() then
      add(nil, "Aura scan unavailable in instances")
    end
    sortByValue(parts)
    local labels = {}
    for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
    return labels
  end
  if ns.inInstance() then
    add(nil, "Aura scan unavailable in instances")
    sortByValue(parts)
    local labels = {}
    for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
    return labels
  end
  local bagged = nil
  for _, entry in ipairs(ns.REGISTRY) do
    if ns.entryApplies(entry) and not ns.hasEntryAura(entry) then
      local hint = entry.hint
      if entry.bagWord then
        if bagged == nil then bagged = ns.foodInBags() end
        if bagged then hint = entry.bagWord .. " in bags" end
      end
      add(entry.pct, entry.label .. " · " .. entry.grant .. " (" .. hint .. ")")
    end
  end
  sortByValue(parts)
  local labels = {}
  for _, p in ipairs(parts) do labels[#labels + 1] = p.label end
  return labels
end

-- Bar segments ---------------------------------------------------------
-- Fractions over the current level: where progress ends, how far
-- ready-to-turn-in quests reach, how far rested XP reaches beyond
-- them. The overlays STACK, in the order you would play them: banked
-- quest XP first, then rested grinding. They never overlap, so each
-- boundary is a hard edge. With no quest XP the rested reach is the
-- native projection, (xp + rested) / req. All clamped to [0, 1];
-- overlays never start before progress. An invalid or capped
-- snapshot has no bar: nil, never zeros that would paint a
-- misleading empty bar.
function ns.barSegments(snap, restedXp, questXp)
  if not ns.validateSnapshot(snap) or snap.capped then return nil end
  local r = (type(restedXp) == "number" and restedXp > 0) and restedXp or 0
  local q = (type(questXp) == "number" and questXp > 0) and questXp or 0
  -- Overflow is native-semantics only: (xp + rested) / req, ignoring
  -- the custom quest overlay the native bar never knew.
  local overflowed = (snap.xp + r) / snap.req > 1
  local progress = math.max(0, math.min(1, snap.xp / snap.req))
  local questEnd = math.max(progress, math.min(1, (snap.xp + q) / snap.req))
  local restedEnd = math.max(questEnd, math.min(1, (snap.xp + q + r) / snap.req))
  return {
    progress = progress,
    restedEnd = restedEnd,
    questEnd = questEnd,
    hasRested = r > 0,
    restedOverflow = overflowed,
    hasQuest = q > 0,
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

-- Reputation mode ------------------------------------------------------
-- At max level the bar pivots from XP to reputation. A faction of any
-- kind -- standard standing, Renown, Paragon, friendship -- normalizes
-- to one progress shape ({ id, name, kind, have, need, level,
-- levelLabel, capLabel, capped, bonus }, Paragon adding raw and
-- pending), following Blizzard's own ReputationStatusBarMixin math
-- (see .reference/api-verification.md "Reputation mode"). The rolling
-- estimator never learns the kinds: rep paints synthetic XP-shaped
-- snapshots through it with est.unit set, and only the format layer
-- speaks Rep.

-- Tracked-faction state. The ID persists in SavedVariables so a
-- reload restores it; the cache and baseline are session-only.
local repCache = {}
local repFactionID, repWatching, lastGainedID, repBaseline = nil, false, nil, nil

-- The standing ceiling. Blizzard defines MAX_REPUTATION_REACTION in
-- its own (possibly unloaded) ReputationFrame, so a missing global
-- falls back to the eight reactions that have held since 2004.
function ns.maxRepReaction()
  if type(MAX_REPUTATION_REACTION) == "number" and MAX_REPUTATION_REACTION >= 1 then
    return math.floor(MAX_REPUTATION_REACTION)
  end
  return 8
end

function ns.standingName(reaction)
  if type(reaction) == "number" and ns.STANDING_NAMES[reaction] ~= nil then
    return ns.STANDING_NAMES[reaction]
  end
  return ("Rank %s"):format(tostring(reaction))
end

-- A faction-list row is trackable when it names a real faction and
-- carries reputation (headers with rep count; plain headers don't).
function ns.validRepRow(fd)
  if type(fd) ~= "table" then return false end
  if type(fd.factionID) ~= "number" or fd.factionID == 0 then return false end
  if fd.isHeader and not fd.isHeaderWithRep then return false end
  return type(fd.name) == "string" and fd.name ~= ""
end

-- Standard standing: currentStanding between the reaction thresholds.
function ns.repStandardProgress(fd, maxReaction)
  if not ns.validRepRow(fd) then return nil end
  maxReaction = maxReaction or ns.maxRepReaction()
  local r, lo, hi, cur = fd.reaction, fd.currentReactionThreshold, fd.nextReactionThreshold, fd.currentStanding
  if type(r) ~= "number" or r < 1 or r ~= math.floor(r) then return nil end
  if type(lo) ~= "number" or type(hi) ~= "number" or type(cur) ~= "number" then return nil end
  local label = ns.standingName(math.min(r, maxReaction))
  if r >= maxReaction then
    return { id = fd.factionID, name = fd.name, kind = "standing",
      have = 1, need = 1, level = r, levelLabel = label,
      capLabel = label, capped = true, bonus = fd.hasBonusRepGain == true }
  end
  if hi <= lo or cur < lo then return nil end
  return { id = fd.factionID, name = fd.name, kind = "standing",
    have = cur - lo, need = hi - lo, level = r,
    levelLabel = label, capLabel = label, capped = false,
    bonus = fd.hasBonusRepGain == true }
end

-- Renown: currentStanding is already in-level progress over the
-- faction's level threshold (the native watch bar reads it raw).
function ns.repRenownProgress(fd, major, hasMax)
  if not ns.validRepRow(fd) then return nil end
  if type(major) ~= "table" then return nil end
  local level, threshold = major.renownLevel, major.renownLevelThreshold
  if type(level) ~= "number" or type(threshold) ~= "number" or threshold <= 0 then return nil end
  if type(fd.currentStanding) ~= "number" then return nil end
  local label = ("Renown %d"):format(math.floor(level))
  if hasMax then
    return { id = fd.factionID, name = fd.name, kind = "renown",
      have = 1, need = 1, level = level, levelLabel = label,
      capLabel = label, capped = true, bonus = fd.hasBonusRepGain == true }
  end
  local have = math.max(0, math.min(threshold, fd.currentStanding))
  return { id = fd.factionID, name = fd.name, kind = "renown",
    have = have, need = threshold, level = level, levelLabel = label,
    capLabel = label, capped = false, bonus = fd.hasBonusRepGain == true }
end

-- Paragon: the cycle position is the lifetime value modulo the
-- threshold; a pending reward pins the bar full. Never capped.
function ns.repParagonProgress(fd, currentValue, threshold, hasRewardPending)
  if not ns.validRepRow(fd) then return nil end
  if type(currentValue) ~= "number" or type(threshold) ~= "number" or threshold <= 0 then return nil end
  local have = currentValue % threshold
  if hasRewardPending then have = threshold end
  return { id = fd.factionID, name = fd.name, kind = "paragon", raw = currentValue,
    have = have, need = threshold, level = nil, levelLabel = "Paragon",
    capLabel = "Paragon", capped = false, pending = hasRewardPending == true,
    bonus = fd.hasBonusRepGain == true }
end

-- Friendship: standing between the rank thresholds; a nil next
-- threshold is max rank and paints a full bar.
function ns.repFriendshipProgress(fd, repInfo, rankInfo)
  if not ns.validRepRow(fd) then return nil end
  if type(repInfo) ~= "table" or type(rankInfo) ~= "table" then return nil end
  local reaction = type(repInfo.reaction) == "string" and repInfo.reaction or "Friend"
  local level = type(rankInfo.currentLevel) == "number" and rankInfo.currentLevel or nil
  if repInfo.nextThreshold == nil then
    return { id = fd.factionID, name = fd.name, kind = "friendship",
      have = 1, need = 1, level = level, levelLabel = reaction,
      capLabel = reaction, capped = true, bonus = fd.hasBonusRepGain == true }
  end
  local lo, hi, cur = repInfo.reactionThreshold, repInfo.nextThreshold, repInfo.standing
  if type(lo) ~= "number" or type(hi) ~= "number" or type(cur) ~= "number" then return nil end
  if hi <= lo or cur < lo then return nil end
  return { id = fd.factionID, name = fd.name, kind = "friendship",
    have = cur - lo, need = hi - lo, level = level, levelLabel = reaction,
    capLabel = reaction, capped = false, bonus = fd.hasBonusRepGain == true }
end

-- Rep gain between two progress reads of one faction. Same-kind and
-- same-level deltas are exact; a single rank-up carries the remainder
-- across; anything else (kind swap, faction swap, multi-rank jump, a
-- loss) resyncs with nil, exactly like ns.gain. Paragon has no ranks:
-- the lifetime value's non-negative delta is the gain.
function ns.repGain(old, new)
  if type(old) ~= "table" or type(new) ~= "table" then return nil end
  if old.id ~= new.id or old.kind ~= new.kind then return nil end
  if new.capped then return nil end
  if new.kind == "paragon" then
    if type(old.raw) ~= "number" or type(new.raw) ~= "number" then return nil end
    if new.raw >= old.raw then return new.raw - old.raw end
    return nil
  end
  if type(old.level) ~= "number" or type(new.level) ~= "number" then return nil end
  if type(old.have) ~= "number" or type(new.have) ~= "number" then return nil end
  if type(old.need) ~= "number" or type(new.need) ~= "number" then return nil end
  if new.level == old.level then
    if new.have >= old.have then return new.have - old.have end
    return nil
  elseif new.level == old.level + 1 then
    return math.max(0, old.need - old.have + new.have)
  end
  return nil
end

-- Bar label: the faction name with in-rank numbers, name alone at the
-- cap like the native bar, guidance when nothing is tracked.
function ns.repBarLabel(progress)
  if progress == nil then return "No faction tracked" end
  if progress.capped then return progress.name end
  local pct = math.max(0, math.min(100, math.floor(progress.have / progress.need * 100 + 0.5)))
  return ("%s  %s/%s (%d%%)"):format(progress.name, fmt(progress.have), fmt(progress.need), pct)
end

-- Stats line: rank context the bar label skips. Nil at the cap (the
-- tooltip carries it) and for unknown kinds.
function ns.repStatsLine(progress)
  if progress == nil or progress.capped then return nil end
  local pct = math.max(0, math.min(100, math.floor(progress.have / progress.need * 100 + 0.5)))
  if progress.kind == "standing" then
    return ("%s · %d%% to %s"):format(progress.levelLabel, pct, ns.standingName(progress.level + 1))
  elseif progress.kind == "renown" then
    return ("%s · %d%% to %d"):format(progress.levelLabel, pct, progress.level + 1)
  elseif progress.kind == "paragon" then
    return ("Paragon · %d%% to reward"):format(pct)
  elseif progress.kind == "friendship" then
    return ("%s · %d%% to next rank"):format(progress.levelLabel, pct)
  end
  return nil
end

-- Fill art for a tracked faction: the reaction row, blue for Renown
-- and major-faction Paragon, forced green for friendships. A missing
-- or wild reaction reads friendly rather than erroring.
function ns.repAtlas(progress)
  if progress.kind == "renown" or progress.blue then
    return ns.REP_FILL_BLUE, ns.REP_FLARE_BLUE, ns.REP_LEVELUP_BLUE
  end
  local row = progress.kind == "friendship" and 5 or progress.level
  if type(row) ~= "number" or row < 1 or row > 8 then row = 5 end
  row = math.floor(row)
  return ns.REP_FILL[row], ns.REP_FLARE[row], ns.REP_LEVELUP[row]
end

-- One texture swap for both modes: the animated template takes atlas
-- names, the plain-bar fallback paints its fill texture instead.
local function applyBarArt(fillAtlas, flareAtlas, levelupAtlas)
  if type(bar.SetBarTexture) == "function" then
    pcall(bar.SetBarTexture, bar, fillAtlas)
  elseif type(bar.GetStatusBarTexture) == "function" then
    local fill = bar:GetStatusBarTexture()
    if fill ~= nil then pcall(function() fill:SetAtlas(fillAtlas, false) end) end
  end
  if type(bar.SetAnimationTextures) == "function" then
    pcall(bar.SetAnimationTextures, bar, flareAtlas, levelupAtlas)
  end
end

-- Presence-gated readers. Every C_* call below verified ok/ok (see
-- the verification record); a missing namespace still degrades to
-- nil, never an error.
local function watchedFaction()
  if type(C_Reputation) ~= "table" then return nil end
  if type(C_Reputation.GetWatchedFactionData) ~= "function" then return nil end
  local fd = C_Reputation.GetWatchedFactionData()
  if not ns.validRepRow(fd) then return nil end
  return fd
end

-- Full progress for one faction ID, dispatching paragon -> renown ->
-- friendship -> standard like the native watch bar. An unreadable
-- kind reads nil instead of falling through to a wrong one; a
-- missing kind API does the same.
function ns.readRepProgress(factionID)
  if type(C_Reputation) ~= "table" or type(factionID) ~= "number" then return nil end
  local R = C_Reputation
  -- The watched struct is the live one native itself paints; ByID can
  -- lag it (3000 vs 1803 seen live on a renown faction), so the
  -- watched faction always reads through GetWatchedFactionData.
  local fd = nil
  local watched = watchedFaction()
  if watched ~= nil and watched.factionID == factionID then
    fd = watched
  elseif type(R.GetFactionDataByID) == "function" then
    fd = R.GetFactionDataByID(factionID)
  end
  if not ns.validRepRow(fd) then return nil end
  if type(R.IsFactionParagonForCurrentPlayer) == "function"
      and R.IsFactionParagonForCurrentPlayer(factionID) then
    if type(R.GetFactionParagonInfo) ~= "function" then return nil end
    local currentValue, threshold, _, hasRewardPending = R.GetFactionParagonInfo(factionID)
    local paragon = ns.repParagonProgress(fd, currentValue, threshold, hasRewardPending)
    if paragon and type(R.IsMajorFaction) == "function" and R.IsMajorFaction(factionID) then
      paragon.blue = true
    end
    return paragon
  end
  if type(R.IsMajorFaction) == "function" and R.IsMajorFaction(factionID) then
    if type(C_MajorFactions) ~= "table"
        or type(C_MajorFactions.GetMajorFactionData) ~= "function"
        or type(C_MajorFactions.HasMaximumRenown) ~= "function" then return nil end
    return ns.repRenownProgress(fd, C_MajorFactions.GetMajorFactionData(factionID),
      C_MajorFactions.HasMaximumRenown(factionID))
  end
  if type(C_GossipInfo) == "table"
      and type(C_GossipInfo.GetFriendshipReputation) == "function"
      and type(C_GossipInfo.GetFriendshipReputationRanks) == "function" then
    local repInfo = C_GossipInfo.GetFriendshipReputation(factionID)
    if type(repInfo) == "table" and type(repInfo.friendshipFactionID) == "number"
        and repInfo.friendshipFactionID > 0 then
      return ns.repFriendshipProgress(fd, repInfo,
        C_GossipInfo.GetFriendshipReputationRanks(repInfo.friendshipFactionID))
    end
  end
  return ns.repStandardProgress(fd)
end

-- Gain scan: re-read every visible faction row and diff standings
-- against the cache, returning the ID with the largest increase (or
-- nil). Paragon rows compare lifetime values and friendship rows
-- their own standing, the way Blizzard's ReputationFrame does;
-- Renown rows compare currentStanding like the native watch bar.
-- Decreases only resync the cache: a loss never steals tracking.
-- Collapsed headers hide their children from the index list, so a
-- collapsed faction gains never surface here; its
-- FACTION_STANDING_CHANGED payload (noted in onRep) covers
-- collapsed rows; the watched and persisted paths use ByID and
-- never depend on the scan.
local function scanStanding(R, id, standing)
  if type(R.IsFactionParagonForCurrentPlayer) == "function"
      and type(R.GetFactionParagonInfo) == "function"
      and R.IsFactionParagonForCurrentPlayer(id) then
    local currentValue = R.GetFactionParagonInfo(id)
    if type(currentValue) == "number" then return currentValue end
    return nil
  end
  if type(C_GossipInfo) == "table"
      and type(C_GossipInfo.GetFriendshipReputation) == "function" then
    local repInfo = C_GossipInfo.GetFriendshipReputation(id)
    if type(repInfo) == "table" and type(repInfo.friendshipFactionID) == "number"
        and repInfo.friendshipFactionID > 0 and type(repInfo.standing) == "number" then
      return repInfo.standing
    end
  end
  return standing
end

function ns.scanRepGains()
  if type(C_Reputation) ~= "table" then return nil end
  local R = C_Reputation
  if type(R.GetNumFactions) ~= "function" or type(R.GetFactionDataByIndex) ~= "function" then
    return nil
  end
  local ok, gained = pcall(function()
    local n = R.GetNumFactions()
    if type(n) ~= "number" then return nil end
    local bestID, bestGain = nil, 0
    for i = 1, n do
      local fd = R.GetFactionDataByIndex(i)
      if ns.validRepRow(fd) then
        local standing = scanStanding(R, fd.factionID, fd.currentStanding)
        if type(standing) == "number" then
          local prev = repCache[fd.factionID]
          repCache[fd.factionID] = standing
          if type(prev) == "number" and standing > prev and standing - prev > bestGain then
            bestID, bestGain = fd.factionID, standing - prev
          end
        end
      end
    end
    return bestID
  end)
  if ok then return gained end
  return nil
end

-- Tracked-faction resolution, first readable candidate wins: watched,
-- then the latest gainer, then the persisted ID from the last
-- session, then nothing (the untracked state). followLatest flips the
-- order to latest, persisted, watched: the bar always follows fresh
-- gains and only borrows the watched faction until the first one.
-- The choice persists, so a reload restores it; every candidate
-- revalidates to readable progress on the way in, so tracking never
-- sticks on a dead row.
function ns.resolveRepFaction()
  repWatching = false
  local watched = watchedFaction()
  local watchedID = watched ~= nil and watched.factionID or nil
  local order
  if opts().followLatest then
    order = { lastGainedID, opts().repFaction, watchedID }
  else
    order = { watchedID, lastGainedID, opts().repFaction }
  end
  repFactionID = nil
  for i = 1, 3 do -- fixed bound: the order has holes (ipairs would stop at the first nil)
    local id = order[i]
    if type(id) == "number" and ns.readRepProgress(id) then
      repFactionID = id
      repWatching = (id == watchedID)
      break
    end
  end
  opts().repFaction = repFactionID
  return repFactionID
end

function ns.repTracked()
  return repFactionID
end

function ns.repFollowingWatched()
  return repWatching
end

-- Re-resolve after a scan or a tick, restarting observation only when
-- the tracked faction actually moved. Watched changes carry no
-- event, so refresh calls this every second; the reads are cheap.
function ns.maybeSwitchRep()
  local before = repFactionID
  local rid = ns.resolveRepFaction()
  if rid ~= before then
    repBaseline = rid and ns.readRepProgress(rid) or nil
    resetTrackers()
    return true
  end
  return false
end

function ns.noteRepGain(factionID)
  if type(factionID) == "number" then lastGainedID = factionID end
end

function ns.repBaselineRead()
  return repBaseline
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
  local wantHidden = o.hideDefault and o.shown and mode ~= "dormant"
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

-- One rep estimate for the bar and the tooltip, so they never
-- disagree. Untracked carries guidance; a capped faction carries its
-- cap label; otherwise a synthetic snapshot flows through the same
-- estimator and longer ETA basis as XP.
local function repEstimate(progress)
  if progress == nil then
    return { status = "untracked", windowSeconds = rateTracker.window,
      observedSeconds = 0, windowXp = 0, idleSeconds = nil,
      xpPerHour = nil, remainingXp = nil, etaSeconds = nil, unit = "Rep" }
  end
  local now = GetTime()
  local snap
  if progress.capped then
    snap = { level = 0, xp = 1, req = 1, capped = false }
  else
    snap = { level = progress.level or 0, xp = progress.have, req = progress.need, capped = false }
  end
  local est = ns.estimate(rateTracker, now, snap, paused)
  est.unit = "Rep"
  if progress.capped and not paused then
    est.status = "rep-capped"
    est.capLabel = progress.capLabel
    est.etaSeconds = nil
    return est
  end
  local longEta = ns.etaSeconds(etaTracker, now, est.remainingXp or 0)
  if est.etaSeconds and (est.remainingXp or 0) > 0 then
    est.etaSeconds = longEta or est.etaSeconds
  end
  return est
end

local function refreshRep(o)
  ns.applyGeometry()
  ns.maybeSwitchRep()
  local progress = repFactionID and ns.readRepProgress(repFactionID) or nil
  if progress then
    if type(bar.SetAnimatedValues) == "function" then
      bar:SetAnimatedValues(progress.have, 0, progress.need, progress.level)
    else
      bar:SetMinMaxValues(0, progress.need)
      bar:SetValue(progress.have)
    end
    if o.alwaysShow then
      barText:SetText(ns.barText(repEstimate(progress)))
      barText:Show()
    else
      barText:SetText(ns.repBarLabel(progress))
    end
    applyBarArt(ns.repAtlas(progress))
  else
    if type(bar.SetAnimatedValues) == "function" then
      bar:SetAnimatedValues(0, 0, 1, nil)
    else
      bar:SetMinMaxValues(0, 1)
      bar:SetValue(0)
    end
    if o.alwaysShow then
      barText:SetText(ns.barText(repEstimate(nil)))
      barText:Show()
    else
      barText:SetText(ns.repBarLabel(nil))
    end
    applyBarArt(ns.XP_ATLAS, ns.FLARE_XP_ATLAS, ns.LEVELUP_XP_ATLAS)
  end
  -- No overlays in rep mode: rested and quest XP don't exist here.
  restFill:Hide()
  questFill:Hide()
  pip:Hide()
  applyNativeBar()
  ns.barShown(o.shown)
end

local function refresh()
  local o = opts()
  local now = GetTime()
  -- Bursts report here: deferred through combat, netted after 0.15s of quiet.
  ns.flushSummary(now)
  if mode == "dormant" then
    ns.barShown(false)
    applyNativeBar()
    return
  end
  if mode == "rep" then
    refreshRep(o)
    return
  end
  local geo = ns.applyGeometry()
  local est = ns.estimate(rateTracker, now, baseline, paused)
  -- The ETA reads the longer basis (which also prunes it); the rate
  -- window still gates whether any ETA shows at all.
  local longEta = ns.etaSeconds(etaTracker, now, est.remainingXp or 0)
  if est.etaSeconds and (est.remainingXp or 0) > 0 then
    est.etaSeconds = longEta or est.etaSeconds
  end
  local seg = ns.barSegments(baseline, restedAmount(), questXp)
  if seg then
    if type(bar.SetAnimatedValues) == "function" then
      -- Level wraps the ding animation through full and around, the
      -- way the native bar dings; maxLevel stays nil, which the
      -- template reads as never-capped, true whenever we show.
      -- Raw XP, never fractions: the template floors animated values,
      -- and the floor of a fraction is a vanished fill.
      bar:SetAnimatedValues(baseline.xp, 0, baseline.req, baseline.level)
    else
      bar:SetMinMaxValues(0, baseline.req)
      bar:SetValue(baseline.xp)
    end
    if o.alwaysShow then
      barText:SetText(ns.barText(est))
      barText:Show()
    else
      barText:SetText(ns.barLabel(baseline, seg))
    end
    local isRested = seg ~= nil and seg.hasRested
    applyBarArt(isRested and ns.RESTED_ATLAS or ns.XP_ATLAS,
      isRested and ns.FLARE_RESTED_ATLAS or ns.FLARE_XP_ATLAS,
      isRested and ns.LEVELUP_RESTED_ATLAS or ns.LEVELUP_XP_ATLAS)
    -- Native hides the prediction fill when rested overflows the bar,
    -- but only on the clients that say so: Mainline hides it, Camelot
    -- keeps the bar full. A missing API keeps the old behavior.
    if isRested and restOk and not (seg.restedOverflow and not ns.restedOverflowShown()) then
      restFill:SetWidth(seg.restedEnd * geo.troughW)
      -- Crop, never stretch: the grain maps across the full bar width,
      -- so each span keeps its native shading at any width.
      restFill:SetTexCoord(0, seg.restedEnd, 0, 1)
      restFill:Show()
    else
      restFill:Hide()
    end
    if seg ~= nil and questOk and seg.questEnd > seg.progress then
      questFill:ClearAllPoints()
      questFill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", seg.progress * geo.troughW, 0)
      questFill:SetSize((seg.questEnd - seg.progress) * geo.troughW, ns.FILL_HEIGHT)
      questFill:SetTexCoord(seg.progress, seg.questEnd, 0, 1)
      questFill:Show()
    else
      questFill:Hide()
    end
    -- The rested pip rides the rested reach, hidden at the bar edges
    -- like the native one (hideAtBarEdge), and hidden without rested.
    if pipOk and isRested and seg.restedEnd >= 0.01 and seg.restedEnd <= 0.99 then
      pip:ClearAllPoints()
      pip:SetPoint("CENTER", bar, "LEFT", seg.restedEnd * geo.troughW, geo.pipY)
      pip:Show()
    else
      pip:Hide()
    end
  end
  applyNativeBar()
  ns.barShown(o.shown)
end

-- Native hides the prediction fill when rested overflows the bar, but
-- only on the clients that say so: Mainline hides it, Camelot keeps
-- the bar full. A missing API keeps the old behavior and shows it.
function ns.restedOverflowShown()
  if type(ShouldRestedXpBarDisplayWhenOverflowing) == "function" then
    local ok, show = pcall(ShouldRestedXpBarDisplayWhenOverflowing)
    if ok then return show and true or false end
  end
  return true
end

-- The tooltip carries the engine the bar replaced: the rate line, the
-- rested and quest reach, the bonus list, and the missing list. It
-- never fires mid-drag: our own drag flag guards it, which keeps the
-- promise without touching an unverified global.
local dragging = false

function ns.showRepTip()
  if dragging then return end
  if type(GameTooltip) ~= "table" then return end
  local progress = repFactionID and ns.readRepProgress(repFactionID) or nil
  local est = repEstimate(progress)
  GameTooltip:SetOwner(frame, "ANCHOR_TOP")
  GameTooltip:ClearLines()
  GameTooltip:SetText(ns.titleText(est), COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
  GameTooltip:AddLine(ns.subText(est), COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  if progress then
    local stats = ns.repStatsLine(progress)
    if stats then
      GameTooltip:AddLine(progress.name .. ": " .. stats,
        COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
    else
      GameTooltip:AddLine(progress.name .. " — " .. progress.capLabel,
        COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
    end
    if progress.pending then
      GameTooltip:AddLine("Paragon reward pending",
        COLORS.green[1], COLORS.green[2], COLORS.green[3], true)
    end
  end
  GameTooltip:AddLine(" ", COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
  GameTooltip:AddLine("Bonuses", COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
  local bonuses = bonusParts()
  if #bonuses == 0 then
    GameTooltip:AddLine("No rep bonus", COLORS.red[1], COLORS.red[2], COLORS.red[3], true)
  else
    for _, b in ipairs(bonuses) do
      GameTooltip:AddLine(b, COLORS.green[1], COLORS.green[2], COLORS.green[3], true)
    end
  end
  for _, m in ipairs(missingParts()) do
    GameTooltip:AddLine(m, COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  end
  if progress then
    GameTooltip:AddLine(repWatching and "Following watched faction" or "Following latest gains",
      COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  end
  GameTooltip:Show()
end

function ns.showTip()
  if dragging then return end
  if type(GameTooltip) ~= "table" then return end
  if mode == "rep" then ns.showRepTip() return end
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
  GameTooltip:SetText(ns.titleText(est), COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
  GameTooltip:AddLine(ns.subText(est), COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  if seg then
    if seg.hasRested and seg.restedPct >= 0.5 then
      local pct = math.floor(seg.restedPct + 0.5)
      local num = "|cFF" .. ns.hex(COLORS.rest) .. pct .. "%|r"
      GameTooltip:AddDoubleLine("Rested:", num .. " of level",
        COLORS.text[1], COLORS.text[2], COLORS.text[3],
        COLORS.text[1], COLORS.text[2], COLORS.text[3])
    end
    if questCount > 0 and seg.questEnd > seg.progress and seg.questPct >= 0.5 then
      local pct = math.floor(seg.questPct + 0.5)
      local noun = questCount == 1 and "quest" or "quests"
      local num = "|cFF" .. ns.hex(COLORS.quest) .. pct .. "%|r"
      GameTooltip:AddDoubleLine(("%d %s ready:"):format(questCount, noun), num .. " of level",
        COLORS.text[1], COLORS.text[2], COLORS.text[3],
        COLORS.text[1], COLORS.text[2], COLORS.text[3])
    end
  end
  -- Air between the readout and the bonus section, the way native
  -- tooltips group: title block, stats block, gold header, lines.
  GameTooltip:AddLine(" ", COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
  GameTooltip:AddLine("Bonuses", COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
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
  GameTooltip:Show()
end

-- Modes ------------------------------------------------------------------
-- Leveling characters track XP; max-level characters track reputation
-- (or go dormant when repMode is off). Each mode owns its event set;
-- entering-world, cap-change, regen, and aura signals stay registered in
-- every active mode. Entering a mode restarts observation: a rate
-- never spans two different progressions.
local ticker
local xpEvents = { "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_EQUIPMENT_CHANGED",
  "UPDATE_EXHAUSTION", "PLAYER_UPDATE_RESTING",
  "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_COMPLETE",
  "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }
local repEvents = { "UPDATE_FACTION", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "FACTION_STANDING_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }

local function setEvents(list, on)
  for _, e in ipairs(list) do
    if on then frame:RegisterEvent(e) else frame:UnregisterEvent(e) end
  end
end

local function enterXPMode()
  mode = "xp"
  repBaseline = nil
  setEvents(repEvents, false)
  setEvents(xpEvents, true)
  frame:RegisterEvent("UNIT_AURA")
  if not ticker and type(C_Timer) == "table"
      and type(C_Timer.NewTicker) == "function" then
    ticker = C_Timer.NewTicker(1, refresh)
  end
end

local function enterRepMode()
  mode = "rep"
  setEvents(xpEvents, false)
  setEvents(repEvents, true)
  frame:RegisterEvent("UNIT_AURA")
  if not ticker and type(C_Timer) == "table"
      and type(C_Timer.NewTicker) == "function" then
    ticker = C_Timer.NewTicker(1, refresh)
  end
  repCache = {}
  ns.scanRepGains() -- seed the cache: arriving gains diff, nothing awards
  local id = ns.resolveRepFaction()
  repBaseline = id and ns.readRepProgress(id) or nil
  resetTrackers()
  paused = false
  local o = opts()
  if not o.repAnnounced then
    o.repAnnounced = true
    ns.say("tracking reputation at max level (/vxp config to turn it off)")
  end
end

local function enterDormant()
  mode = "dormant"
  ns.barShown(false)
  paused = false
  if ticker then ticker:Cancel() ticker = nil end
  setEvents(xpEvents, false)
  setEvents(repEvents, false)
  frame:UnregisterEvent("UNIT_AURA")
  applyNativeBar()
end

-- Enter the mode a snapshot calls for. Entering rep mode or waking
-- from dormancy restarts observation; callers already reset when the
-- character itself changed.
local function activateMode(snap)
  if snap.capped and opts().repMode then
    if mode ~= "rep" then enterRepMode() end
  elseif snap.capped then
    enterDormant()
  elseif mode ~= "xp" then
    resetTrackers()
    paused = false
    enterXPMode()
  else
    enterXPMode()
  end
end

-- Effective max level, mirroring GameRulesUtil.GetEffectiveMaxLevelForPlayer
-- (Blizzard_SharedXML/GameRulesUtil.lua): timerunners compare against the
-- latest expansion, everyone else against their own, capped by the
-- per-player max. Missing pieces degrade toward GetMaxPlayerLevel,
-- then toward nothing (nil = unknown).
function ns.effectiveMaxLevel()
  local latest, expansion, perPlayer
  if type(GetMaxLevelForLatestExpansion) == "function" then
    latest = GetMaxLevelForLatestExpansion()
  end
  if type(GetMaxLevelForPlayerExpansion) == "function" then
    expansion = GetMaxLevelForPlayerExpansion()
  end
  if type(GetMaxPlayerLevel) == "function" then perPlayer = GetMaxPlayerLevel() end
  if type(latest) ~= "number" or type(expansion) ~= "number" or type(perPlayer) ~= "number" then
    if type(perPlayer) == "number" then return perPlayer end
    return nil
  end
  local timerunning = type(PlayerIsTimerunning) == "function" and PlayerIsTimerunning()
  local trial = type(IsTrialAccount) == "function" and IsTrialAccount()
  local expansionMax = (timerunning and not trial) and latest or expansion
  return math.min(expansionMax, perPlayer)
end

-- Capped test, mirroring GameRulesUtil.IsPlayerAtEffectiveMaxLevel:
-- a level comparison, never UnitXPMax == 0. At cap the client now
-- reports a phantom requirement (100M seen live on a 90) instead of
-- zeroing, so max == 0 survives only as the last-resort fallback
-- when no max-level API exists at all.
function ns.isLevelCapped(level, max)
  if type(level) ~= "number" then return false end
  local cap = ns.effectiveMaxLevel()
  if type(cap) == "number" then return level >= cap end
  return max == 0
end

local function readSnapshot()
  local max, level = UnitXPMax("player"), UnitLevel("player")
  if ns.isLevelCapped(level, max) then return { level = level, xp = 0, req = 1, capped = true } end
  return { level = level, xp = UnitXP("player"), req = max, capped = false }
end

-- Rank-up line for the tracked faction: one chat fact when the new
-- progress sits exactly one rank above the old, or when a Paragon
-- reward flips to pending. Same-level gains stay silent (the rate owns
-- them); anything else resyncs silently like ns.repGain.
function ns.repRankMessage(old, new)
  if type(old) ~= "table" or type(new) ~= "table" then return nil end
  if new.capped then return nil end
  if new.kind == "paragon" then
    if new.pending and not old.pending then
      return "paragon reward ready with " .. new.name
    end
    return nil
  end
  if old.id ~= new.id or old.kind ~= new.kind then return nil end
  if type(old.level) ~= "number" or type(new.level) ~= "number" then return nil end
  if new.level ~= old.level + 1 then return nil end
  local label = new.levelLabel
  if new.kind == "renown" then
    label = ("renown %d"):format(new.level)
  end
  if type(label) ~= "string" or label == "" then label = "a new rank" end
  return ("rank up with %s: %s"):format(new.name, label:lower())
end
-- Rep gains arrive as faction updates: rescan for the latest gainer,
-- re-resolve (following it when nothing is watched), then reconstruct
-- at most one award for the tracked faction from its baseline delta,
-- exactly like the XP path.
-- The index scan cannot see collapsed rows, so a gain there never
-- surfaces as a latest gainer (the bar keeps the old faction while
-- chat announces the new one). FACTION_STANDING_CHANGED carries the
-- gainer faction ID outright, ByID-readable whatever the headers do,
-- so the payload is the primary signal and the scan stays the
-- fallback for UPDATE_FACTION, which carries none.
--
-- Paragon lifetime values and friendship standings live outside
-- FactionData.currentStanding (readRepProgress never sources them
-- there), so the payload standing only compares for
-- standard/renown rows; anything else follows when readable.
local function notePayloadGain(factionID, updatedStanding)
  if type(factionID) ~= "number" then return end
  local special = false
  if type(C_Reputation) == "table"
      and type(C_Reputation.IsFactionParagonForCurrentPlayer) == "function"
      and C_Reputation.IsFactionParagonForCurrentPlayer(factionID) then
    special = true
  end
  if not special and type(C_GossipInfo) == "table"
      and type(C_GossipInfo.GetFriendshipReputation) == "function" then
    local repInfo = C_GossipInfo.GetFriendshipReputation(factionID)
    if type(repInfo) == "table" and type(repInfo.friendshipFactionID) == "number"
        and repInfo.friendshipFactionID > 0 then
      special = true
    end
  end
  if not special and type(repCache[factionID]) == "number"
      and type(updatedStanding) == "number"
      and updatedStanding <= repCache[factionID] then
    -- A loss or a no-op resyncs the cache like the scan: it never
    -- steals tracking.
    repCache[factionID] = updatedStanding
    return
  end
  -- First sighting (a collapsed row has no cache entry) follows: the
  -- resolver revalidates readability, so a dead row never sticks.
  ns.noteRepGain(factionID)
end

local function onRep(gainedID, updatedStanding, renownLevel)
  if renownLevel then
    -- A renown level-up is a gain by definition: the in-level
    -- standing resets low and reads as a loss to standing compares.
    ns.noteRepGain(gainedID)
  else
    notePayloadGain(gainedID, updatedStanding)
  end
  ns.noteRepGain(ns.scanRepGains())
  if ns.maybeSwitchRep() then
    refresh()
    return
  end
  if repFactionID then
    local snap = ns.readRepProgress(repFactionID)
    if snap == nil then
      -- Tracked faction went unreadable: resolve again (usually the
      -- untracked state) instead of awarding against stale reads.
      ns.maybeSwitchRep()
    else
      if not paused then
        local award = ns.repGain(repBaseline, snap)
        if award then
          local stamp = GetTime()
          ns.addAward(rateTracker, stamp, award)
          ns.addAward(etaTracker, stamp, award)
          ns.noteSummaryGain(stamp, "rep", repFactionID, snap.name, award)
        end
      end
      local rankMsg = ns.repRankMessage(repBaseline, snap)
      if rankMsg then ns.say(rankMsg) end
      repBaseline = snap
    end
  end
  refresh()
end

-- The XP bar is the single authoritative award source: each update
-- reconstructs at most one gain from the snapshot delta and stamps it
-- with the receipt time. Actual awarded XP already includes every
-- bonus, so nothing is ever multiplied twice.
local function onXP()
  local snap = readSnapshot()
  if snap.capped then
    baseline = snap
    activateMode(snap)
    return
  end
  if not paused then
    local gained = ns.gain(baseline, snap)
    if gained then
      local stamp = GetTime()
      ns.addAward(rateTracker, stamp, gained)
      ns.addAward(etaTracker, stamp, gained)
      ns.noteSummaryGain(stamp, "xp", nil, nil, gained)
    end
  end
  baseline = snap
  refresh()
end

-- The ding: one chat fact when the fresh snapshot sits above the
-- baseline level, then a resync with no award -- the XP path stays the
-- single authoritative award source, so event order cannot
-- double-count it. A repeat event at the same level only resyncs; a
-- ding to cap pivots modes below. Announced outside pause: the line
-- is a fact about the character, not tracked data. The fanfare itself
-- stays the client's own: no SOUNDKIT name for it exists in
-- Blizzard's UI source, so the addon adds no sound of its own.
local function onLevelUp()
  local snap = readSnapshot()
  if baseline ~= nil
      and type(baseline.level) == "number" and type(snap.level) == "number"
      and snap.level > baseline.level then
    ns.say(("level %d reached"):format(snap.level))
  end
  baseline = snap
  if snap.capped then activateMode(snap) end
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
    "Show the bar: XP with XP/hr and bonuses while leveling, reputation with Rep/hr at max level.",
    function() refresh() end)
  check("alwaysShow", "Always show bar text",
    "Keep the XP/hr and time-to-level line on the bar at all times instead of showing it on hover only.",
    function() refresh() if not opts().alwaysShow then ns.hideBarLabel() end end)
  check("hideDefault", "Hide the default XP bar",
    "Hide Blizzard's status bar cluster while VocXP shows. Watched reputation and honor bars hide with it.",
    function() refresh() end)
  check("repMode", "Track reputation at max level",
    "At max level, follow the watched faction (or the latest gains) with Rep/hr and time to the next rank.",
    function() activateMode(readSnapshot()) refresh() end)
  check("followLatest", "Follow latest reputation gains",
    "In reputation mode, always track the faction you most recently earned, even when another faction is watched.",
    function() if mode == "rep" then ns.maybeSwitchRep() end refresh() end)
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
frame:RegisterEvent("PLAYER_MAX_LEVEL_UPDATE")
frame:SetScript("OnEvent", function(_, event, arg1, arg2)
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
  elseif event == "PLAYER_MAX_LEVEL_UPDATE" then
    -- Cap raised (or lowered): re-derive the mode from a fresh
    -- snapshot. A raise wakes everything; staying capped is a no-op.
    baseline = readSnapshot()
    activateMode(baseline)
    refresh()
    return
  elseif event == "PLAYER_ENTERING_WORLD" then
    ns.db = VocXPDB or ns.db -- client replaced the file-top table
    ns.ensureSettings()
    ns.subscribeEditMode()
    local o = opts()
    frame:ClearAllPoints()
    frame:SetPoint(o.point, UIParent, o.point, o.x, o.y)
    local snap = readSnapshot()
    local id = UnitGUID("player")
    local switched = id ~= identity
    if switched or mode == "dormant" then
      -- New character, first login, or waking from dormancy: fresh
      -- window and a fresh observation gate. Zone loads on the same
      -- character keep history; travel is tracked time.
      identity = id
      resetTrackers()
      paused = false
    end
    baseline = snap -- zone loads carry no timestamped gains: resync, add nothing
    if snap.capped and o.repMode then
      if mode == "rep" and not switched then
        -- Zone load inside rep mode: silent resync, history kept.
        ns.scanRepGains()
        ns.maybeSwitchRep()
        local rid = ns.repTracked()
        repBaseline = rid and ns.readRepProgress(rid) or nil
      else
        enterRepMode()
      end
    else
      activateMode(snap)
    end
    if mode == "xp" then ns.scanQuestXp() end
    ns.checkRivals() -- a loaded rival bar warns once here; never fought
    if mode ~= "dormant" and o.hideDefault and o.shown and not o.barAnnounced then
      o.barAnnounced = true
      ns.say("the default XP bar hides while VocXP shows (/vxp config to change it)")
    end
  else
    if event == "UNIT_AURA" then
      if arg1 ~= "player" then return end
    elseif event == "PLAYER_XP_UPDATE" then
      onXP()
    elseif event == "PLAYER_LEVEL_UP" then
      onLevelUp()
    elseif event == "UPDATE_FACTION" then
      onRep()
    elseif event == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" then
      onRep(arg1, nil, true)
    elseif event == "FACTION_STANDING_CHANGED" then
      onRep(arg1, arg2, false)
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_TURNED_IN"
        or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED"
        or event == "QUEST_COMPLETE" then
      ns.scanQuestXp()
    end
    -- PLAYER_EQUIPMENT_CHANGED, UPDATE_EXHAUSTION, and
    -- PLAYER_UPDATE_RESTING fall through to a bare re-render: a gear
    -- swap or a rest change only re-renders, which refreshes the
    -- rested and quest lines at once. A ding never adds an award:
    -- onLevelUp resyncs with no gain, so event order cannot
    -- double-count it.
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
  o.point, o.x, o.y = point, math.floor(x + 0.5), math.floor(y + 0.5)
end)
frame:SetScript("OnEnter", function() ns.showBarLabel() ns.showTip() end)
frame:SetScript("OnLeave", function()
  ns.hideBarLabel()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end)

-- The one main action: show or hide the bar. Shared by the bare
-- slash command and the addon compartment.
function ns.toggle()
  local o = opts()
  o.shown = not o.shown
  refresh()
  if mode == "dormant" then
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

-- Rival XP/reputation bars. Other addons are guests (FAMILY.md): when an
-- addon known to paint its own XP or reputation bar is loaded, say so
-- once and suggest ours hide. Never touch the rival: no disable, no
-- hiding its frames, no fighting it.
-- Evidence: ElvUI's experience databars (tukui-org/ElvUI wiki,
-- "performance optimization retail"); Bartender4's bundled XP/Reputation
-- bar (CurseForge listing); Dominos' bundled XP bar (Experiencer's note
-- to "use Dominos or Bartender" to hide the Blizzard XP bar).
ns.RIVALS = { "ElvUI", "Bartender4", "Dominos" }
local rivalsWarned = false
function ns.checkRivals()
  if rivalsWarned then return false end
  if not opts().shown or mode == "dormant" then return false end
  if type(C_AddOns) ~= "table" or type(C_AddOns.IsAddOnLoaded) ~= "function" then return false end
  local hit = nil
  for _, addon in ipairs(ns.RIVALS) do
    local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, addon)
    if ok and loaded then hit = addon break end
  end
  if hit == nil then return false end
  rivalsWarned = true
  ns.say(hit .. " is loaded: two XP bars may show (/vxp hides ours)")
  return true
end

-- Addon compartment (FAMILY.md "Addon compartment"): the toc names
-- these three globals; Blizzard's compartment menu calls them with
-- (addonName, button). Left and middle toggle like the bare slash;
-- right opens Settings; any click in combat no-ops. Hover keeps
-- the tooltip contract: gold title, one line, the slash hint.
function VocXP_CompartmentClick(_, button)
  if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
  if button == "RightButton" then ns.openConfig() else ns.toggle() end
end

function VocXP_CompartmentEnter(_, button)
  if type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  GameTooltip:ClearLines()
  GameTooltip:SetText("VocXP", COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
  GameTooltip:AddLine("Session XP/hr and bonuses on an elegant XP bar; reputation at max level.",
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
  "/vxp rep       reputation tracking on or off",
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
      if mode == "rep" then repBaseline = repFactionID and ns.readRepProgress(repFactionID) or nil end
    end
    refresh()
    click(paused)
    ns.say(paused and "paused" or "resumed")
  elseif msg == "reset" then
    resetTrackers()
    baseline = readSnapshot()
    paused = false
    refresh()
    if mode == "rep" then repBaseline = repFactionID and ns.readRepProgress(repFactionID) or nil end
    click(true)
    ns.say("session reset")
  elseif msg == "rep" then
    local o = opts()
    o.repMode = not o.repMode
    if o.repMode then
      -- On at cap wakes rep mode at once; leveling picks it up at the cap.
      activateMode(readSnapshot())
    elseif mode == "rep" then
      enterDormant()
    end
    refresh()
    click(o.repMode)
    ns.say(o.repMode and "reputation tracking on" or "reputation tracking off")
  elseif msg == "config" then
    ns.openConfig()
  else
    ns.help()
  end
end
