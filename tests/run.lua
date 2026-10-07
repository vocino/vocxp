-- VocXP regression tests. Stub-harness: no WoW client needed.
-- Run from anywhere:  lua tests/run.lua   (repo root also fine)
-- Works on Lua 5.1 (the client's dialect) and 5.2+.
--
-- Convention: each test builds a fresh stub world, drives the frame's
-- OnEvent/OnDrag scripts or the slash handler, and asserts. Any failed
-- assert aborts with the test name.

local testDir = debug.getinfo(1, "S").source:gsub("\\", "/"):match("@?(.*/)") or ""
local mainPath = testDir .. "../main.lua"

local passed = 0
local function check(name, cond)
  if not cond then error("FAIL: " .. name, 2) end
  passed = passed + 1
end

-- Expected readout: title line, body lines, body color.
local GREEN_C = { 0.25, 1, 0.25 }
local RED_C = { 1, 0.25, 0.25 }
local function readout(w, title, body, c)
  local bc = w.frame.body.color or {}
  return w.frame.title.text == title
    and w.frame.body.text == body
    and bc[1] == c[1] and bc[2] == c[2] and bc[3] == c[3]
end

-- Fresh stub world per test.
local function loadAddon(world)
  local g = {}
  for k, v in pairs(_G) do g[k] = v end -- inherit stdlib (string, table...)
  g._G = g
  g.print = function(...) world.printed[#world.printed + 1] = table.concat({...}, " ") end
  g.strtrim = function(s) return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1")) end
  g.GetTime = function() return world.now end
  g.UnitXP = function() return world.xp end
  g.UnitXPMax = function() return world.max end
  g.UnitLevel = function() return world.level end
  g.UnitGUID = function() return world.guid end
  g.GetXPExhaustion = function() return world.rested and 1 or nil end
  g.C_PvP = {
    IsWarModeDesired = function() return world.warMode end,
    GetWarModeRewardBonus = function() return world.warBonus end,
  }
  g.C_UnitAuras = { GetPlayerAuraBySpellID = function(id) return world.auras[id] end }
  g.C_Sound = { PlaySound = function(id) world.sounds[#world.sounds + 1] = id end }
  g.C_Timer = {
    NewTicker = function(secs, fn)
      local t = { secs = secs, fn = fn }
      t.Cancel = function(self) self.cancelled = true end
      world.tickers[#world.tickers + 1] = t
      return t
    end,
  }
  g.UIParent = {}
  g.SlashCmdList = {}
  g.CreateFrame = function(ftype, _, _, template)
    local f = { events = {}, scripts = {}, ctype = ftype, template = template }
    f.SetSize = function(_, w, h) f.size = { w, h } end
    f.SetMovable = function(_, m) f.movable = m end
    f.SetClampedToScreen = function(_, c) f.clamped = (c == nil) and true or c end
    f.RegisterEvent = function(_, e) f.events[e] = true end
    f.UnregisterEvent = function(_, e) f.events[e] = nil end
    f.RegisterForDrag = function(_, b) f.dragButton = b end
    f.EnableMouse = function(_, m) f.mouse = m end
    f.SetShown = function(_, s) f.shown = s end
    f.SetBackdrop = function(_, b) f.backdrop = b end
    f.SetBackdropColor = function(_, r, gg, bb, a) f.backdropColor = { r, gg, bb, a } end
    f.SetBackdropBorderColor = function(_, r, gg, bb) f.borderColor = { r, gg, bb } end
    f.SetScript = function(_, sname, fn) f.scripts[sname] = fn end
    -- The client ignores StartMoving on a non-movable frame; emulate
    -- that so the drag tests fail if SetMovable(true) ever goes missing.
    f.StartMoving = function() if f.movable then f.moving = true end end
    f.StopMovingOrSizing = function() f.moving = false end
    f.ClearAllPoints = function() f.point = nil end
    f.SetPoint = function(_, p, _, _, x, y) f.point = { p, x, y } end
    f.GetPoint = function() return f.point[1], nil, nil, f.point[2], f.point[3] end
    f.CreateFontString = function(_, _, _, tmpl)
      local t = { template = tmpl }
      t.SetPoint = function() end
      t.SetJustifyH = function() end
      t.SetText = function(_, s) t.text = s end
      t.SetTextColor = function(_, r, gg, b) t.color = { r, gg, b } end
      t.GetStringWidth = function() return 100 end
      t.GetStringHeight = function() return 30 end
      -- Same-template strings route by creation order: main.lua creates
      -- the body before the ETA line, so the first GameTooltipText is
      -- the body and the second is the ETA line.
      if tmpl == "GameTooltipHeaderText" then f.title = t
      elseif f.body == nil then f.body = t
      else f.eta = t end
      return t
    end
    world.frames[#world.frames + 1] = f
    return f
  end
  g.VocXPDB = nil -- client hasn't restored SavedVariables at file-exec time

  local f = assert(io.open(mainPath, "r"))
  local src = f:read("*a")
  f:close()
  -- 5.1 sandboxes with setfenv; 5.2+ takes the env as load's 4th arg.
  local chunk
  if setfenv then
    chunk = assert(loadstring(src, "@" .. mainPath))
    setfenv(chunk, g)
  else
    chunk = assert(load(src, "@" .. mainPath, "t", g))
  end
  local ns = {}
  chunk("VocXP", ns)
  world.frame = world.frames[1] -- the readout frame, created at load
  world.ns = ns
  world.env = g
  return ns
end

local function newWorld()
  return { now = 1000000, xp = 0, max = 1000, level = 10, guid = "Player-11-0001",
           rested = false, warMode = false, warBonus = 10, auras = {},
           printed = {}, tickers = {}, frames = {}, sounds = {}, savedVars = nil }
end

-- Simulate the client deserializing SavedVariables (a FRESH table replaces
-- the file-top default) and then firing PLAYER_ENTERING_WORLD.
local function clientLoaded(w)
  w.env.VocXPDB = w.savedVars or {}
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
end

local function levelEvent(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_LEVEL_UP", w.level)
end

local function etaline(w)
  return w.frame.eta and w.frame.eta.text
end

-- Float-tolerant equality for rates and ETAs: exact for the integer
-- cases, honest about division rounding everywhere else.
local function close(a, b)
  return math.abs(a - b) <= math.max(1e-9 * math.abs(b), 1e-9)
end

local function xpEvent(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_XP_UPDATE")
end

-- 1. SavedVariables rebind.
do
  local w = newWorld()
  w.savedVars = { shown = false, locked = true, point = "TOPLEFT", x = 10, y = -20 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("db rebind keeps saved shown=false", ns.db.shown == false)
  check("db rebind keeps saved locked=true", ns.db.locked == true)
  check("db rebind keeps saved position", ns.db.point == "TOPLEFT" and ns.db.x == 10 and ns.db.y == -20)
  check("rebound frame hidden", w.frame.shown == false)
  check("rebound frame positioned", w.frame.point[1] == "TOPLEFT" and w.frame.point[2] == 10 and w.frame.point[3] == -20)
  check("rebound frame mouse off", w.frame.mouse == false)
end

-- 2. Fresh profile gets all defaults.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  check("fresh shown defaults true", ns.db.shown == true)
  check("fresh locked defaults false", ns.db.locked == false)
  check("fresh position defaults", ns.db.point == "CENTER" and ns.db.x == -340 and ns.db.y == 200)
  check("fresh frame shown", w.frame.shown == true)
  check("fresh frame mouse on", w.frame.mouse == true)
  check("fresh collects", w.frame.title.text == "Collecting data" and etaline(w) == "Collecting data")
end

-- 3. Drag wiring (movable so OnDragStart can move the frame).
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("frame movable", w.frame.movable == true)
  check("frame clamped", w.frame.clamped == true)
  check("frame drags on left button", w.frame.dragButton == "LeftButton")
end

-- 4. XP gain accumulates into the session rate.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 1800
  w.xp = 500
  xpEvent(w)
  check("rate text", readout(w, "6k XP/hr · last 5m", "No XP bonus", RED_C))
  check("rate eta", etaline(w) == "Next level: ~5m")
end

-- 5. Level-up carries the remainder across the bar.
do
  local w = newWorld()
  w.xp, w.max = 900, 1000
  loadAddon(w)
  clientLoaded(w)
  w.xp, w.max, w.level = 100, 2000, 11
  w.now = w.now + 3600
  xpEvent(w)
  check("level-up carries", readout(w, "2k XP/hr · last 5m", "No XP bonus", RED_C))
  check("level-up eta", etaline(w) == "Next level: ~48m")
end

-- 6. Max-level characters never show the readout.
do
  local w = newWorld()
  w.xp, w.max = 0, 0
  loadAddon(w)
  clientLoaded(w)
  check("max level hidden", w.frame.shown == false)
end
do -- cap raised later: next login wakes everything back up
  local w = newWorld()
  w.xp, w.max = 0, 0
  loadAddon(w)
  clientLoaded(w)
  w.max = 100000
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("cap raise reshows", w.frame.shown == true)
  check("cap raise restarts ticker", #w.tickers == 1)
  check("cap raise collects", w.frame.title.text == "Collecting data" and etaline(w) == "Collecting data")
end
do -- toggle at max level keeps the pref but says so
  local w = newWorld()
  w.xp, w.max = 0, 0
  loadAddon(w)
  clientLoaded(w)
  w.env.SlashCmdList.VOCXP("")
  check("max toggle stays hidden", w.frame.shown == false)
  check("max toggle announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: max level (stays hidden).")
end

-- 7. Bonus lines.
do
  local w = newWorld()
  w.warMode = true
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode line", readout(w, "0 XP/hr · last 1m", "+10% War Mode", GREEN_C))
  check("war mode eta", etaline(w) == "No recent XP")
end
do
  local w = newWorld()
  w.rested = true
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("rested line", readout(w, "0 XP/hr · last 1m", "Rested", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.rested = true, true
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("bonuses stack", readout(w, "0 XP/hr · last 1m", "+10% War Mode\nRested", GREEN_C))
end
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("no bonus line", readout(w, "0 XP/hr · last 1m", "No XP bonus", RED_C))
end
do -- Call to Arms raises the Enlisted value above the +10% base
  local w = newWorld()
  w.warMode, w.warBonus = true, 15
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode live value", readout(w, "0 XP/hr · last 1m", "+15% War Mode", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.warBonus = true, 30
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode high call", readout(w, "0 XP/hr · last 1m", "+30% War Mode", GREEN_C))
end
do -- missing bonus API falls back to the +10% base
  local w = newWorld()
  w.warMode = true
  loadAddon(w)
  w.env.C_PvP = { IsWarModeDesired = function() return true end }
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode fallback", readout(w, "0 XP/hr · last 1m", "+10% War Mode", GREEN_C))
end
do -- out-of-range value is not trusted
  local w = newWorld()
  w.warMode, w.warBonus = true, 5000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode range gate", readout(w, "0 XP/hr · last 1m", "+10% War Mode", GREEN_C))
end

-- 8. The ticker refreshes the rate between XP events.
do
  local w = newWorld()
  w.xp, w.max = 0, 100000
  loadAddon(w)
  clientLoaded(w)
  check("ticker registered", #w.tickers == 1 and w.tickers[1].secs == 1)
  w.now = w.now + 10
  w.xp = 3600
  xpEvent(w)
  check("early gain collects", w.frame.title.text == "Collecting data")
  w.now = w.now + 290
  w.tickers[1].fn()
  check("ticker holds window", readout(w, "43k XP/hr · last 5m", "No XP bonus", RED_C))
  check("ticker eta", etaline(w) == "Next level: ~2h14m")
  w.now = w.now + 11
  w.tickers[1].fn()
  check("ticker expires award", readout(w, "0 XP/hr · last 5m", "No XP bonus", RED_C))
  check("expired eta", etaline(w) == "No recent XP")
end

-- 9. /vxp toggles the readout.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("slash registered", w.env.SLASH_VOCXP1 == "/vxp" and w.env.SlashCmdList.VOCXP ~= nil)
  local slash = w.env.SlashCmdList.VOCXP
  slash("")
  check("slash hides", w.frame.shown == false)
  check("slash hide announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: hidden.")
  slash("")
  check("slash shows", w.frame.shown == true)
  check("slash show announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: shown.")
end

-- 10. /vxp lock toggles mouse input.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  slash("lock")
  check("lock disables mouse", w.frame.mouse == false)
  check("lock announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: locked.")
  slash("  LOCK  ")
  check("lock toggles back", w.frame.mouse == true)
  check("unlock announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: unlocked. Drag to move.")
end

-- 11. /vxp reset zeroes the session.
do
  local w = newWorld()
  w.xp, w.max = 0, 100000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 5000
  xpEvent(w)
  w.now = w.now + 100
  w.env.SlashCmdList.VOCXP("reset")
  check("reset collects", w.frame.title.text == "Collecting data" and etaline(w) == "Collecting data")
  check("reset announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: session reset.")
  w.now = w.now + 60
  w.xp = 6000
  xpEvent(w)
  check("reset clears history", readout(w, "60k XP/hr · last 1m · warming up", "No XP bonus", RED_C))
end

-- 12. Dragging persists the position; locked drags don't move.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnDragStart(w.frame)
  check("drag starts moving", w.frame.moving == true)
  w.frame.point = { "TOPLEFT", 50, -60 } -- the client moved it
  w.frame.scripts.OnDragStop(w.frame)
  check("drag stops", w.frame.moving == false)
  check("drag persists", ns.db.point == "TOPLEFT" and ns.db.x == 50 and ns.db.y == -60)
end
do
  local w = newWorld()
  w.savedVars = { locked = true }
  loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnDragStart(w.frame)
  check("locked drag blocked", w.frame.moving ~= true)
end

-- 13. XP-buff auras join the bonus line.
do
  local w = newWorld()
  w.auras[430191] = { points = { 20 } }
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("mentored line", readout(w, "0 XP/hr · last 1m", "+20% Warband Mentored", GREEN_C))
end
do
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("whee line", readout(w, "0 XP/hr · last 1m", "+10% WHEE!", GREEN_C))
end
do
  local w = newWorld()
  w.auras[136583] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("top hat line", readout(w, "0 XP/hr · last 1m", "+10% Darkmoon Top Hat", GREEN_C))
end
do
  local w = newWorld()
  w.auras[24705] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("grim visage line", readout(w, "0 XP/hr · last 1m", "+10% Grim Visage", GREEN_C))
end
do
  local w = newWorld()
  w.auras[95987] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("unburdened line", readout(w, "0 XP/hr · last 1m", "+10% Unburdened", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.rested = true, true
  w.auras[430191], w.auras[46668] = { points = { 20 } }, {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("all bonuses stack in order", readout(w, "0 XP/hr · last 1m",
    "+10% War Mode\n+20% Warband Mentored\n+10% WHEE!\nRested", GREEN_C))
end
do -- missing aura API degrades to no aura lines, no error
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  w.env.C_UnitAuras = nil
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("no aura api degrades", readout(w, "0 XP/hr · last 1m", "No XP bonus", RED_C))
end

do -- mentored without a readable value shows no number
  local w = newWorld()
  w.auras[430191] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("mentored fallback", readout(w, "0 XP/hr · last 1m", "Warband Mentored", GREEN_C))
end
do -- out-of-range value is not trusted
  local w = newWorld()
  w.auras[430191] = { points = { 5000 } }
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("mentored range gate", readout(w, "0 XP/hr · last 1m", "Warband Mentored", GREEN_C))
end

-- 14. Aura changes refresh the readout.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("unit_aura registered", w.frame.events.UNIT_AURA == true)
  w.now = w.now + 45
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("no aura yet", readout(w, "0 XP/hr · last 45s", "No XP bonus", RED_C))
  w.auras[46668] = {}
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "target")
  check("other unit ignored", readout(w, "0 XP/hr · last 45s", "No XP bonus", RED_C))
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("player aura refreshes", readout(w, "0 XP/hr · last 45s", "+10% WHEE!", GREEN_C))
end

-- 15. Tooltip frame styling and auto-fit.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("backdrop template", w.frame.template == "BackdropTemplate")
  check("tooltip background", w.frame.backdrop.bgFile == "Interface\\Tooltips\\UI-Tooltip-Background")
  check("tooltip border", w.frame.backdrop.edgeFile == "Interface\\Tooltips\\UI-Tooltip-Border")
  check("backdrop colors", w.frame.backdropColor[4] == 0.85 and w.frame.borderColor[1] == 1)
  check("title uses tooltip header font", w.frame.title.template == "GameTooltipHeaderText")
  check("body uses tooltip text font", w.frame.body.template == "GameTooltipText")
  check("eta uses tooltip text font", w.frame.eta.template == "GameTooltipText")
  local tc = w.frame.title.color or {}
  check("title is house gold", tc[1] == 1 and tc[2] == 0.82 and tc[3] == 0)
  check("frame fits text", w.frame.size[1] == 120 and w.frame.size[2] == 118)
end

-- 16. Max level goes fully dormant: no ticker, no hot events.
do
  local w = newWorld()
  w.xp, w.max = 0, 0
  loadAddon(w)
  clientLoaded(w)
  check("maxed starts tickerless", #w.tickers == 0)
  check("maxed unregisters xp", w.frame.events.PLAYER_XP_UPDATE == nil)
  check("maxed unregisters aura", w.frame.events.UNIT_AURA == nil)
  check("maxed unregisters level", w.frame.events.PLAYER_LEVEL_UP == nil)
  check("maxed keeps pew wake", w.frame.events.PLAYER_ENTERING_WORLD == true)
end
do -- ding to cap mid-session shuts down
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.xp, w.max = 0, 0
  xpEvent(w)
  check("ding hides", w.frame.shown == false)
  check("ding cancels ticker", w.tickers[1].cancelled == true)
  check("ding unregisters xp", w.frame.events.PLAYER_XP_UPDATE == nil)
  check("ding unregisters aura", w.frame.events.UNIT_AURA == nil)
  check("ding unregisters level", w.frame.events.PLAYER_LEVEL_UP == nil)
end
do -- re-login after a ding restarts exactly one ticker
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.xp, w.max = 0, 0
  xpEvent(w)
  w.max = 50000
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("rewake restarts ticker", #w.tickers == 2 and w.tickers[2].cancelled ~= true)
  check("rewake reregisters", w.frame.events.PLAYER_XP_UPDATE == true and w.frame.events.UNIT_AURA == true and w.frame.events.PLAYER_LEVEL_UP == true)
  check("rewake reshows", w.frame.shown == true)
  check("rewake collects", w.frame.title.text == "Collecting data")
end
do -- repeated logins never stack tickers
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("no double ticker", #w.tickers == 1)
end

-- 17. Rolling-rate core: fake clock, deterministic snapshots.
do -- read at session start: null rate and ETA, collecting
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(1000)
  local est = ns.estimate(tr, 1000, { level = 10, xp = 0, req = 1000, capped = false }, false)
  check("start collecting", est.status == "collecting")
  check("start nulls", est.xpPerHour == nil and est.etaSeconds == nil)
  check("start zero observed", est.observedSeconds == 0 and est.windowXp == 0)
  check("start window", est.windowSeconds == 300)
  check("start remaining", est.remainingXp == 1000)
end
do -- 12,000 XP in a full 300s window: 144,000/hr, ready
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 100, 6000)
  ns.addAward(tr, 200, 6000)
  local est = ns.estimate(tr, 300, { level = 10, xp = 40000, req = 100000, capped = false }, false)
  check("full rate", close(est.xpPerHour, 144000))
  check("full ready", est.status == "ready")
  check("full window facts", est.windowXp == 12000 and est.observedSeconds == 300)
  check("full remaining", est.remainingXp == 60000)
  check("full eta", close(est.etaSeconds, 1500))
end
do -- 4,000 XP after 120s: 120,000/hr over observed time, warming up
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 60, 4000)
  local est = ns.estimate(tr, 120, { level = 10, xp = 40000, req = 100000, capped = false }, false)
  check("warming rate", close(est.xpPerHour, 120000))
  check("warming status", est.status == "warming-up")
  check("warming eta", close(est.etaSeconds, 1800))
end
do -- award before the 30s gate: raw rate kept, estimate collecting
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 5, 500)
  local est = ns.estimate(tr, 10, { level = 10, xp = 0, req = 1000, capped = false }, false)
  check("early raw rate", close(est.xpPerHour, 180000))
  check("early collecting", est.status == "collecting" and est.etaSeconds == nil)
end
do -- silent past the gate: 0/hr, no recent XP
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  local snap = { level = 10, xp = 0, req = 1000, capped = false }
  local est = ns.estimate(tr, 30, snap, false)
  check("silent zero rate", est.status == "no-recent-xp" and est.xpPerHour == 0)
  check("silent null eta", est.etaSeconds == nil)
  local early = ns.estimate(tr, 29, snap, false)
  check("gate boundary", early.status == "collecting" and early.xpPerHour == 0)
end
do -- award exactly at the trailing cutoff expires; just newer survives
  local w = newWorld()
  local ns = loadAddon(w)
  local snap = { level = 10, xp = 0, req = 1000, capped = false }
  local tr = ns.newTracker(0)
  ns.addAward(tr, 50, 700)
  local est = ns.estimate(tr, 350, snap, false)
  check("cutoff excluded", est.windowXp == 0 and est.status == "no-recent-xp")
  local tr2 = ns.newTracker(0)
  ns.addAward(tr2, 51, 700)
  local est2 = ns.estimate(tr2, 350, snap, false)
  check("cutoff kept", est2.windowXp == 700 and close(est2.xpPerHour, 8400))
  check("cutoff ready", est2.status == "ready")
end
do -- award at exactly session start is a zero-elapsed boundary: excluded
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(1000)
  ns.addAward(tr, 1000, 500)
  local est = ns.estimate(tr, 1060, { level = 10, xp = 0, req = 1000, capped = false }, false)
  check("start boundary excluded", est.windowXp == 0 and est.status == "no-recent-xp")
end
do -- full window after the final award: 0/hr, null ETA
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 10, 1000)
  local est = ns.estimate(tr, 400, { level = 10, xp = 0, req = 1000, capped = false }, false)
  check("expired zero rate", est.status == "no-recent-xp" and est.xpPerHour == 0)
  check("expired null eta", est.etaSeconds == nil)
end
do -- requirement reached before the level snapshot updates: awaiting
  local w = newWorld()
  local ns = loadAddon(w)
  local full = { level = 10, xp = 1000, req = 1000, capped = false }
  local tr = ns.newTracker(0)
  ns.addAward(tr, 60, 4000)
  local est = ns.estimate(tr, 120, full, false)
  check("awaiting status", est.status == "awaiting-level-update")
  check("awaiting zero eta", est.remainingXp == 0 and est.etaSeconds == 0)
  check("awaiting keeps rate", close(est.xpPerHour, 120000))
  local quiet = ns.newTracker(0)
  local est2 = ns.estimate(quiet, 120, full, false)
  check("awaiting beats silent", est2.status == "awaiting-level-update")
end
do -- absent snapshot: unavailable ETA, raw rate kept
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 10, 1000)
  local est = ns.estimate(tr, 120, nil, false)
  check("absent unavailable", est.status == "unavailable")
  check("absent nulls", est.etaSeconds == nil and est.remainingXp == nil)
  check("absent keeps rate", close(est.xpPerHour, 30000))
end
do -- invalid snapshots: unavailable ETA, raw rate kept, nothing fabricated
  local bad = {
    { level = 10, xp = 500, req = 1000 }, -- capped flag missing
    { level = 10, xp = 1500, req = 1000, capped = false }, -- xp past requirement
    { level = 10, xp = -5, req = 1000, capped = false }, -- negative xp
    { level = 10, xp = 500, req = 0, capped = false }, -- non-positive requirement
    { level = 10, xp = 0 / 0, req = 1000, capped = false }, -- NaN
    { level = 10, xp = 500, req = math.huge, capped = false }, -- infinite
  }
  for i, snap in ipairs(bad) do
    local w = newWorld()
    local ns = loadAddon(w)
    local tr = ns.newTracker(0)
    ns.addAward(tr, 10, 1000)
    local est = ns.estimate(tr, 120, snap, false)
    check("bad " .. i .. " unavailable", est.status == "unavailable")
    check("bad " .. i .. " nulls", est.etaSeconds == nil and est.remainingXp == nil)
    check("bad " .. i .. " keeps rate", close(est.xpPerHour, 30000))
  end
end
do -- capped: N/A rate, null ETA
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 10, 1000)
  local est = ns.estimate(tr, 120, { level = 80, xp = 0, req = 0, capped = true }, false)
  check("capped status", est.status == "capped")
  check("capped nulls", est.xpPerHour == nil and est.etaSeconds == nil and est.remainingXp == nil)
end
do -- paused: estimate suspended, raw facts retained
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 10, 1000)
  local est = ns.estimate(tr, 120, { level = 10, xp = 0, req = 1000, capped = false }, true)
  check("paused status", est.status == "paused" and est.etaSeconds == nil)
  check("paused keeps rate", close(est.xpPerHour, 30000))
end
do -- compaction preserves sums and rates
  local w = newWorld()
  local ns = loadAddon(w)
  local snap = { level = 10, xp = 0, req = 1000, capped = false }
  local tr = ns.newTracker(0)
  ns.addAward(tr, 10, 100)
  ns.addAward(tr, 20, 200)
  ns.addAward(tr, 400, 300)
  local before = ns.estimate(tr, 400, snap, false)
  ns.compact(tr)
  local after = ns.estimate(tr, 400, snap, false)
  check("compact same sum", after.windowXp == before.windowXp and after.windowXp == 300)
  check("compact same rate", close(after.xpPerHour, before.xpPerHour))
  check("compact same status", after.status == before.status)
  check("compact resets head", tr.head == 1)
end
do -- input adapter rejects zero and non-finite awards
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  check("zero ignored", ns.addAward(tr, 10, 0) == false)
  check("negative ignored", ns.addAward(tr, 10, -5) == false)
  check("nan amount ignored", ns.addAward(tr, 10, 0 / 0) == false)
  check("infinite amount ignored", ns.addAward(tr, 10, math.huge) == false)
  check("nan time ignored", ns.addAward(tr, 0 / 0, 100) == false)
  check("nothing counted", tr.sum == 0 and #tr.events == 0)
  check("valid accepted", ns.addAward(tr, 10, 100) == true and tr.sum == 100)
end

-- 18. Readout labels.
do
  local w = newWorld()
  local ns = loadAddon(w)
  check("ready title", ns.titleText({ status = "ready", xpPerHour = 144000, observedSeconds = 300 })
    == "144k XP/hr · last 5m")
  check("warming title", ns.titleText({ status = "warming-up", xpPerHour = 120000, observedSeconds = 120 })
    == "120k XP/hr · last 2m · warming up")
  check("zero title", ns.titleText({ status = "no-recent-xp", xpPerHour = 0, observedSeconds = 300 })
    == "0 XP/hr · last 5m")
  check("collecting title", ns.titleText({ status = "collecting", xpPerHour = 180000, observedSeconds = 10 })
    == "Collecting data")
  check("paused title", ns.titleText({ status = "paused", xpPerHour = 1, observedSeconds = 1 }) == "Paused")
  check("ready eta", ns.etaText({ status = "ready", etaSeconds = 1500 }) == "Next level: ~25m")
  check("warming eta", ns.etaText({ status = "warming-up", etaSeconds = 1800 }) == "Next level: ~30m")
  check("silent eta", ns.etaText({ status = "no-recent-xp" }) == "No recent XP")
  check("collecting eta", ns.etaText({ status = "collecting" }) == "Collecting data")
  check("awaiting eta", ns.etaText({ status = "awaiting-level-update", etaSeconds = 0 })
    == "Level complete; awaiting update")
  check("unavailable eta", ns.etaText({ status = "unavailable" }) == "Unavailable")
  check("paused eta", ns.etaText({ status = "paused" }) == "Paused")
end
do -- ETA formatting: sub-minute floor, upward rounding, hours as needed
  local w = newWorld()
  local ns = loadAddon(w)
  check("eta sub-minute", ns.formatEta(30) == "~<1m" and ns.formatEta(59.9) == "~<1m")
  check("eta minute", ns.formatEta(60) == "~1m")
  check("eta rounds up", ns.formatEta(1501) == "~26m")
  check("eta hour", ns.formatEta(3600) == "~1h")
  check("eta hour minutes", ns.formatEta(3900) == "~1h05m" and ns.formatEta(7260) == "~2h01m")
end

-- 19. Gain reconstruction from XP-bar snapshots.
do
  local w = newWorld()
  local ns = loadAddon(w)
  local new = { level = 10, xp = 300, req = 1000, capped = false }
  check("gain first is baseline", ns.gain(nil, new) == nil)
  check("gain same level", ns.gain({ level = 10, xp = 100, req = 1000, capped = false }, new) == 200)
  check("gain no change", ns.gain({ level = 10, xp = 300, req = 1000, capped = false }, new) == 0)
  check("gain negative resyncs",
    ns.gain({ level = 10, xp = 500, req = 1000, capped = false }, new) == nil)
  check("gain one level",
    ns.gain({ level = 10, xp = 900, req = 1000, capped = false },
      { level = 11, xp = 100, req = 2000, capped = false }) == 200)
  check("gain multi-level unmeasurable",
    ns.gain({ level = 10, xp = 900, req = 1000, capped = false },
      { level = 12, xp = 50, req = 3000, capped = false }) == nil)
  check("gain level drop resyncs",
    ns.gain({ level = 11, xp = 100, req = 2000, capped = false }, new) == nil)
end

-- 20. Live tracker through frame events.
do -- same-level gain becomes a timestamped award
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 300
  xpEvent(w)
  check("live rate", readout(w, "18k XP/hr · last 1m · warming up", "No XP bonus", RED_C))
  check("live eta", etaline(w) == "Next level: ~3m")
end
do -- level-up keeps history and snapshots the new level atomically
  local w = newWorld()
  w.xp = 900
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 120
  w.xp, w.max, w.level = 100, 2000, 11
  xpEvent(w)
  check("ding rate", readout(w, "6k XP/hr · last 2m · warming up", "No XP bonus", RED_C))
  check("ding eta", etaline(w) == "Next level: ~19m")
end
do -- PLAYER_LEVEL_UP refreshes but never adds an award
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("level event registered", w.frame.events.PLAYER_LEVEL_UP == true)
  w.now = w.now + 60
  w.xp = 300
  xpEvent(w)
  local title = w.frame.title.text
  levelEvent(w)
  check("level adds nothing", w.frame.title.text == title)
end
do -- multi-level jump is unmeasurable: no invented gain
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.level, w.xp, w.max = 12, 50, 3000
  xpEvent(w)
  check("jump silent", readout(w, "0 XP/hr · last 1m", "No XP bonus", RED_C))
  check("jump eta", etaline(w) == "No recent XP")
end
do -- negative same-level delta resyncs, never a negative award
  local w = newWorld()
  w.xp = 500
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 400
  xpEvent(w)
  check("negative silent", readout(w, "0 XP/hr · last 1m", "No XP bonus", RED_C))
  w.now = w.now + 60
  w.xp = 500
  xpEvent(w)
  check("resync rate", readout(w, "3k XP/hr · last 2m · warming up", "No XP bonus", RED_C))
  check("resync eta", etaline(w) == "Next level: ~10m")
end
do -- zone load keeps history; character switch clears it
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 300
  xpEvent(w)
  w.now = w.now + 30
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("zone keeps history", readout(w, "12k XP/hr · last 1m · warming up", "No XP bonus", RED_C))
  check("zone eta", etaline(w) == "Next level: ~4m")
  w.guid = "Player-11-0002"
  w.now = w.now + 5
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("switch clears", w.frame.title.text == "Collecting data" and etaline(w) == "Collecting data")
end
do -- /vxp pause freezes the display; resume restarts the gate
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  w.now = w.now + 60
  w.xp = 300
  xpEvent(w)
  slash("pause")
  check("pause display", w.frame.title.text == "Paused" and etaline(w) == "Paused")
  check("pause announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: paused.")
  w.now = w.now + 60
  w.xp = 600
  xpEvent(w)
  check("pause ignores awards", w.frame.title.text == "Paused")
  slash("pause")
  check("resume collects", w.frame.title.text == "Collecting data" and etaline(w) == "Collecting data")
  check("resume announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: resumed.")
  w.now = w.now + 60
  w.xp = 900
  xpEvent(w)
  check("resume no backfill", readout(w, "18k XP/hr · last 1m · warming up", "No XP bonus", RED_C))
end

-- 21. Slash toggles confirm with checkbox sounds (numeric fallback:
-- the harness provides no SOUNDKIT table).
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  slash("")
  slash("")
  slash("lock")
  slash("lock")
  slash("pause")
  slash("pause")
  slash("reset")
  check("toggle sounds", table.concat(w.sounds, ",") == "857,856,856,857,856,857,856")
end

print("tests/run.lua: " .. passed .. " checks passed")
