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
  g.IsInInstance = function() return world.inInstance end
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
      local t = { template = tmpl, text = "" }
      t.SetPoint = function() end
      t.SetJustifyH = function() end
      t.SetText = function(_, s) t.text = s end
      t.GetText = function() return t.text end
      t.SetTextColor = function(_, r, gg, b) t.color = { r, gg, b } end
      t.GetStringWidth = function() return 100 end
      t.GetStringHeight = function() return 30 end
      -- Same-template strings route by creation order: main.lua creates
      -- the body before the sub line, so the first GameTooltipText is
      -- the body and the second is the sub line; a third is the
      -- missing-buff section.
      if tmpl == "GameTooltipHeaderText" then f.title = t
      elseif f.body == nil then f.body = t
      elseif f.sub == nil then f.sub = t
      else f.missed = t end
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
           rested = false, warMode = false, warBonus = 10, inInstance = false, auras = {},
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

local function missedline(w)
  return w.frame.missed and w.frame.missed.text
end

local function subline(w)
  return w.frame.sub and w.frame.sub.text
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
  check("fresh collects", w.frame.title.text == "Collecting data" and subline(w) == "Collecting data")
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
  check("rate text", readout(w, "3k XP/hr · 15m", "No XP bonus", RED_C))
  check("rate sub", subline(w) == "Last 10m")
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
  check("level-up carries", readout(w, "1k XP/hr · 2h23m", "No XP bonus", RED_C))
  check("level-up sub", subline(w) == "Last 10m")
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
  check("cap raise collects", w.frame.title.text == "Collecting data" and subline(w) == "Collecting data")
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
  check("war mode line", readout(w, "0 XP/hr", "+10% War Mode", GREEN_C))
  check("war mode sub", subline(w) == "Warming up · last 1m of 10m")
end
do
  local w = newWorld()
  w.rested = true
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("rested line", readout(w, "0 XP/hr", "Rested", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.rested = true, true
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("bonuses stack", readout(w, "0 XP/hr", "+10% War Mode\nRested", GREEN_C))
end
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("no bonus line", readout(w, "0 XP/hr", "No XP bonus", RED_C))
end
do -- Call to Arms raises the Enlisted value above the +10% base
  local w = newWorld()
  w.warMode, w.warBonus = true, 15
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode live value", readout(w, "0 XP/hr", "+15% War Mode", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.warBonus = true, 30
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode high call", readout(w, "0 XP/hr", "+30% War Mode", GREEN_C))
end
do -- missing bonus API falls back to the +10% base
  local w = newWorld()
  w.warMode = true
  loadAddon(w)
  w.env.C_PvP = { IsWarModeDesired = function() return true end }
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode fallback", readout(w, "0 XP/hr", "+10% War Mode", GREEN_C))
end
do -- out-of-range value is not trusted
  local w = newWorld()
  w.warMode, w.warBonus = true, 5000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("war mode range gate", readout(w, "0 XP/hr", "+10% War Mode", GREEN_C))
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
  check("early gain collects", w.frame.title.text == "1.3m XP/hr" and subline(w) == "Collecting data")
  w.now = w.now + 290
  w.tickers[1].fn()
  check("ticker holds window", readout(w, "43k XP/hr · 2h14m", "No XP bonus", RED_C))
  check("ticker sub", subline(w) == "Warming up · last 5m of 10m")
  w.now = w.now + 11
  w.tickers[1].fn()
  check("ticker warming rate", readout(w, "42k XP/hr · 2h19m", "No XP bonus", RED_C))
  check("ticker warming sub", subline(w) == "Warming up · last 5m of 10m")
  w.now = w.now + 300
  w.tickers[1].fn()
  check("ticker expires award", readout(w, "0 XP/hr", "No XP bonus", RED_C))
  check("expired sub", subline(w) == "No XP in the last 10m")
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
  check("reset collects", w.frame.title.text == "Collecting data" and subline(w) == "Collecting data")
  check("reset announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: session reset.")
  w.now = w.now + 60
  w.xp = 6000
  xpEvent(w)
  check("reset clears history", readout(w, "60k XP/hr · 1h34m", "No XP bonus", RED_C))
  check("reset warming sub", subline(w) == "Warming up · last 1m of 10m")
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
  check("mentored line", readout(w, "0 XP/hr", "+20% Warband Mentored", GREEN_C))
end
do
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("whee line", readout(w, "0 XP/hr", "+10% WHEE!", GREEN_C))
end
do
  local w = newWorld()
  w.auras[136583] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("top hat line", readout(w, "0 XP/hr", "+10% Darkmoon Top Hat", GREEN_C))
end
do
  local w = newWorld()
  w.auras[24705] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("grim visage line", readout(w, "0 XP/hr", "+10% Grim Visage", GREEN_C))
end
do
  local w = newWorld()
  w.auras[95987] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("unburdened line", readout(w, "0 XP/hr", "+10% Unburdened", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.rested = true, true
  w.auras[430191], w.auras[46668] = { points = { 20 } }, {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("bonuses sort by value", readout(w, "0 XP/hr",
    "+20% Warband Mentored\n+10% War Mode\n+10% WHEE!\nRested", GREEN_C))
end
do -- highest bonus first across sources
  local w = newWorld()
  w.warMode, w.warBonus, w.rested = true, 30, true
  w.auras[430191], w.auras[46668] = { points = { 20 } }, {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("bonuses sort descending", readout(w, "0 XP/hr",
    "+30% War Mode\n+20% Warband Mentored\n+10% WHEE!\nRested", GREEN_C))
end
do -- lines without a number trail the valued lines
  local w = newWorld()
  w.warMode = true
  w.auras[430191] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("unvalued lines trail", readout(w, "0 XP/hr",
    "+10% War Mode\nWarband Mentored", GREEN_C))
end
do -- missing aura API degrades to no aura lines, no error
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  w.env.C_UnitAuras = nil
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("no aura api degrades", readout(w, "0 XP/hr", "No XP bonus", RED_C))
end

do -- mentored without a readable value shows no number
  local w = newWorld()
  w.auras[430191] = {}
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("mentored fallback", readout(w, "0 XP/hr", "Warband Mentored", GREEN_C))
end
do -- out-of-range value is not trusted
  local w = newWorld()
  w.auras[430191] = { points = { 5000 } }
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("mentored range gate", readout(w, "0 XP/hr", "Warband Mentored", GREEN_C))
end

-- 14. Aura changes refresh the readout.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("unit_aura registered", w.frame.events.UNIT_AURA == true)
  w.now = w.now + 45
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("no aura yet", readout(w, "0 XP/hr", "No XP bonus", RED_C))
  check("partial seconds sub", subline(w) == "Warming up · last 45s of 10m")
  w.auras[46668] = {}
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "target")
  check("other unit ignored", readout(w, "0 XP/hr", "No XP bonus", RED_C))
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("player aura refreshes", readout(w, "0 XP/hr", "+10% WHEE!", GREEN_C))
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
  check("sub uses tooltip text font", w.frame.sub.template == "GameTooltipText")
  local tc = w.frame.title.color or {}
  check("title is house gold", tc[1] == 1 and tc[2] == 0.82 and tc[3] == 0)
  check("missed uses tooltip text font", w.frame.missed.template == "GameTooltipText")
  check("frame fits text", w.frame.size[1] == 120 and w.frame.size[2] == 152)
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
  check("start window", est.windowSeconds == 600)
  check("start remaining", est.remainingXp == 1000)
end
do -- 12,000 XP in a full 600s window: 72,000/hr, ready
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 500, 6000)
  ns.addAward(tr, 590, 6000)
  local est = ns.estimate(tr, 600, { level = 10, xp = 40000, req = 100000, capped = false }, false)
  check("full rate", close(est.xpPerHour, 72000))
  check("full ready", est.status == "ready")
  check("full window facts", est.windowXp == 12000 and est.observedSeconds == 600)
  check("full remaining", est.remainingXp == 60000)
  check("full eta", close(est.etaSeconds, 3000))
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
do -- silent past the gate, partial window: 0/hr, still warming up
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  local snap = { level = 10, xp = 0, req = 1000, capped = false }
  local est = ns.estimate(tr, 30, snap, false)
  check("silent zero rate", est.status == "warming-up" and est.xpPerHour == 0)
  check("silent null eta", est.etaSeconds == nil)
  local early = ns.estimate(tr, 29, snap, false)
  check("gate boundary", early.status == "collecting" and early.xpPerHour == 0)
  local full = ns.estimate(tr, 600, snap, false)
  check("full silent", full.status == "no-recent-xp" and full.xpPerHour == 0)
end
do -- award exactly at the trailing cutoff expires; just newer survives
  local w = newWorld()
  local ns = loadAddon(w)
  local snap = { level = 10, xp = 0, req = 1000, capped = false }
  local tr = ns.newTracker(0)
  ns.addAward(tr, 50, 700)
  local est = ns.estimate(tr, 650, snap, false)
  check("cutoff excluded", est.windowXp == 0 and est.status == "no-recent-xp")
  local tr2 = ns.newTracker(0)
  ns.addAward(tr2, 51, 700)
  local est2 = ns.estimate(tr2, 650, snap, false)
  check("cutoff kept", est2.windowXp == 700 and close(est2.xpPerHour, 4200))
  check("cutoff idle", est2.status == "idle")
end
do -- award at exactly session start is a zero-elapsed boundary: excluded
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(1000)
  ns.addAward(tr, 1000, 500)
  local est = ns.estimate(tr, 1060, { level = 10, xp = 0, req = 1000, capped = false }, false)
  check("start boundary excluded", est.windowXp == 0 and est.status == "warming-up")
end
do -- full window after the final award: 0/hr, null ETA
  local w = newWorld()
  local ns = loadAddon(w)
  local tr = ns.newTracker(0)
  ns.addAward(tr, 10, 1000)
  local est = ns.estimate(tr, 700, { level = 10, xp = 0, req = 1000, capped = false }, false)
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
  local before = ns.estimate(tr, 700, snap, false)
  ns.compact(tr)
  local after = ns.estimate(tr, 700, snap, false)
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
  check("ready title", ns.titleText({ status = "ready", xpPerHour = 144000, etaSeconds = 1500 })
    == "144k XP/hr · 25m")
  check("warming title", ns.titleText({ status = "warming-up", xpPerHour = 120000, etaSeconds = 1800 })
    == "120k XP/hr · 30m")
  check("idle title", ns.titleText({ status = "idle", xpPerHour = 42000, etaSeconds = 8000 })
    == "42k XP/hr · 2h14m")
  check("zero title", ns.titleText({ status = "no-recent-xp", xpPerHour = 0, etaSeconds = nil })
    == "0 XP/hr")
  check("collecting pace title", ns.titleText({ status = "collecting", xpPerHour = 180000 }) == "180k XP/hr")
  check("collecting blank title", ns.titleText({ status = "collecting" }) == "Collecting data")
  check("paused title", ns.titleText({ status = "paused", xpPerHour = 1, observedSeconds = 1 }) == "Paused")
  check("unavailable title", ns.titleText({ status = "unavailable", xpPerHour = 30000 }) == "Unavailable")
  check("awaiting title", ns.titleText({ status = "awaiting-level-update", xpPerHour = 120000, etaSeconds = 0 })
    == "120k XP/hr · <1m")
  check("ready sub", ns.subText({ status = "ready", observedSeconds = 600, windowSeconds = 600 }) == "Last 10m")
  check("warming sub", ns.subText({ status = "warming-up", observedSeconds = 120, windowSeconds = 600 })
    == "Warming up · last 2m of 10m")
  check("warming seconds sub", ns.subText({ status = "warming-up", observedSeconds = 45, windowSeconds = 600 })
    == "Warming up · last 45s of 10m")
  check("idle sub", ns.subText({ status = "idle", observedSeconds = 600, windowSeconds = 600, idleSeconds = 150 })
    == "Idle 2m · last 10m")
  check("silent sub", ns.subText({ status = "no-recent-xp", observedSeconds = 600, windowSeconds = 600 })
    == "No XP in the last 10m")
  check("collecting sub", ns.subText({ status = "collecting" }) == "Collecting data")
  check("awaiting sub", ns.subText({ status = "awaiting-level-update" })
    == "Level complete; awaiting update")
  check("unavailable sub", ns.subText({ status = "unavailable" }) == "Waiting for XP data")
  check("paused sub", ns.subText({ status = "paused" }) == "Tracking paused")
end
do -- ETA formatting: sub-minute floor, upward rounding, hours as needed
  local w = newWorld()
  local ns = loadAddon(w)
  check("eta sub-minute", ns.formatEta(30) == "<1m" and ns.formatEta(59.9) == "<1m")
  check("eta minute", ns.formatEta(60) == "1m")
  check("eta rounds up", ns.formatEta(1501) == "26m")
  check("eta hour", ns.formatEta(3600) == "1h")
  check("eta hour minutes", ns.formatEta(3900) == "1h05m" and ns.formatEta(7260) == "2h01m")
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
  check("live rate", readout(w, "18k XP/hr · 3m", "No XP bonus", RED_C))
  check("live sub", subline(w) == "Warming up · last 1m of 10m")
end
do -- level-up keeps history and snapshots the new level atomically
  local w = newWorld()
  w.xp = 900
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 120
  w.xp, w.max, w.level = 100, 2000, 11
  xpEvent(w)
  check("ding rate", readout(w, "6k XP/hr · 19m", "No XP bonus", RED_C))
  check("ding sub", subline(w) == "Warming up · last 2m of 10m")
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
  check("jump silent", readout(w, "0 XP/hr", "No XP bonus", RED_C))
  check("jump sub", subline(w) == "Warming up · last 1m of 10m")
end
do -- negative same-level delta resyncs, never a negative award
  local w = newWorld()
  w.xp = 500
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 400
  xpEvent(w)
  check("negative silent", readout(w, "0 XP/hr", "No XP bonus", RED_C))
  w.now = w.now + 60
  w.xp = 500
  xpEvent(w)
  check("resync rate", readout(w, "3k XP/hr · 10m", "No XP bonus", RED_C))
  check("resync sub", subline(w) == "Warming up · last 2m of 10m")
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
  check("zone keeps history", readout(w, "12k XP/hr · 4m", "No XP bonus", RED_C))
  check("zone sub", subline(w) == "Warming up · last 1m of 10m")
  w.guid = "Player-11-0002"
  w.now = w.now + 5
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("switch clears", w.frame.title.text == "Collecting data" and subline(w) == "Collecting data")
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
  check("pause display", w.frame.title.text == "Paused" and subline(w) == "Tracking paused")
  check("pause announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: paused.")
  w.now = w.now + 60
  w.xp = 600
  xpEvent(w)
  check("pause ignores awards", w.frame.title.text == "Paused")
  slash("pause")
  check("resume collects", w.frame.title.text == "Collecting data" and subline(w) == "Collecting data")
  check("resume announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: resumed.")
  w.now = w.now + 60
  w.xp = 900
  xpEvent(w)
  check("resume no backfill", readout(w, "18k XP/hr · <1m", "No XP bonus", RED_C))
  check("resume fresh sub", subline(w) == "Warming up · last 1m of 10m")
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

-- 22. Missing-buff feedback: gray lines name what each gap is worth.
do -- bare character sees every gap plus the rollup
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("missing full list", missedline(w) == "+10% War Mode (toggle in a capital)\n"
    .. "+10% WHEE! (Faire week)\n"
    .. "+10% Wickerman (Hallow's End)\n"
    .. "Warband Mentored (needs a max-level character)\n"
    .. "Rested (rest in town)")
end
do -- partial stack shows only the gap
  local w = newWorld()
  w.warMode, w.rested = true, true
  loadAddon(w)
  clientLoaded(w)
  check("missing gap only", missedline(w) == "+10% WHEE! (Faire week)\n"
    .. "+10% Wickerman (Hallow's End)\n"
    .. "Warband Mentored (needs a max-level character)")
end
do -- full stack hides the section and its space
  local w = newWorld()
  w.warMode, w.rested = true, true
  w.auras[430191] = { points = { 20 } }
  w.auras[46668], w.auras[136583] = {}, {}
  w.auras[24705], w.auras[95987] = {}, {}
  loadAddon(w)
  clientLoaded(w)
  check("missing hidden when full", missedline(w) == "")
  check("missing frees space", w.frame.size[1] == 120 and w.frame.size[2] == 118)
end
do -- offered War Mode value follows Call to Arms
  local w = newWorld()
  w.warBonus = 15
  loadAddon(w)
  clientLoaded(w)
  check("missing live offer", missedline(w) == "+15% War Mode (toggle in a capital)\n"
    .. "+10% WHEE! (Faire week)\n"
    .. "+10% Wickerman (Hallow's End)\n"
    .. "Warband Mentored (needs a max-level character)\n"
    .. "Rested (rest in town)")
end
do -- one Wickerman aura covers the neutral line
  local w = newWorld()
  w.auras[24705] = {}
  loadAddon(w)
  clientLoaded(w)
  check("wickerman covered", not (missedline(w) or ""):find("Wickerman", 1, true))
end

-- Darkmoon buffs are either/or: one active covers the other.
do
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  local missed = missedline(w) or ""
  check("whee covers top hat", not missed:find("Top Hat", 1, true))
  check("whee not recommended", not missed:find("WHEE!", 1, true))
end
do
  local w = newWorld()
  w.auras[136583] = {}
  loadAddon(w)
  clientLoaded(w)
  local missed = missedline(w) or ""
  check("top hat covers whee", not missed:find("WHEE!", 1, true))
  check("top hat not recommended", not missed:find("Top Hat", 1, true))
end

-- 23. ETA uses a longer-memory basis than the displayed rate.
do -- unit: 15-minute window keeps what the 10-minute window drops
  local w = newWorld()
  local ns = loadAddon(w)
  local short = ns.newTracker(0)
  local long = ns.newTracker(0, 900)
  ns.addAward(short, 100, 6000)
  ns.addAward(short, 200, 6000)
  ns.addAward(long, 100, 6000)
  ns.addAward(long, 200, 6000)
  local est = ns.estimate(short, 900, { level = 10, xp = 0, req = 1000, capped = false }, false)
  check("short window expired", est.status == "no-recent-xp" and est.etaSeconds == nil)
  check("long window remembers", close(ns.etaSeconds(long, 900, 60000), 4500))
end
do -- dungeon burst: live rate spikes, ETA stays conservative
  local w = newWorld()
  w.max = 100000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 5000
  xpEvent(w)
  w.now = w.now + 240
  w.xp = 10000
  xpEvent(w)
  w.now = w.now + 300
  w.xp = 60000
  xpEvent(w)
  check("burst rate spikes", readout(w, "360k XP/hr · 7m", "No XP bonus", RED_C))
  check("burst sub", subline(w) == "Last 10m")
end
do -- stale long-window earnings never resurrect an ETA
  local w = newWorld()
  w.max = 100000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 10
  w.xp = 3600
  xpEvent(w)
  w.now = w.now + 910
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("stale eta stays null", subline(w) == "No XP in the last 10m")
  check("stale title zero", w.frame.title.text == "0 XP/hr")
end

-- 24. Aura reads go blind in instances: verifiable lines stay, the
-- rest becomes an honest note instead of false absence.
do
  local w = newWorld()
  w.inInstance = true
  w.warMode, w.rested = true, true
  w.auras[430191] = { points = { 20 } }
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  check("instance active lines", readout(w, "Collecting data", "+10% War Mode\nRested", GREEN_C))
  check("instance missing note", missedline(w) == "Aura scan unavailable in instances")
end
do
  local w = newWorld()
  w.inInstance = true
  loadAddon(w)
  clientLoaded(w)
  check("instance bare body", readout(w, "Collecting data", "No XP bonus", RED_C))
  check("instance bare missing", missedline(w) == "+10% War Mode (toggle in a capital)\n"
    .. "Rested (rest in town)\n"
    .. "Aura scan unavailable in instances")
end

-- 25. Idle status: a quiet minute in a full window admits staleness.
do -- 59s of quiet stays ready; 60s trips idle
  local w = newWorld()
  w.max = 100000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 541
  w.xp = 60000
  xpEvent(w)
  w.now = w.now + 59
  w.tickers[1].fn()
  check("quiet 59s ready", subline(w) == "Last 10m")
  w.now = w.now + 1
  w.tickers[1].fn()
  check("quiet 60s idle", subline(w) == "Idle 1m · last 10m")
  check("idle keeps payoff", w.frame.title.text == "360k XP/hr · 7m")
end
do -- idle in a partial window still reads warming up
  local w = newWorld()
  w.max = 100000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 5000
  xpEvent(w)
  w.now = w.now + 120
  w.tickers[1].fn()
  check("warming owns partial idle", subline(w) == "Warming up · last 3m of 10m")
  check("partial idle payoff", w.frame.title.text == "100k XP/hr · 57m")
end

print("tests/run.lua: " .. passed .. " checks passed")
