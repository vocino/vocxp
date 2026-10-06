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
  g.time = function() return world.time end
  g.UnitXP = function() return world.xp end
  g.UnitXPMax = function() return world.max end
  g.GetXPExhaustion = function() return world.rested and 1 or nil end
  g.C_PvP = { IsWarModeDesired = function() return world.warMode end }
  g.C_UnitAuras = { GetPlayerAuraBySpellID = function(id) return world.auras[id] end }
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
    f.CreateFontString = function(_, _, _, template)
      local t = { template = template }
      t.SetPoint = function() end
      t.SetJustifyH = function() end
      t.SetText = function(_, s) t.text = s end
      t.SetTextColor = function(_, r, g, b) t.color = { r, g, b } end
      t.GetStringWidth = function() return 100 end
      t.GetStringHeight = function() return 30 end
      if template == "GameTooltipHeaderText" then f.title = t else f.body = t end
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
  return { time = 1000000, xp = 0, max = 1000, rested = false, warMode = false, auras = {},
           printed = {}, tickers = {}, frames = {}, savedVars = nil }
end

-- Simulate the client deserializing SavedVariables (a FRESH table replaces
-- the file-top default) and then firing PLAYER_ENTERING_WORLD.
local function clientLoaded(w)
  w.env.VocXPDB = w.savedVars or {}
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
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
  w.time = w.time + 1800
  w.xp = 500
  xpEvent(w)
  check("rate text", readout(w, "1k XP/hr", "No XP bonus", RED_C))
end

-- 5. Level-up carries the remainder across the bar.
do
  local w = newWorld()
  w.xp, w.max = 900, 1000
  loadAddon(w)
  clientLoaded(w)
  w.xp, w.max, w.time = 100, 2000, w.time + 3600
  xpEvent(w)
  check("level-up carries", readout(w, "200 XP/hr", "No XP bonus", RED_C))
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
  check("cap raise rate", readout(w, "0 XP/hr", "No XP bonus", RED_C))
end
do -- toggle at max level keeps the pref but says so
  local w = newWorld()
  w.xp, w.max = 0, 0
  loadAddon(w)
  clientLoaded(w)
  w.env.SlashCmdList.VOCXP("")
  check("max toggle stays hidden", w.frame.shown == false)
  check("max toggle announces", w.printed[#w.printed] == "VocXP: max level (stays hidden).")
end

-- 7. Bonus lines.
do
  local w = newWorld()
  w.warMode = true
  loadAddon(w)
  clientLoaded(w)
  check("war mode line", readout(w, "0 XP/hr", "+10% War Mode", GREEN_C))
end
do
  local w = newWorld()
  w.rested = true
  loadAddon(w)
  clientLoaded(w)
  check("rested line", readout(w, "0 XP/hr", "Rested", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.rested = true, true
  loadAddon(w)
  clientLoaded(w)
  check("bonuses stack", readout(w, "0 XP/hr", "+10% War Mode\nRested", GREEN_C))
end
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("no bonus line", readout(w, "0 XP/hr", "No XP bonus", RED_C))
end

-- 8. The ticker refreshes the rate between XP events.
do
  local w = newWorld()
  w.xp, w.max = 0, 100000
  loadAddon(w)
  clientLoaded(w)
  check("ticker registered", #w.tickers == 1 and w.tickers[1].secs == 5)
  w.xp = 3600
  xpEvent(w)
  check("fresh rate spikes", readout(w, "13.0m XP/hr", "No XP bonus", RED_C))
  w.time = w.time + 3600
  w.tickers[1].fn()
  check("ticker decays rate", readout(w, "4k XP/hr", "No XP bonus", RED_C))
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
  check("slash hide announces", w.printed[#w.printed] == "VocXP: hidden.")
  slash("")
  check("slash shows", w.frame.shown == true)
  check("slash show announces", w.printed[#w.printed] == "VocXP: shown.")
end

-- 10. /vxp lock toggles mouse input.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  slash("lock")
  check("lock disables mouse", w.frame.mouse == false)
  check("lock announces", w.printed[#w.printed] == "VocXP: locked.")
  slash("  LOCK  ")
  check("lock toggles back", w.frame.mouse == true)
  check("unlock announces", w.printed[#w.printed] == "VocXP: unlocked. Drag to move.")
end

-- 11. /vxp reset zeroes the session.
do
  local w = newWorld()
  w.xp, w.max = 0, 100000
  loadAddon(w)
  clientLoaded(w)
  w.xp = 5000
  xpEvent(w)
  w.time = w.time + 100
  w.env.SlashCmdList.VOCXP("reset")
  check("reset zeroes rate", readout(w, "0 XP/hr", "No XP bonus", RED_C))
  check("reset announces", w.printed[#w.printed] == "VocXP: session reset.")
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
  check("mentored line", readout(w, "0 XP/hr", "+20% Warband Mentored", GREEN_C))
end
do
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  check("whee line", readout(w, "0 XP/hr", "+10% WHEE!", GREEN_C))
end
do
  local w = newWorld()
  w.auras[136583] = {}
  loadAddon(w)
  clientLoaded(w)
  check("top hat line", readout(w, "0 XP/hr", "+10% Darkmoon Top Hat", GREEN_C))
end
do
  local w = newWorld()
  w.auras[24705] = {}
  loadAddon(w)
  clientLoaded(w)
  check("grim visage line", readout(w, "0 XP/hr", "+10% Grim Visage", GREEN_C))
end
do
  local w = newWorld()
  w.auras[95987] = {}
  loadAddon(w)
  clientLoaded(w)
  check("unburdened line", readout(w, "0 XP/hr", "+10% Unburdened", GREEN_C))
end
do
  local w = newWorld()
  w.warMode, w.rested = true, true
  w.auras[430191], w.auras[46668] = { points = { 20 } }, {}
  loadAddon(w)
  clientLoaded(w)
  check("all bonuses stack in order", readout(w, "0 XP/hr",
    "+10% War Mode\n+20% Warband Mentored\n+10% WHEE!\nRested", GREEN_C))
end
do -- missing aura API degrades to no aura lines, no error
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  w.env.C_UnitAuras = nil
  clientLoaded(w)
  check("no aura api degrades", readout(w, "0 XP/hr", "No XP bonus", RED_C))
end

do -- mentored without a readable value shows no number
  local w = newWorld()
  w.auras[430191] = {}
  loadAddon(w)
  clientLoaded(w)
  check("mentored fallback", readout(w, "0 XP/hr", "Warband Mentored", GREEN_C))
end
do -- out-of-range value is not trusted
  local w = newWorld()
  w.auras[430191] = { points = { 5000 } }
  loadAddon(w)
  clientLoaded(w)
  check("mentored range gate", readout(w, "0 XP/hr", "Warband Mentored", GREEN_C))
end

-- 14. Aura changes refresh the readout.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("unit_aura registered", w.frame.events.UNIT_AURA == true)
  check("no aura yet", readout(w, "0 XP/hr", "No XP bonus", RED_C))
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
  check("frame fits text", w.frame.size[1] == 120 and w.frame.size[2] == 84)
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
  check("rewake reregisters", w.frame.events.PLAYER_XP_UPDATE == true and w.frame.events.UNIT_AURA == true)
  check("rewake reshows", w.frame.shown == true)
end
do -- repeated logins never stack tickers
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("no double ticker", #w.tickers == 1)
end

print("tests/run.lua: " .. passed .. " checks passed")
