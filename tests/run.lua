-- VocXP regression tests. Stub-harness: no WoW client needed.
-- Run from anywhere:  lua tests/run.lua   (repo root also fine)
-- Works on Lua 5.1 (the client's dialect) and 5.2+.
--
-- Convention: each test builds a fresh stub world, drives the frame's
-- OnEvent/OnDrag/OnEnter scripts or the slash handler, and asserts.
-- Any failed assert aborts with the test name.

local testDir = debug.getinfo(1, "S").source:gsub("\\", "/"):match("@?(.*/)") or ""
local mainPath = testDir .. "../main.lua"

local passed = 0
local function check(name, cond)
  if not cond then error("FAIL: " .. name, 2) end
  passed = passed + 1
end

-- Expected bar state: progress value, label text, overlay widths.
local GREEN_C = { 0.25, 0.9, 0.35 }
local RED_C = { 0.9, 0.3, 0.25 }
local GOLD_C = { 1, 0.82, 0 }
local MUTED_C = { 0.5, 0.5, 0.5 }

-- Float-tolerant equality for rates, ETAs, and bar fractions.
local function close(a, b)
  return math.abs(a - b) <= math.max(1e-9 * math.abs(b), 1e-9)
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
  g.GetXPExhaustion = function() return world.restedXp end
  g.IsXPUserDisabled = function() return world.xpDisabled end
  g.GetQuestLogRewardXP = function() return world.questReward[world.selectedQuest] end
  g.C_QuestLog = {
    GetNumQuestLogEntries = function() return #world.quests end,
    GetInfo = function(i)
      local q = world.quests[i]
      if q == nil then return nil end
      return { questID = q.id, isHeader = q.header == true }
    end,
    ReadyForTurnIn = function(id) return world.ready[id] end,
    GetSelectedQuest = function() return world.selectedQuest end,
    SetSelectedQuest = function(id)
      world.selectedQuest = id
      world.selectLog[#world.selectLog + 1] = id
    end,
  }
  g.EventRegistry = {
    RegisterCallback = function(_, event, fn) world.editCallbacks[event] = fn end,
  }
  local native = { shown = true }
  native.IsShown = function(self) return self.shown end
  native.Hide = function(self) self.shown = false end
  native.Show = function(self) self.shown = true end
  g.StatusTrackingBarManager = native
  world.native = native
  g.C_PvP = {
    IsWarModeDesired = function() return world.warMode end,
    GetWarModeRewardBonus = function() return world.warBonus end,
  }
  g.C_UnitAuras = { GetPlayerAuraBySpellID = function(id) return world.auras[id] end }
  g.C_AddOns = {
    GetAddOnInterfaceVersion = function(n)
      world.queriedAddon = n
      return world.addonInterfaceVersion
    end,
  }
  g.C_PaperDollInfo = {
    GetInventorySlotInfo = function(slotName)
      world.slotQueries[#world.slotQueries + 1] = slotName
      return world.slotIDs[slotName]
    end,
  }
  g.GetInventoryItemQuality = function(unit, slot)
    if unit ~= "player" then return nil end
    return world.equipped[slot]
  end
  g.IsInInstance = function() return world.inInstance end
  g.GetMaxLevelForLatestExpansion = function() return world.latestMaxLevel end
  g.GetMaxLevelForPlayerExpansion = function() return world.expansionMaxLevel end
  g.GetMaxPlayerLevel = function() return world.playerMaxLevel end
  g.PlayerIsTimerunning = function() return world.timerunning end
  g.IsTrialAccount = function() return world.trial end
  g.MAX_REPUTATION_REACTION = 8
  local function factionRow(f)
    return { factionID = f.id, name = f.name, reaction = f.reaction,
             currentReactionThreshold = f.lo, nextReactionThreshold = f.hi,
             currentStanding = f.standing, isHeader = f.header == true,
             isHeaderWithRep = f.headerRep == true,
             isWatched = f.id == world.watchedID, hasBonusRepGain = f.bonus == true }
  end
  local function factionByID(id)
    for _, f in ipairs(world.factions) do
      if f.id == id then return factionRow(f) end
    end
    return nil
  end
  g.C_Reputation = {
    GetNumFactions = function() return #world.factions end,
    GetFactionDataByIndex = function(i)
      local f = world.factions[i]
      if f == nil then return nil end
      return factionRow(f)
    end,
    GetFactionDataByID = function(id)
      local fd = factionByID(id)
      -- byIDStanding models the live finding that ByID can lag the
      -- watched struct (3000 vs 1803 seen on a renown faction).
      if fd ~= nil then
        for _, f in ipairs(world.factions) do
          if f.id == id and f.byIDStanding ~= nil then fd.currentStanding = f.byIDStanding end
        end
      end
      return fd
    end,
    GetWatchedFactionData = function()
      if world.watchedID == nil or world.watchedID == 0 then return nil end
      return factionByID(world.watchedID)
    end,
    IsMajorFaction = function(id) return world.isMajor[id] == true end,
    IsFactionParagonForCurrentPlayer = function(id) return world.paragon[id] ~= nil end,
    GetFactionParagonInfo = function(id)
      local p = world.paragon[id]
      if p == nil then return nil end
      return p.current, p.threshold, 0, p.pending == true
    end,
  }
  g.C_MajorFactions = {
    GetMajorFactionData = function(id)
      local m = world.major[id]
      if m == nil then return nil end
      return { renownLevel = m.level, renownLevelThreshold = m.threshold }
    end,
    HasMaximumRenown = function(id)
      local m = world.major[id]
      return m ~= nil and m.hasMax == true
    end,
  }
  g.C_GossipInfo = {
    GetFriendshipReputation = function(id)
      local f = world.friendship[id]
      if f == nil then return nil end
      return { friendshipFactionID = f.fid, standing = f.standing,
               reaction = f.reaction, reactionThreshold = f.lo, nextThreshold = f.next }
    end,
    GetFriendshipReputationRanks = function(fid)
      for _, f in pairs(world.friendship) do
        if f.fid == fid then return { currentLevel = f.curLevel, maxLevel = f.maxLevel } end
      end
      return nil
    end,
  }
  g.PlaySound = function(id) world.sounds[#world.sounds + 1] = id end
  g.GameTooltip = {
    SetOwner = function(_, owner, anchor) world.gametip.owner, world.gametip.anchor = owner, anchor end,
    ClearLines = function() world.gametip.lines = {} end,
    SetText = function(_, t, r, gg, b) world.gametip.title = t world.gametip.titleColor = { r, gg, b } end,
    AddLine = function(_, t, r, gg, b)
      world.gametip.lines[#world.gametip.lines + 1] = { text = t, r = r, g = gg, b = b }
    end,
    Show = function() world.gametip.shown = true end,
    Hide = function() world.gametip.shown = false end,
  }
  if world.withSettings then
    local S = {}
    S.RegisterVerticalLayoutCategory = function(n)
      world.settingsCat = n
      return { GetID = function() return 42 end }
    end
    S.RegisterAddOnCategory = function() world.settingsCatRegistered = true end
    S.RegisterAddOnSetting = function(_, var, key, tbl, typ, label, default)
      world.settingsReg[#world.settingsReg + 1] =
        { var = var, key = key, tbl = tbl, type = typ, label = label, default = default }
      local s = {}
      s.SetValueChangedCallback = function(_, fn) world.settingCallbacks[var] = fn end
      return s
    end
    S.CreateCheckbox = function() world.settingsChecks = world.settingsChecks + 1 end
    S.OpenToCategory = function(id) world.openedCategory = id end
    g.Settings = S
  end
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
  local function newTexture()
    local t = { shown = true, width = 0, points = {} }
    t.SetAtlas = function(_, a, u) if world.noAtlas then error("unknown atlas") end t.atlas = a t.atlasSize = u end
    t.SetTexture = function(_, f) t.file = f end
    t.SetAllPoints = function() t.allPoints = true end
    t.SetPoint = function(_, p, rel, rp, x, y)
      t.points[#t.points + 1] = { p, rel, rp, x, y }
    end
    t.ClearAllPoints = function() t.points = {} end
    t.SetWidth = function(_, w) t.width = w end
    t.SetSize = function(_, w, h) t.size = { w, h } end
    t.SetBlendMode = function(_, b) t.blend = b end
    t.SetTexCoord = function(_, l, r, tp, bt) t.texcoord = { l, r, tp, bt } end
    t.SetVertexColor = function(_, r, gg, b) t.vertex = { r, gg, b } end
    t.SetRoundLayoutToNearestPixel = function(_, e) t.rounded = e end
    t.SetShown = function(_, s) t.shown = s end
    t.Hide = function() t.shown = false end
    t.Show = function() t.shown = true end
    t.IsShown = function() return t.shown end
    return t
  end
  g.CreateFrame = function(ftype, _, _, template)
    if world.failTemplate and template ~= nil then error("unknown template") end
    local f = { events = {}, scripts = {}, ctype = ftype, template = template,
                strings = {}, textures = {} }
    f.SetSize = function(_, w, h) f.size = { w, h } end
    f.SetHeight = function(_, h) f.height = h end
    f.SetMovable = function(_, m) f.movable = m end
    f.SetClampedToScreen = function(_, c) f.clamped = (c == nil) and true or c end
    f.RegisterEvent = function(_, e) f.events[e] = true end
    f.UnregisterEvent = function(_, e) f.events[e] = nil end
    f.RegisterForDrag = function(_, b) f.dragButton = b end
    f.EnableMouse = function(_, m) f.mouse = m end
    f.SetRoundLayoutToNearestPixel = function(_, e) f.rounded = e end
    f.SetShown = function(_, s) f.shown = s end
    f.SetAllPoints = function() f.allPoints = true end
    f.SetScript = function(_, sname, fn) f.scripts[sname] = fn end
    -- The client ignores StartMoving on a non-movable frame; emulate
    -- that so the drag tests fail if SetMovable(true) ever goes missing.
    f.StartMoving = function() if f.movable then f.moving = true end end
    f.StopMovingOrSizing = function() f.moving = false end
    f.ClearAllPoints = function() f.point = nil end
    f.SetPoint = function(_, p, _, _, x, y) f.point = { p, x, y } end
    f.GetPoint = function() return f.point[1], nil, nil, f.point[2], f.point[3] end
    f.SetMinMaxValues = function(_, lo, hi) f.minmax = { lo, hi } end
    f.SetValue = function(_, v) f.value = v end
    f.SetStatusBarTexture = function(_, tx) f.barTexture = tx end
    if template == "GradualAnimatedStatusBarTemplate" then
      f.SetBarTexture = function(_, a) f.barAtlas = a end
      f.SetAnimationTextures = function(_, gf, lu) f.flare = { gf, lu } end
      f.SetAnimatedValues = function(_, v, lo, hi, lvl)
        f.animated = { v, lo, hi, lvl }
        f.value = v
      end
    end
    f.GetStatusBarTexture = function()
      if f.fillTex == nil then f.fillTex = newTexture() end
      return f.fillTex
    end
    f.CreateTexture = function(_, _, layer, _, sub)
      local t = newTexture()
      t.layer, t.sublevel = layer, sub or 0
      f.textures[#f.textures + 1] = t
      return t
    end
    f.CreateFontString = function(_, _, _, tmpl)
      if tmpl == world.failFont then error("unknown font") end
      local t = { template = tmpl, text = "" }
      t.SetPoint = function(_, p, rel, rp, x, y) t.point = { p, rel, rp, x, y } end
      t.SetJustifyH = function() end
      t.shown = true
      t.SetShown = function(_, s) t.shown = s end
      t.Hide = function() t.shown = false end
      t.Show = function() t.shown = true end
      t.IsShown = function() return t.shown end
      t.SetText = function(_, s) t.text = s end
      t.GetText = function() return t.text end
      t.SetTextColor = function(_, r, gg, b) t.color = { r, gg, b } end
      t.SetShadowOffset = function(_, x, y) t.shadow = { x, y } end
      t.SetRoundLayoutToNearestPixel = function(_, e) t.rounded = e end
      t.GetStringWidth = function() return 100 end
      t.GetStringHeight = function() return 30 end
      f.strings[#f.strings + 1] = t
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
  world.frame = world.frames[1] -- the bar frame, created at load
  world.bar = world.frames[2] -- the StatusBar inside it
  world.bg = world.bar.textures[1]
  world.restFill = world.bar.textures[2]
  world.questFill = world.bar.textures[3]
  world.label = world.bar.strings[1]
  world.frameTex = world.frame.textures[1] -- the stroke hangs on the frame
  world.pip = world.bar.textures[4]
  world.rate = world.frame.strings[1]
  world.sub = world.frame.strings[2]
  world.ns = ns
  world.env = g
  return ns
end

local function newWorld()
  return { now = 1000000, xp = 0, max = 1000, level = 10, guid = "Player-11-0001",
           restedXp = nil, xpDisabled = false, warMode = false, warBonus = 10,
           factions = {}, watchedID = nil, isMajor = {}, paragon = {},
           playerMaxLevel = 90, expansionMaxLevel = 90, latestMaxLevel = 90,
           timerunning = false, trial = false,
           major = {}, friendship = {},
           inInstance = false, auras = {},
           addonInterfaceVersion = 120105,
           quests = {}, ready = {}, questReward = {}, selectedQuest = 0, selectLog = {},
           editCallbacks = {},
           slotIDs = { HeadSlot = 1, NeckSlot = 2, ShoulderSlot = 3, BackSlot = 15,
                       ChestSlot = 5, LegsSlot = 7, Finger0Slot = 11, Finger1Slot = 12 },
           equipped = {}, slotQueries = {},
           printed = {}, tickers = {}, frames = {}, sounds = {}, savedVars = nil,
           gametip = { lines = {} }, withSettings = false, settingsReg = {},
           settingsChecks = 0, settingCallbacks = {} }
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

local function xpEvent(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_XP_UPDATE")
end

-- Hover the bar: the client clears and rebuilds the tooltip per show.
local function hover(w)
  w.frame.scripts.OnEnter(w.frame)
end

local function tiptexts(w)
  local out = {}
  for _, l in ipairs(w.gametip.lines) do out[#out + 1] = l.text end
  return out
end

local function tiphas(w, text)
  for _, t in ipairs(tiptexts(w)) do if t == text then return true end end
  return false
end

local function tipcolor(w, text)
  for _, l in ipairs(w.gametip.lines) do
    if l.text == text then return { l.r, l.g, l.b } end
  end
  return nil
end

local function sameColor(c, want)
  return c ~= nil and c[1] == want[1] and c[2] == want[2] and c[3] == want[3]
end

local function wear(w, ...)
  for _, slotName in ipairs({ ... }) do w.equipped[w.slotIDs[slotName]] = 7 end
end

local function setQuests(w, list)
  -- list: { { id = n, xp = n|nil, ready = bool, header = bool } }
  w.quests, w.ready, w.questReward = {}, {}, {}
  for _, q in ipairs(list) do
    w.quests[#w.quests + 1] = { id = q.id, header = q.header }
    if q.ready then w.ready[q.id] = true end
    if q.xp ~= nil then w.questReward[q.id] = q.xp end
  end
end

local function setFactions(w, list)
  -- list: { { id = n, name = s, reaction = n, lo = n, hi = n,
  --            standing = n, header = bool, bonus = bool } }
  w.factions = {}
  for _, f in ipairs(list) do w.factions[#w.factions + 1] = f end
end

local function repEvent(w)
  w.frame.scripts.OnEvent(w.frame, "UPDATE_FACTION")
end

local function maxLevelEvent(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_MAX_LEVEL_UPDATE")
end

local function capWorld(w)
  -- At cap the client reports a phantom 100M requirement, never 0
  -- (seen live on a level 90); cap detection is a level comparison.
  w.level, w.xp, w.max = 90, 0, 100000000
end

-- 1. SavedVariables rebind, defaults, and the one-time notice.
do
  local w = newWorld()
  w.savedVars = { shown = false, locked = true, hideDefault = false,
                  point = "TOPLEFT", x = 10, y = -20 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("db rebind keeps saved shown=false", ns.db.shown == false)
  check("db rebind keeps saved locked=true", ns.db.locked == true)
  check("db rebind keeps saved hideDefault=false", ns.db.hideDefault == false)
  check("db rebind keeps saved position", ns.db.point == "TOPLEFT" and ns.db.x == 10 and ns.db.y == -20)
  check("rebound frame hidden", w.frame.shown == false)
  check("rebound frame positioned", w.frame.point[1] == "TOPLEFT" and w.frame.point[2] == 10 and w.frame.point[3] == -20)
  check("mouse stays on for the tooltip", w.frame.mouse == true)
  check("opt-out keeps the native bar", w.native.shown == true)
  check("opt-out skips the notice", #w.printed == 0)
end
do -- fresh profile gets all defaults and hides the native bar
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  check("fresh shown defaults true", ns.db.shown == true)
  check("fresh locked defaults false", ns.db.locked == false)
  check("fresh hideDefault defaults true", ns.db.hideDefault == true)
  check("fresh repMode defaults true", ns.db.repMode == true)
  check("fresh followLatest defaults false", ns.db.followLatest == false)
  check("fresh position defaults", ns.db.point == "BOTTOM" and ns.db.x == 0 and ns.db.y == 100)
  check("fresh frame shown", w.frame.shown == true)
  check("fresh native hidden", w.native.shown == false)
  check("fresh announces once", #w.printed == 1 and w.printed[1] ==
    "|cff66ccffVocXP|r: the default XP bar hides while VocXP shows (/vxp config to change it)")
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("notice never repeats", #w.printed == 1)
end

-- 2. Bar construction mirrors Blizzard's ExpStatusBarTemplate.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("frame holds bar and lines", w.frame.size[1] == 571 and w.frame.size[2] == 55)
  check("rate line face", w.rate.template == "GameFontNormal")
  check("rate line shadow", w.rate.shadow[1] == 1 and w.rate.shadow[2] == -1)
  check("rate line under bar", w.rate.point[1] == "TOP" and w.rate.point[3] == "TOP" and w.rate.point[5] == -22)
  check("rate line snapped", w.rate.rounded == true)
  check("bar sits in the art", w.bar.size[1] == 565 and w.bar.size[2] == 11 and w.bar.point[1] == "TOPLEFT" and w.bar.point[2] == 1 and w.bar.point[3] == -1)
  check("stats line face", w.sub.template == "GameFontNormal")
  check("stats line shadow", w.sub.shadow[1] == 1 and w.sub.shadow[2] == -1)
  check("stats line under rate", w.sub.point[1] == "TOP" and w.sub.point[2] == w.rate)
  check("stats line snapped", w.sub.rounded == true)
  check("stats line starts hidden", w.sub.shown == false)
  check("label carries the 1px shadow", w.label.shadow[1] == 1 and w.label.shadow[2] == -1)
  check("every region snaps to pixels", w.frame.rounded == true and w.bar.rounded == true
    and w.bg.rounded == true and w.restFill.rounded == true and w.questFill.rounded == true
    and w.pip.rounded == true and w.label.rounded == true
    and w.rate.rounded == true and w.sub.rounded == true
    and w.frameTex.rounded == true)
  check("animated bar needs no raw texture", w.bar.minmax == nil and w.bar.barTexture == nil)
  check("background atlas", w.bg.atlas == "UI-HUD-ExperienceBar-Background")
  check("rested wears prediction", w.restFill.atlas == "UI-HUD-ExperienceBar-Fill-Prediction")
  check("quests wear the gain look", w.questFill.atlas == "UI-HUD-ExperienceBar-Fill-Prediction"
    and w.questFill.blend == nil
    and w.questFill.vertex[1] == 0.901 and w.questFill.vertex[2] == 0.8
    and w.questFill.vertex[3] == 0.601)
  check("quest overlay above rested", w.restFill.layer == "ARTWORK" and w.restFill.sublevel == -1
    and w.questFill.layer == "ARTWORK" and w.questFill.sublevel == 0)
  check("overlays start hidden", w.restFill.shown == false and w.questFill.shown == false)
  check("label uses the highlight face", w.label.template == "GameFontHighlight")
  check("label centered", w.label.point[1] == "CENTER" and w.label.point[4] == 0
    and w.label.point[5] == 1)
  check("bar uses the animated template", w.bar.template == "GradualAnimatedStatusBarTemplate")
  check("frame stroke atlas", w.frameTex.atlas == "UI-HUD-ExperienceBar-Frame" and w.frameTex.atlasSize == true)
  check("pip atlas", w.pip.atlas == "UI-HUD-ExperienceBar-Frame-Pip")
  check("pip starts hidden", w.pip.shown == false)
  check("art pins its size", w.bg.atlasSize == false and w.restFill.atlasSize == false
    and w.questFill.atlasSize == false and w.pip.atlasSize == false)
  check("frame movable", w.frame.movable == true)
  check("frame clamped", w.frame.clamped == true)
  check("frame drags on left button", w.frame.dragButton == "LeftButton")
end

-- 3. Bar render: progress, label, and both overlays.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  check("progress value", w.bar.value == 500)
  check("bar label", w.label.text == "10  500/1k (50%)")
  check("unrested bar atlas", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Experience")
  check("animated values", w.bar.animated[1] == 500 and w.bar.animated[2] == 0
    and w.bar.animated[3] == 1000 and w.bar.animated[4] == 10)
  check("unrested flare pair", w.bar.flare[1] == "UI-HUD-ExperienceBar-Flare-XP-2x-Flipbook"
    and w.bar.flare[2] == "UI-HUD-ExperienceBar-Fill-Experience-2x-Flipbook")
end
do -- rested overlay reaches past progress and swaps the fill
  local w = newWorld()
  w.restedXp = 300
  loadAddon(w)
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  check("rested overlay shown", w.restFill.shown == true)
  check("rested overlay width", close(w.restFill.width, 452))
  check("rested overlay cropped, not stretched", w.restFill.texcoord ~= nil
    and close(w.restFill.texcoord[1], 0) and close(w.restFill.texcoord[2], 0.8))
  check("rested bar atlas", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Rested")
  check("rested flare pair", w.bar.flare[1] == "UI-HUD-ExperienceBar-Flare-Rested-2x-Flipbook"
    and w.bar.flare[2] == "UI-HUD-ExperienceBar-Fill-Rested-2x-Flipbook")
  check("pip rides rested", w.pip.shown == true and close(w.pip.points[1][4], 452))
  hover(w)
  check("tooltip rested line", tiphas(w, "Rested: 30% of level"))
end
do -- exhaustion events repaint the rested layer
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("exhaustion events registered",
    w.frame.events.UPDATE_EXHAUSTION == true and w.frame.events.PLAYER_UPDATE_RESTING == true)
  w.restedXp = 1000
  w.frame.scripts.OnEvent(w.frame, "UPDATE_EXHAUSTION")
  check("exhaustion paints rested", w.restFill.shown == true and close(w.restFill.width, 565))
  w.restedXp = nil
  w.frame.scripts.OnEvent(w.frame, "PLAYER_UPDATE_RESTING")
  check("rest change clears rested", w.restFill.shown == false)
end
do -- disabled XP gain hides the rested layer like the native bar
  local w = newWorld()
  w.restedXp = 500
  w.xpDisabled = true
  loadAddon(w)
  clientLoaded(w)
  check("xp-disabled hides rested", w.restFill.shown == false)
  check("xp-disabled keeps xp fill", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Experience")
  check("xp-disabled hides pip", w.pip.shown == false)
end
do -- quest overlay spans from progress to the turn-in reach
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  setQuests(w, { { id = 11, xp = 100, ready = true }, { id = 12, xp = 200, ready = true } })
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  check("quest overlay shown", w.questFill.shown == true)
  check("quest overlay starts at progress", close(w.questFill.points[1][4], 282.5))
  check("quest overlay width", close(w.questFill.width, 169.5))
  check("quest overlay cropped to its span", w.questFill.texcoord ~= nil
    and close(w.questFill.texcoord[1], 0.5) and close(w.questFill.texcoord[2], 0.8))
  hover(w)
  check("tooltip quest line", tiphas(w, "2 quests ready: 30% of level"))
end
do -- rested stacks beyond quest: the pip marks true runout past turn-ins
  local w = newWorld()
  w.restedXp = 200
  loadAddon(w)
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  setQuests(w, { { id = 11, xp = 100, ready = true } })
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  check("stacked rested width", close(w.restFill.width, 452))
  check("stacked pip past quest edge", w.pip.shown == true
    and close(w.pip.points[1][4], 452) and w.questFill.width < 452)
end
do -- one quest reads singular
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  setQuests(w, { { id = 11, xp = 1000, ready = true } })
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  hover(w)
  check("tooltip one quest", tiphas(w, "1 quest ready: 100% of level"))
end
do -- overlays clamp at the bar edge, never past it
  local w = newWorld()
  w.restedXp = 5000
  loadAddon(w)
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  setQuests(w, { { id = 11, xp = 5000, ready = true } })
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  check("rested clamps", close(w.restFill.width, 565))
  check("quest clamps", close(w.questFill.width, 282.5))
end

-- 31. Native fidelity: the pip, the plain-bar fallback, atlas failure.
do -- pip centers on the rested reach
  local w = newWorld()
  w.restedXp = 100
  loadAddon(w)
  clientLoaded(w)
  w.xp = 400
  xpEvent(w)
  check("pip centered", w.pip.points[1][1] == "CENTER" and close(w.pip.points[1][4], 282.5) and w.pip.points[1][5] == 2)
  check("pip size", w.pip.size[1] == 10 and w.pip.size[2] == 14)
end
do -- pip hides at the bar edges like the native one
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.restedXp = 1000 -- rested reach: the full bar
  w.frame.scripts.OnEvent(w.frame, "UPDATE_EXHAUSTION")
  check("full rested hides pip", w.pip.shown == false)
  check("full rested keeps fill", w.restFill.shown == true)
  w.xp, w.restedXp = 0, 5 -- rested reach under 1%
  xpEvent(w)
  check("sliver rested hides pip", w.pip.shown == false)
  check("sliver rested keeps fill", w.restFill.shown == true)
end
do -- missing template falls back to a plain bar
  local w = newWorld()
  w.failTemplate = true
  w.restedXp = 300
  loadAddon(w)
  check("fallback drops template", w.bar.template == nil)
  check("fallback wears the file texture", w.bar.barTexture == "Interface\\TargetingFrame\\UI-StatusBar")
  check("fallback starts 0 to 1", w.bar.minmax[1] == 0 and w.bar.minmax[2] == 1)
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  check("fallback paints value", w.bar.value == 500 and w.bar.minmax[2] == 1000)
  check("fallback fill atlas", w.bar.fillTex.atlas == "UI-HUD-ExperienceBar-Fill-Rested" and w.bar.fillTex.atlasSize == false)
  check("fallback no flare", w.bar.flare == nil)
  check("fallback pip works", w.pip.shown == true)
end
do -- missing atlases hide their layers, never the bar
  local w = newWorld()
  w.noAtlas = true
  loadAddon(w)
  clientLoaded(w)
  w.xp, w.restedXp = 500, 300
  xpEvent(w)
  check("no-atlas bg hidden", w.bg.shown == false)
  check("no-atlas frame hidden", w.frameTex.shown == false)
  check("no-atlas overlays hidden", w.restFill.shown == false
    and w.questFill.shown == false and w.pip.shown == false)
  check("no-atlas bar paints", w.bar.value == 500 and w.label.text == "10  500/1k (50%)")
end

-- 32. Stats line: ready quests and rested reach, always on screen.
do
  local w = newWorld()
  local ns = loadAddon(w)
  local snap = { level = 10, xp = 500, req = 1000, capped = false }
  local both = ns.barSegments(snap, 300, 200)
  check("stats both", ns.subStatsLine(both, 2) == "2 quests ready: 20% · Rested: 30%")
  check("stats singular", ns.subStatsLine(both, 1) == "1 quest ready: 20% · Rested: 30%")
  local quests = ns.barSegments(snap, 0, 200)
  check("stats quests only", ns.subStatsLine(quests, 2) == "2 quests ready: 20%")
  local rested = ns.barSegments(snap, 300, 0)
  check("stats rested only", ns.subStatsLine(rested, 0) == "Rested: 30%")
  check("stats count without reach hides",
    ns.subStatsLine(ns.barSegments(snap, 0, 0), 2) == nil)
  check("stats neither hides", ns.subStatsLine(ns.barSegments(snap, 0, 0), 0) == nil)
  check("stats nil seg hides", ns.subStatsLine(nil, 2) == nil)
end
do -- refresh paints and clears the line live
  local w = newWorld()
  w.restedXp = 300
  loadAddon(w)
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  setQuests(w, { { id = 11, xp = 100, ready = true }, { id = 12, xp = 100, ready = true } })
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  check("stats paints", w.sub.shown == true
    and w.sub.text == "2 quests ready: 20% · Rested: 30%")
  setQuests(w, {})
  w.restedXp = nil
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  check("stats clears", w.sub.shown == false)
end

-- 33. Rate line: XP/hr and time-to-level, always on screen.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("rate collects", w.rate.text == "Collecting data")
  w.now = w.now + 1800
  w.xp = 500
  xpEvent(w)
  check("rate paints", w.rate.text == "3k XP/hr · 15m")
  w.env.SlashCmdList.VOCXP("pause")
  check("rate pauses", w.rate.text == "Paused")
end

-- 34. Degradation: font fallback, sub-1% reach hides.
do
  local w = newWorld()
  w.failFont = "GameFontHighlight"
  loadAddon(w)
  check("font fallback", w.label.template == "GameFontNormal")
end
do -- slivers show in the overlays but never as 0% lines
  local w = newWorld()
  local ns = loadAddon(w)
  local seg = ns.barSegments({ level = 75, xp = 9428, req = 69130, capped = false }, 100, 0)
  check("sliver stats hides", ns.subStatsLine(seg, 0) == nil)
  w.restedXp = 100
  w.xp, w.max = 9428, 69130
  clientLoaded(w)
  hover(w)
  check("sliver tooltip hides", not tiphas(w, "Rested: 0%"))
  check("sliver overlay shows", w.restFill.shown == true)
end

-- 4. Segment math is pure and total: nil for no-bar, clamped else.
do
  local w = newWorld()
  local ns = loadAddon(w)
  local seg = ns.barSegments({ level = 10, xp = 250, req = 1000, capped = false }, 250, 500)
  check("segment fractions", close(seg.progress, 0.25) and close(seg.restedEnd, 1.0)
    and close(seg.questEnd, 0.75))
  check("segments stack, never overlap", seg.questEnd >= seg.progress
    and seg.restedEnd >= seg.questEnd)
  check("segment flags", seg.hasRested == true and seg.hasQuest == true)
  local noQuest = ns.barSegments({ level = 10, xp = 250, req = 1000, capped = false }, 250, 0)
  check("no quest reduces to native", close(noQuest.restedEnd, 0.5) and noQuest.hasQuest == false)
  local noRested = ns.barSegments({ level = 10, xp = 250, req = 1000, capped = false }, 0, 500)
  check("no rested, no rested tail", close(noRested.restedEnd, 0.75) and noRested.hasRested == false)
  check("segment percents", close(seg.pct, 25) and close(seg.restedPct, 25) and close(seg.questPct, 50))
  check("segment label", ns.barLabel({ level = 10, xp = 250, req = 1000 }, seg) == "10  250/1k (25%)")
  check("label rounds half up",
    ns.barLabel({ level = 10, xp = 1, req = 200 }, ns.barSegments(
      { level = 10, xp = 1, req = 200, capped = false })) == "10  1/200 (1%)")
  check("capped has no bar", ns.barSegments({ level = 80, xp = 0, req = 0, capped = true }) == nil)
  check("invalid has no bar", ns.barSegments({ level = 10, xp = 500 }, 10, 10) == nil)
  check("nil has no bar", ns.barSegments(nil, 10, 10) == nil)
  local bad = ns.barSegments({ level = 10, xp = 500, req = 1000, capped = false }, -5, 0 / 0)
  check("bad overlays vanish", bad.restedEnd == bad.progress and bad.questEnd == bad.progress)
  local over = ns.barSegments({ level = 10, xp = 900, req = 1000, capped = false }, 500, 500)
  check("overlays clamp at full", over.restedEnd == 1 and over.questEnd == 1)
end

-- 5. Max level pivots to reputation; the native bar stays hidden.
do -- watched faction takes the bar with its rank context
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  check("rep mode shown", w.frame.shown == true)
  check("rep mode hides native", w.native.shown == false)
  check("rep mode announces twice", #w.printed == 2
    and w.printed[1] == "|cff66ccffVocXP|r: tracking reputation at max level (/vxp config to turn it off)"
    and w.printed[2] == "|cff66ccffVocXP|r: the default XP bar hides while VocXP shows (/vxp config to change it)")
  check("rep mode keeps ticker", #w.tickers == 1)
  check("rep events registered", w.frame.events.UPDATE_FACTION == true
    and w.frame.events.MAJOR_FACTION_RENOWN_LEVEL_CHANGED == true)
  check("xp events unregistered", w.frame.events.PLAYER_XP_UPDATE == nil
    and w.frame.events.QUEST_LOG_UPDATE == nil and w.frame.events.UPDATE_EXHAUSTION == nil)
  check("rep aura stays", w.frame.events.UNIT_AURA == true)
  check("rep bar label", w.label.text == "Court  3k/9k (33%)")
  check("rep fill green", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
  check("rep flare pair", w.bar.flare[1] == "UI-HUD-ExperienceBar-Flare-Reputation-2x-Flipbook"
    and w.bar.flare[2] == "UI-HUD-ExperienceBar-Fill-Reputation-2x-Flipbook")
  check("rep overlays off", w.restFill.shown == false and w.questFill.shown == false
    and w.pip.shown == false)
  check("rep rate collects", w.rate.text == "Collecting data")
  check("rep stats rank", w.sub.shown == true and w.sub.text == "Honored · 33% to Revered")
end
do -- nothing tracked: guidance instead of a blank bar
  local w = newWorld()
  capWorld(w)
  loadAddon(w)
  clientLoaded(w)
  check("untracked shown", w.frame.shown == true)
  check("untracked keeps native hidden", w.native.shown == false)
  check("untracked label", w.label.text == "No faction tracked")
  check("untracked bar empty", w.bar.value == 0)
  check("untracked rate", w.rate.text == "No reputation tracked")
  check("untracked hides stats", w.sub.shown == false)
  hover(w)
  check("untracked tooltip", tiptexts(w)[1] == "No reputation tracked"
    and tiptexts(w)[2] == "Watch a faction to track it")
end
do -- cap raised later: next login wakes XP back up
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  w.level, w.max = 10, 100000
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("cap raise reshows", w.frame.shown == true)
  check("cap raise rehides native", w.native.shown == false)
  check("cap raise keeps one ticker", #w.tickers == 1 and w.tickers[1].cancelled ~= true)
  check("cap raise repaints", w.label.text == "10  0/100k (0%)")
  check("cap raise swaps events", w.frame.events.PLAYER_XP_UPDATE == true
    and w.frame.events.UPDATE_FACTION == nil)
end
do -- toggle at max level works like any bar now
  local w = newWorld()
  capWorld(w)
  loadAddon(w)
  clientLoaded(w)
  w.env.SlashCmdList.VOCXP("")
  check("rep toggle hides", w.frame.shown == false)
  check("rep toggle announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: hidden")
end
do -- repMode off: the old dormancy, native bar back
  local w = newWorld()
  capWorld(w)
  w.savedVars = { repMode = false }
  loadAddon(w)
  clientLoaded(w)
  check("dormant hidden", w.frame.shown == false)
  check("dormant restores native", w.native.shown == true)
  check("dormant skips notices", #w.printed == 0)
  check("dormant tickerless", #w.tickers == 0)
  w.env.SlashCmdList.VOCXP("")
  check("dormant toggle stays hidden", w.frame.shown == false)
  check("dormant toggle announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: max level (stays hidden)")
end

-- 6. Native-bar hiding is enforced every refresh and restored on exit.
do -- toggling our bar restores and rehides the native one
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  slash("")
  check("our hide restores native", w.native.shown == true)
  slash("")
  check("our show rehides native", w.native.shown == false)
end
do -- an Edit Mode reshow lasts at most one refresh
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.native.shown = true -- Edit Mode reshows the cluster
  w.tickers[1].fn()
  check("refresh re-hides native", w.native.shown == false)
end
do -- missing manager degrades to a lone bar, never an error
  local w = newWorld()
  loadAddon(w)
  w.env.StatusTrackingBarManager = nil
  clientLoaded(w)
  w.xp = 500
  xpEvent(w)
  check("no manager still paints", w.bar.value == 500)
end
do -- partial manager (no methods) is left alone
  local w = newWorld()
  loadAddon(w)
  w.env.StatusTrackingBarManager = {}
  clientLoaded(w)
  check("methodless manager ignored", w.frame.shown == true)
end

-- 7. Quest scan: ready quests summed, everything else skipped,
-- selection restored, re-entry safe.
do
  local w = newWorld()
  local ns = loadAddon(w)
  setQuests(w, {
    { id = 10, header = true },
    { id = 11, xp = 100, ready = true },
    { id = 12, xp = 200, ready = false },
    { id = 13, xp = 0, ready = true },
  })
  local total, count = ns.scanQuestXp()
  check("scan sums ready xp", total == 100)
  check("scan counts paid quests", count == 1)
end
do -- nil entries and unpaid quests never break the scan
  local w = newWorld()
  local ns = loadAddon(w)
  setQuests(w, { { id = 11, ready = true } }) -- no xp entry: unpaid
  w.quests[2] = nil -- hole reads as nil
  local total, count = ns.scanQuestXp()
  check("unpaid quest skipped", total == 0 and count == 0)
end
do -- the previous selection is restored
  local w = newWorld()
  local ns = loadAddon(w)
  w.selectedQuest = 99
  setQuests(w, { { id = 11, xp = 100, ready = true } })
  ns.scanQuestXp()
  check("selection restored", w.selectedQuest == 99)
  check("restore is last", w.selectLog[#w.selectLog] == 99)
end
do -- zero selection needs no restore
  local w = newWorld()
  local ns = loadAddon(w)
  setQuests(w, { { id = 11, xp = 100, ready = true } })
  ns.scanQuestXp()
  check("no restore for zero", #w.selectLog == 1 and w.selectLog[1] == 11)
end
do -- a missing API anywhere in the chain means no overlay
  local w = newWorld()
  local ns = loadAddon(w)
  setQuests(w, { { id = 11, xp = 100, ready = true } })
  w.env.C_QuestLog = nil
  check("no quest namespace degrades", ns.scanQuestXp() == 0)
  loadAddon(newWorld()) -- reload for a clean namespace, then break one link
  local w2 = newWorld()
  local ns2 = loadAddon(w2)
  setQuests(w2, { { id = 11, xp = 100, ready = true } })
  w2.env.C_QuestLog.ReadyForTurnIn = nil
  check("missing link degrades", ns2.scanQuestXp() == 0)
  w2.env.GetQuestLogRewardXP = nil
  check("missing reward reader degrades", ns2.scanQuestXp() == 0)
end
do -- a quest event mid-scan re-renders instead of recursing
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  setQuests(w, { { id = 11, xp = 100, ready = true }, { id = 12, xp = 200, ready = true } })
  local fired = false
  local realSet = w.env.C_QuestLog.SetSelectedQuest
  w.env.C_QuestLog.SetSelectedQuest = function(id)
    realSet(id)
    if not fired then
      fired = true
      w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
    end
  end
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  check("re-entrant scan completes", fired == true)
  check("re-entrant scan totals", ns.scanQuestXp() == 300)
end
do -- every quest event rescans and repaints
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_ACCEPTED",
                       "QUEST_REMOVED", "QUEST_COMPLETE" }) do
    check("quest event registered: " .. e, w.frame.events[e] == true)
  end
  setQuests(w, { { id = 11, xp = 1000, ready = true } })
  w.frame.scripts.OnEvent(w.frame, "QUEST_TURNED_IN")
  check("turn-in rescans", w.questFill.shown == true)
  setQuests(w, {})
  w.frame.scripts.OnEvent(w.frame, "QUEST_REMOVED")
  check("removal clears", w.questFill.shown == false)
end

-- 8. Tooltip: gold title, rate, status, bonuses, gaps, slash hint.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("tooltip anchors above the bar", w.gametip.owner == w.frame
    and w.gametip.anchor == "ANCHOR_TOP" and w.gametip.shown == true)
  check("tooltip title is gold", w.gametip.title == "VocXP" and sameColor(w.gametip.titleColor, GOLD_C))
  local lines = tiptexts(w)
  check("tooltip rate first", lines[1] == "Collecting data" and lines[2] == "Collecting data")
  check("tooltip teaches the slash", lines[#lines]:find("/vxp", 1, true) ~= nil)
end
do -- full stack orders every section
  local w = newWorld()
  w.warMode, w.restedXp = true, 500
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  setQuests(w, { { id = 11, xp = 100, ready = true } })
  w.frame.scripts.OnEvent(w.frame, "QUEST_LOG_UPDATE")
  hover(w)
  check("tooltip order", table.concat(tiptexts(w), "|") == table.concat({
    "0 XP/hr",
    "Warming up · last 1m of 10m",
    "Rested: 50% of level",
    "1 quest ready: 10% of level",
    "+10% War Mode",
    "Rested",
    "+10% WHEE! (Faire week)",
    "+10% Wickerman (Hallow's End)",
    "Warband Mentored (needs a max-level character)",
    "/vxp shows or hides it. /vxp help lists the rest.",
  }, "|"))
  check("tooltip bonus green", sameColor(tipcolor(w, "+10% War Mode"), GREEN_C))
end
do -- bonus and gap colors
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("no-bonus red", sameColor(tipcolor(w, "No XP bonus"), RED_C))
  check("gap muted", sameColor(tipcolor(w, "Rested (rest in town)"), MUTED_C))
  local sub = w.gametip.lines[2]
  check("sub muted", sub.text == "Collecting data"
    and sameColor({ sub.r, sub.g, sub.b }, MUTED_C))
end
do -- leaving the bar hides the tooltip
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  w.frame.scripts.OnLeave(w.frame)
  check("leave hides tooltip", w.gametip.shown == false)
end
do -- mid-drag hover stays silent, then works after the drop
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnDragStart(w.frame)
  w.frame.scripts.OnEnter(w.frame)
  check("drag suppresses tooltip", w.gametip.shown ~= true)
  w.frame.point = { "TOPLEFT", 50, -60 }
  w.frame.scripts.OnDragStop(w.frame)
  w.frame.scripts.OnEnter(w.frame)
  check("drop restores tooltip", w.gametip.shown == true)
end

-- 9. Edit Mode cooperation: tempers the lock, persists nothing.
do
  local w = newWorld()
  w.savedVars = { locked = true }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("edit callbacks registered",
    type(w.editCallbacks["EditMode.Enter"]) == "function"
    and type(w.editCallbacks["EditMode.Exit"]) == "function")
  w.frame.scripts.OnDragStart(w.frame)
  check("locked drag blocked", w.frame.moving ~= true)
  w.editCallbacks["EditMode.Enter"]()
  check("enter flags active", ns.editModeActive == true)
  w.frame.scripts.OnDragStart(w.frame)
  check("edit session drags locked", w.frame.moving == true)
  w.frame.point = { "TOPLEFT", 50, -60 }
  w.frame.scripts.OnDragStop(w.frame)
  check("edit drag persists", ns.db.point == "TOPLEFT" and ns.db.x == 50 and ns.db.y == -60)
  w.editCallbacks["EditMode.Exit"]()
  check("exit clears active", ns.editModeActive == false)
  w.frame.scripts.OnDragStart(w.frame)
  check("exit restores lock", w.frame.moving ~= true)
  check("lock itself untouched", ns.db.locked == true)
end
do -- no EventRegistry: dragging behaves exactly as it always has
  local w = newWorld()
  w.savedVars = { locked = true }
  local ns = loadAddon(w)
  w.env.EventRegistry = nil
  clientLoaded(w)
  w.frame.scripts.OnDragStart(w.frame)
  check("no-registry locked drag blocked", w.frame.moving ~= true)
  ns.setEditModeActive(true) -- direct flag still tempers (belt and braces)
  w.frame.scripts.OnDragStart(w.frame)
  check("flag tempers lock", w.frame.moving == true)
end
do -- the flag coerces to boolean and subscribing is idempotent
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.setEditModeActive(1)
  check("truthy coerces", ns.editModeActive == true)
  ns.setEditModeActive(nil)
  check("nil coerces", ns.editModeActive == false)
  local enter = w.editCallbacks["EditMode.Enter"]
  ns.subscribeEditMode()
  check("subscribe once", w.editCallbacks["EditMode.Enter"] == enter)
end

-- 10. Dragging persists the position.
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
do -- fractional drops round to the pixel grid
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnDragStart(w.frame)
  w.frame.point = { "TOPLEFT", 50.6, -60.4 } -- the client moved it
  w.frame.scripts.OnDragStop(w.frame)
  check("drop rounds", ns.db.x == 51 and ns.db.y == -60)
end

-- 11. /vxp toggles the bar; /vxp lock gates the drag, never the mouse.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("slash registered", w.env.SLASH_VOCXP1 == "/vxp" and w.env.SlashCmdList.VOCXP ~= nil)
  check("long slash registered", w.env.SLASH_VOCXP2 == "/vocxp" and w.env.SLASH_VOCXP3 == nil)
  local slash = w.env.SlashCmdList.VOCXP
  slash("")
  check("slash hides", w.frame.shown == false)
  check("slash hide announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: hidden")
  slash("")
  check("slash shows", w.frame.shown == true)
  check("slash show announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: shown")
end
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  slash("lock")
  check("lock gates drag", ns.db.locked == true)
  w.frame.scripts.OnDragStart(w.frame)
  check("locked drag blocked", w.frame.moving ~= true)
  check("lock keeps mouse", w.frame.mouse == true)
  check("lock announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: locked")
  slash("  LOCK  ")
  check("lock toggles back", ns.db.locked == false)
  check("unlock announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: unlocked, drag to move")
end

-- 12. Session rate flows into the tooltip; the bar tracks the level.
do -- XP gain accumulates into the session rate
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 1800
  w.xp = 500
  xpEvent(w)
  hover(w)
  local lines = tiptexts(w)
  check("rate line", lines[1] == "3k XP/hr · 15m")
  check("rate sub", lines[2] == "Last 10m")
  check("rate no-bonus", tiphas(w, "No XP bonus"))
  check("bar tracks xp", w.bar.value == 500)
end
do -- level-up carries the remainder across the bar
  local w = newWorld()
  w.xp, w.max = 900, 1000
  loadAddon(w)
  clientLoaded(w)
  w.xp, w.max, w.level = 100, 2000, 11
  w.now = w.now + 3600
  xpEvent(w)
  hover(w)
  check("level-up carries", tiptexts(w)[1] == "1k XP/hr · 2h23m")
  check("bar shows new level", w.label.text == "11  100/2k (5%)")
end
do -- /vxp reset zeroes the session
  local w = newWorld()
  w.xp, w.max = 0, 100000
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 5000
  xpEvent(w)
  w.now = w.now + 100
  w.env.SlashCmdList.VOCXP("reset")
  hover(w)
  check("reset collects", tiptexts(w)[1] == "Collecting data")
  check("reset announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: session reset")
  w.now = w.now + 60
  w.xp = 6000
  xpEvent(w)
  hover(w)
  check("reset clears history", tiptexts(w)[1] == "60k XP/hr · 1h34m")
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
  hover(w)
  check("pause display", tiptexts(w)[1] == "Paused" and tiptexts(w)[2] == "Tracking paused")
  check("pause announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: paused")
  w.now = w.now + 60
  w.xp = 600
  xpEvent(w)
  hover(w)
  check("pause ignores awards", tiptexts(w)[1] == "Paused")
  slash("pause")
  hover(w)
  check("resume collects", tiptexts(w)[1] == "Collecting data")
  check("resume announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: resumed")
  w.now = w.now + 60
  w.xp = 900
  xpEvent(w)
  hover(w)
  check("resume no backfill", tiptexts(w)[1] == "18k XP/hr · <1m")
end

-- 13. The ticker refreshes the rate between XP events.
do
  local w = newWorld()
  w.xp, w.max = 0, 100000
  loadAddon(w)
  clientLoaded(w)
  check("ticker registered", #w.tickers == 1 and w.tickers[1].secs == 1)
  w.now = w.now + 10
  w.xp = 3600
  xpEvent(w)
  hover(w)
  check("early gain collects", tiptexts(w)[1] == "1.3m XP/hr" and tiptexts(w)[2] == "Collecting data")
  w.now = w.now + 290
  w.tickers[1].fn()
  hover(w)
  check("ticker holds window", tiptexts(w)[1] == "43k XP/hr · 2h14m")
  check("ticker sub", tiptexts(w)[2] == "Warming up · last 5m of 10m")
  w.now = w.now + 11
  w.tickers[1].fn()
  hover(w)
  check("ticker warming rate", tiptexts(w)[1] == "42k XP/hr · 2h19m")
  w.now = w.now + 300
  w.tickers[1].fn()
  hover(w)
  check("ticker expires award", tiptexts(w)[1] == "0 XP/hr")
  check("expired sub", tiptexts(w)[2] == "No XP in the last 10m")
end

-- 14. Slash toggles confirm with sounds: open/close for the bar,
-- the checkbox pair for lock, pause, and reset (numeric fallback: the
-- harness provides no SOUNDKIT table).
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
  check("toggle sounds", table.concat(w.sounds, ",") == "851,850,856,857,856,857,856")
  w.env.SOUNDKIT = { IG_MAINMENU_OPEN = 1850, IG_MAINMENU_CLOSE = 1851 }
  w.sounds = {}
  slash("")
  slash("")
  check("SOUNDKIT names win over the fallback", table.concat(w.sounds, ",") == "1851,1850")
  w.env.PlaySound = nil
  w.sounds = {}
  slash("") -- no sound API: silent, never an error
  check("no sound API is silent", #w.sounds == 0)
end

-- Tooltip line helpers: green bonus lines and muted gap lines, in order.
local function greenlines(w)
  local out = {}
  for _, l in ipairs(w.gametip.lines) do
    if sameColor({ l.r, l.g, l.b }, GREEN_C) then out[#out + 1] = l.text end
  end
  return table.concat(out, "\n")
end

local function missinglines(w)
  -- Muted lines between the status line and the slash hint are the gaps.
  local texts = tiptexts(w)
  local out = {}
  for i = 3, #texts - 1 do
    local l = w.gametip.lines[i]
    if sameColor({ l.r, l.g, l.b }, MUTED_C) then out[#out + 1] = l.text end
  end
  return table.concat(out, "\n")
end

local function auraTick(w)
  w.now = w.now + 60
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  hover(w)
end

-- 15. Bonus lines: every active XP source, highest value first.
do
  local w = newWorld()
  w.warMode = true
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("war mode line", tiptexts(w)[1] == "0 XP/hr" and greenlines(w) == "+10% War Mode")
end
do
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("rested line", greenlines(w) == "Rested")
end
do
  local w = newWorld()
  w.warMode, w.restedXp = true, 400
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("bonuses stack", greenlines(w) == "+10% War Mode\nRested")
end
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("no bonus line", tiphas(w, "No XP bonus") and greenlines(w) == "")
end
do -- Call to Arms raises the Enlisted value above the +10% base
  local w = newWorld()
  w.warMode, w.warBonus = true, 15
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("war mode live value", greenlines(w) == "+15% War Mode")
end
do
  local w = newWorld()
  w.warMode, w.warBonus = true, 30
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("war mode high call", greenlines(w) == "+30% War Mode")
end
do -- missing bonus API falls back to the +10% base
  local w = newWorld()
  w.warMode = true
  loadAddon(w)
  w.env.C_PvP = { IsWarModeDesired = function() return true end }
  clientLoaded(w)
  auraTick(w)
  check("war mode fallback", greenlines(w) == "+10% War Mode")
end
do -- out-of-range value is not trusted
  local w = newWorld()
  w.warMode, w.warBonus = true, 5000
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("war mode range gate", greenlines(w) == "+10% War Mode")
end
do
  local w = newWorld()
  w.auras[430191] = { points = { 20 } }
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("mentored line", greenlines(w) == "+20% Warband Mentored")
end
do
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("whee line", greenlines(w) == "+10% WHEE!")
end
do
  local w = newWorld()
  w.auras[136583] = {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("top hat line", greenlines(w) == "+10% Darkmoon Top Hat")
end
do
  local w = newWorld()
  w.auras[24705] = {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("grim visage line", greenlines(w) == "+10% Grim Visage")
end
do
  local w = newWorld()
  w.auras[95987] = {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("unburdened line", greenlines(w) == "+10% Unburdened")
end
do
  local w = newWorld()
  w.warMode, w.restedXp = true, 400
  w.auras[430191], w.auras[46668] = { points = { 20 } }, {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("bonuses sort by value", greenlines(w) ==
    "+20% Warband Mentored\n+10% War Mode\n+10% WHEE!\nRested")
end
do -- highest bonus first across sources
  local w = newWorld()
  w.warMode, w.warBonus, w.restedXp = true, 30, 400
  w.auras[430191], w.auras[46668] = { points = { 20 } }, {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("bonuses sort descending", greenlines(w) ==
    "+30% War Mode\n+20% Warband Mentored\n+10% WHEE!\nRested")
end
do -- lines without a number trail the valued lines
  local w = newWorld()
  w.warMode = true
  w.auras[430191] = {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("unvalued lines trail", greenlines(w) == "+10% War Mode\nWarband Mentored")
end
do -- missing aura API degrades to no aura lines, no error
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  w.env.C_UnitAuras = nil
  clientLoaded(w)
  auraTick(w)
  check("no aura api degrades", tiphas(w, "No XP bonus"))
end
do -- mentored without a readable value shows no number
  local w = newWorld()
  w.auras[430191] = {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("mentored fallback", greenlines(w) == "Warband Mentored")
end
do -- out-of-range value is not trusted
  local w = newWorld()
  w.auras[430191] = { points = { 5000 } }
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("mentored range gate", greenlines(w) == "Warband Mentored")
end
do -- aura changes refresh the tooltip
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("unit_aura registered", w.frame.events.UNIT_AURA == true)
  w.now = w.now + 45
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  hover(w)
  check("no aura yet", tiphas(w, "No XP bonus"))
  check("partial seconds sub", tiptexts(w)[2] == "Warming up · last 45s of 10m")
  w.auras[46668] = {}
  w.native.shown = true -- simulated Edit Mode reshow
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "target")
  check("other unit ignored", w.native.shown == true)
  w.frame.scripts.OnEvent(w.frame, "UNIT_AURA", "player")
  check("player aura refreshes", w.native.shown == false)
  hover(w)
  check("player aura shows", greenlines(w) == "+10% WHEE!")
end

-- 16. Missing-buff feedback: gray lines name what each gap is worth.
do -- bare character sees every gap
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("missing full list", missinglines(w) == "+10% War Mode (toggle in a capital)\n"
    .. "+10% WHEE! (Faire week)\n"
    .. "+10% Wickerman (Hallow's End)\n"
    .. "Warband Mentored (needs a max-level character)\n"
    .. "Rested (rest in town)")
end
do -- partial stack shows only the gap
  local w = newWorld()
  w.warMode, w.restedXp = true, 400
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("missing gap only", missinglines(w) == "+10% WHEE! (Faire week)\n"
    .. "+10% Wickerman (Hallow's End)\n"
    .. "Warband Mentored (needs a max-level character)")
end
do -- full stack hides the section
  local w = newWorld()
  w.warMode, w.restedXp = true, 400
  w.auras[430191] = { points = { 20 } }
  w.auras[46668], w.auras[136583] = {}, {}
  w.auras[24705], w.auras[95987] = {}, {}
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("missing hidden when full", missinglines(w) == "")
end
do -- offered War Mode value follows Call to Arms
  local w = newWorld()
  w.warBonus = 15
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("missing live offer", missinglines(w):find(
    "+15% War Mode (toggle in a capital)", 1, true) ~= nil)
end
do -- one Wickerman aura covers the neutral line
  local w = newWorld()
  w.auras[24705] = {}
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("wickerman covered", not missinglines(w):find("Wickerman", 1, true))
end

-- Darkmoon buffs are either/or: one active covers the other.
do
  local w = newWorld()
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  local missed = missinglines(w)
  check("whee covers top hat", not missed:find("Top Hat", 1, true))
  check("whee not recommended", not missed:find("WHEE!", 1, true))
end
do
  local w = newWorld()
  w.auras[136583] = {}
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  local missed = missinglines(w)
  check("top hat covers whee", not missed:find("WHEE!", 1, true))
  check("top hat not recommended", not missed:find("Top Hat", 1, true))
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
  hover(w)
  check("live rate", tiptexts(w)[1] == "18k XP/hr · 3m")
end
do -- level-up keeps history and snapshots the new level atomically
  local w = newWorld()
  w.xp = 900
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 120
  w.xp, w.max, w.level = 100, 2000, 11
  xpEvent(w)
  hover(w)
  check("ding rate", tiptexts(w)[1] == "6k XP/hr · 19m")
end
do -- PLAYER_LEVEL_UP refreshes but never adds an award
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("level event registered", w.frame.events.PLAYER_LEVEL_UP == true)
  w.now = w.now + 60
  w.xp = 300
  xpEvent(w)
  hover(w)
  local line = tiptexts(w)[1]
  levelEvent(w)
  hover(w)
  check("level adds nothing", tiptexts(w)[1] == line)
end
do -- multi-level jump is unmeasurable: no invented gain
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.level, w.xp, w.max = 12, 50, 3000
  xpEvent(w)
  hover(w)
  check("jump silent", tiptexts(w)[1] == "0 XP/hr")
end
do -- negative same-level delta resyncs, never a negative award
  local w = newWorld()
  w.xp = 500
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.xp = 400
  xpEvent(w)
  hover(w)
  check("negative silent", tiptexts(w)[1] == "0 XP/hr")
  w.now = w.now + 60
  w.xp = 500
  xpEvent(w)
  hover(w)
  check("resync rate", tiptexts(w)[1] == "3k XP/hr · 10m")
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
  hover(w)
  check("zone keeps history", tiptexts(w)[1] == "12k XP/hr · 4m")
  w.guid = "Player-11-0002"
  w.now = w.now + 5
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  hover(w)
  check("switch clears", tiptexts(w)[1] == "Collecting data")
end

-- 21. ETA uses a longer-memory basis than the displayed rate.
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
  hover(w)
  check("burst rate spikes", tiptexts(w)[1] == "360k XP/hr · 7m")
  check("burst sub", tiptexts(w)[2] == "Last 10m")
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
  hover(w)
  check("stale eta stays null", tiptexts(w)[2] == "No XP in the last 10m")
  check("stale title zero", tiptexts(w)[1] == "0 XP/hr")
end

-- 22. Aura reads go blind in instances: verifiable lines stay, the
-- rest becomes an honest note instead of false absence.
do
  local w = newWorld()
  w.inInstance = true
  w.warMode, w.restedXp = true, 400
  w.auras[430191] = { points = { 20 } }
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("instance active lines", greenlines(w) == "+10% War Mode\nRested")
  check("instance missing note", missinglines(w) == "Aura scan unavailable in instances")
end
do
  local w = newWorld()
  w.inInstance = true
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("instance bare body", tiphas(w, "No XP bonus"))
  check("instance bare missing", missinglines(w) == "+10% War Mode (toggle in a capital)\n"
    .. "Rested (rest in town)\n"
    .. "Aura scan unavailable in instances")
end

-- 23. Idle status: a quiet minute in a full window admits staleness.
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
  hover(w)
  check("quiet 59s ready", tiptexts(w)[2] == "Last 10m")
  w.now = w.now + 1
  w.tickers[1].fn()
  hover(w)
  check("quiet 60s idle", tiptexts(w)[2] == "Idle 1m · last 10m")
  check("idle keeps payoff", tiptexts(w)[1] == "360k XP/hr · 7m")
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
  hover(w)
  check("warming owns partial idle", tiptexts(w)[2] == "Warming up · last 3m of 10m")
  check("partial idle payoff", tiptexts(w)[1] == "100k XP/hr · 57m")
end

-- 24. Mode transitions: dinging pivots to rep, dormancy stays
-- available, and tickers never stack.
local dormantEvents = { "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UNIT_AURA",
  "PLAYER_EQUIPMENT_CHANGED", "UPDATE_EXHAUSTION", "PLAYER_UPDATE_RESTING",
  "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_COMPLETE",
  "UPDATE_FACTION", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" }
do -- repMode off at cap: fully dormant, native bar back
  local w = newWorld()
  capWorld(w)
  w.savedVars = { repMode = false }
  loadAddon(w)
  clientLoaded(w)
  check("dormant starts tickerless", #w.tickers == 0)
  for _, e in ipairs(dormantEvents) do
    check("dormant unregisters " .. e, w.frame.events[e] == nil)
  end
  check("dormant keeps pew wake", w.frame.events.PLAYER_ENTERING_WORLD == true)
  check("dormant keeps cap wake", w.frame.events.PLAYER_MAX_LEVEL_UPDATE == true)
end
do -- ding to cap mid-session pivots to rep, ticker kept
  local w = newWorld()
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  capWorld(w)
  xpEvent(w)
  check("ding stays shown", w.frame.shown == true)
  check("ding keeps ticker", w.tickers[1].cancelled ~= true)
  check("ding unregisters xp", w.frame.events.PLAYER_XP_UPDATE == nil)
  check("ding registers rep", w.frame.events.UPDATE_FACTION == true)
  check("ding keeps aura", w.frame.events.UNIT_AURA == true)
  check("ding hides native", w.native.shown == false)
  check("ding announces rep", w.printed[#w.printed] ==
    "|cff66ccffVocXP|r: tracking reputation at max level (/vxp config to turn it off)")
  check("ding paints rep", w.label.text == "Court  3k/9k (33%)")
end
do -- ding with repMode off shuts down as before
  local w = newWorld()
  w.savedVars = { repMode = false }
  loadAddon(w)
  clientLoaded(w)
  capWorld(w)
  xpEvent(w)
  check("off ding hides", w.frame.shown == false)
  check("off ding cancels ticker", w.tickers[1].cancelled == true)
  check("off ding unregisters xp", w.frame.events.PLAYER_XP_UPDATE == nil)
  check("off ding unregisters rep", w.frame.events.UPDATE_FACTION == nil)
  check("off ding restores native", w.native.shown == true)
end
do -- cap raise without relog wakes XP through the cap event
  local w = newWorld()
  capWorld(w)
  loadAddon(w)
  clientLoaded(w)
  w.level, w.max = 10, 50000
  maxLevelEvent(w)
  check("cap event repaints", w.label.text == "10  0/50k (0%)")
  check("cap event swaps events", w.frame.events.PLAYER_XP_UPDATE == true
    and w.frame.events.UPDATE_FACTION == nil)
  hover(w)
  check("cap event collects", tiptexts(w)[1] == "Collecting data")
end
do -- re-login after a ding keeps the one ticker
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  capWorld(w)
  xpEvent(w)
  w.level, w.max = 10, 50000
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("rewake keeps ticker", #w.tickers == 1 and w.tickers[1].cancelled ~= true)
  check("rewake reregisters", w.frame.events.PLAYER_XP_UPDATE == true
    and w.frame.events.UNIT_AURA == true and w.frame.events.PLAYER_LEVEL_UP == true
    and w.frame.events.PLAYER_EQUIPMENT_CHANGED == true
    and w.frame.events.UPDATE_EXHAUSTION == true
    and w.frame.events.QUEST_LOG_UPDATE == true)
  check("rewake unregisters rep", w.frame.events.UPDATE_FACTION == nil)
  check("rewake reshows", w.frame.shown == true)
  hover(w)
  check("rewake collects", tiptexts(w)[1] == "Collecting data")
end
do -- repMode off: re-login after a ding restarts exactly one ticker
  local w = newWorld()
  w.savedVars = { repMode = false }
  loadAddon(w)
  clientLoaded(w)
  capWorld(w)
  xpEvent(w)
  w.level, w.max = 10, 50000
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("off rewake restarts ticker", #w.tickers == 2 and w.tickers[1].cancelled == true
    and w.tickers[2].cancelled ~= true)
  check("off rewake reshows", w.frame.shown == true)
end
do -- repeated logins never stack tickers
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("no double ticker", #w.tickers == 1)
end
do -- repeated rep logins never stack tickers either
  local w = newWorld()
  capWorld(w)
  loadAddon(w)
  clientLoaded(w)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("rep no double ticker", #w.tickers == 1)
end

-- 25. Slash grammar (FAMILY.md): help lists every subcommand, an
-- unknown subcommand prints help and never toggles, config opens the
-- panel or says where it lives.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  local before = #w.printed
  slash("help")
  check("/vxp help lists every command", #w.printed == before + 1 + #ns.HELP)
  check("help names config and help last",
    ns.HELP[#ns.HELP - 1]:find("^/vxp config") ~= nil and ns.HELP[#ns.HELP]:find("^/vxp help") ~= nil
    and ns.HELP[#ns.HELP]:find("/vocxp works too", 1, true) ~= nil)
  check("help leads with the bar", ns.HELP[1]:find("show or hide the bar", 1, true) ~= nil)
  before = #w.printed
  slash("lokc") -- typo: help, never an action
  check("unknown subcommand prints help", #w.printed == before + 1 + #ns.HELP)
  check("unknown subcommand never toggles", w.frame.shown == true and ns.db.locked == false)
  slash("config")
  check("/vxp config prints the path without Settings",
    w.printed[#w.printed] == "|cff66ccffVocXP|r: open Settings > AddOns > VocXP")
end

-- 26. Native Settings panel: every option, bound to the live table,
-- applied the moment it changes.
do
  local w = newWorld()
  w.withSettings = true
  local ns = loadAddon(w)
  w.env.VocXPDB = {}
  w.frame.scripts.OnEvent(w.frame, "ADDON_LOADED", "VocXP")
  check("settings built at ADDON_LOADED", ns.settingsBuilt == true)
  check("category registered", w.settingsCat == "VocXP" and w.settingsCatRegistered)
  local keys = {}
  for _, r in ipairs(w.settingsReg) do keys[r.key] = r end
  check("five options registered", keys.shown ~= nil and keys.hideDefault ~= nil
    and keys.repMode ~= nil and keys.followLatest ~= nil and keys.locked ~= nil and #w.settingsReg == 5)
  check("bound to the live table", keys.shown.tbl == ns.db and keys.locked.tbl == w.env.VocXPDB
    and keys.hideDefault.tbl == w.env.VocXPDB)
  check("five checkboxes", w.settingsChecks == 5)
  check("defaults match", keys.shown.default == true and keys.hideDefault.default == true
    and keys.locked.default == false and keys.repMode.default == true and keys.followLatest.default == false)
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("built once", #w.settingsReg == 5)
  ns.db.shown = false
  w.settingCallbacks["VocXP_shown"]()
  check("shown applies live", w.frame.shown == false)
  ns.db.shown = true
  ns.db.hideDefault = false
  w.settingCallbacks["VocXP_hideDefault"]()
  check("hideDefault applies live", w.native.shown == true)
  ns.db.locked = true
  w.settingCallbacks["VocXP_locked"]()
  w.frame.scripts.OnDragStart(w.frame)
  check("locked applies live", w.frame.moving ~= true)
  w.env.SlashCmdList.VOCXP("config")
  check("/vxp config opens the category", w.openedCategory == 42)
end

do -- repMode applies live: dormant and rep swap without reload
  local w = newWorld()
  w.withSettings = true
  capWorld(w)
  w.savedVars = { repMode = false }
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  local ns = loadAddon(w)
  w.env.VocXPDB = w.savedVars
  w.frame.scripts.OnEvent(w.frame, "ADDON_LOADED", "VocXP")
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  check("dormant before toggle", w.frame.shown == false and #w.tickers == 0)
  ns.db.repMode = true
  w.settingCallbacks["VocXP_repMode"]()
  check("repMode on wakes rep", w.frame.shown == true and #w.tickers == 1
    and w.label.text == "Court  3k/9k (33%)")
  ns.db.repMode = false
  w.settingCallbacks["VocXP_repMode"]()
  check("repMode off restores dormant", w.frame.shown == false and w.native.shown == true
    and w.tickers[1].cancelled == true)
end

-- 27. Addon compartment: click does what the bare slash does; hover
-- follows the tooltip contract (gold title, one line, the slash hint).
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("compartment globals", type(w.env.VocXP_CompartmentClick) == "function"
    and type(w.env.VocXP_CompartmentEnter) == "function"
    and type(w.env.VocXP_CompartmentLeave) == "function")
  w.env.VocXP_CompartmentClick("VocXP", "LeftButton")
  check("compartment click hides", w.frame.shown == false and w.sounds[#w.sounds] == 851)
  w.env.VocXP_CompartmentClick("VocXP", "LeftButton")
  check("compartment click shows", w.frame.shown == true and w.sounds[#w.sounds] == 850)
  local btn = {}
  w.env.VocXP_CompartmentEnter("VocXP", btn)
  check("compartment tooltip anchors to the button", w.gametip.owner == btn and w.gametip.shown == true)
  check("compartment tooltip title is gold", w.gametip.title == "VocXP"
    and w.gametip.titleColor[1] == 1 and w.gametip.titleColor[2] == 0.82 and w.gametip.titleColor[3] == 0)
  check("compartment tooltip names the bar", w.gametip.lines[1].text:find("XP bar", 1, true) ~= nil)
  check("compartment tooltip teaches the slash", #w.gametip.lines == 2
    and w.gametip.lines[2].text:find("/vxp", 1, true) ~= nil)
  w.env.VocXP_CompartmentLeave("VocXP", btn)
  check("compartment leave hides the tooltip", w.gametip.shown == false)
end

-- 28. Corrupt SavedVariables reset to defaults instead of misbehaving.
do
  local w = newWorld()
  w.savedVars = { shown = "yes", locked = 1, hideDefault = "no", repMode = "yes", followLatest = "yes", point = 5, x = "far", y = 200 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("wrong-typed keys reset", ns.db.shown == true and ns.db.locked == false and ns.db.repMode == true and ns.db.followLatest == false
    and ns.db.hideDefault == true and ns.db.point == "BOTTOM" and ns.db.x == 0 and ns.db.y == 200)
end

-- 29. Client flavor: Forever recommends only what exists there.
-- Detection reads our own loaded toc's Interface version (see
-- ns.clientFlavor): 1.x is our Forever toc, 12.x our retail toc.
do -- retail stays the default, querying our own addon entry
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  check("retail flavor", ns.clientFlavor() == "retail")
  check("flavor queries own addon", w.queriedAddon == "VocXP")
end
do -- Forever: Rested is the only recommendation
  local w = newWorld()
  w.addonInterfaceVersion = 16001
  local ns = loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("forever missing rested only", missinglines(w) == "Rested (rest in town)")
  check("forever flavor", ns.clientFlavor() == "forever")
end
do -- Forever plus Rested: nothing missing, the section hides
  local w = newWorld()
  w.addonInterfaceVersion = 16001
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("forever rested hides missing", missinglines(w) == "")
end
do -- Forever: a lit War Mode flag still shows -- detection is ungated,
   -- only recommendations gate on flavor
  local w = newWorld()
  w.addonInterfaceVersion = 16001
  w.warMode = true
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("forever war mode active", greenlines(w) == "+10% War Mode")
  check("forever war mode unrecommended", missinglines(w) == "Rested (rest in town)")
end
do -- Forever: a present aura still shows
  local w = newWorld()
  w.addonInterfaceVersion = 16001
  w.auras[46668] = {}
  loadAddon(w)
  clientLoaded(w)
  auraTick(w)
  check("forever whee active", greenlines(w) == "+10% WHEE!")
  check("forever whee unrecommended", not missinglines(w):find("WHEE!", 1, true))
end
do -- Forever in an instance: no scan note, no aura recs to explain
  local w = newWorld()
  w.addonInterfaceVersion = 16001
  w.inInstance = true
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("forever instance quiet", missinglines(w) == "Rested (rest in town)")
end
do -- missing version API falls back to retail, never errors
  local w = newWorld()
  loadAddon(w)
  w.env.C_AddOns = {}
  clientLoaded(w)
  hover(w)
  check("flavor fallback full list", missinglines(w) == "+10% War Mode (toggle in a capital)\n"
    .. "+10% WHEE! (Faire week)\n"
    .. "+10% Wickerman (Hallow's End)\n"
    .. "Warband Mentored (needs a max-level character)\n"
    .. "Rested (rest in town)")
end
do -- no C_AddOns at all: same retail fallback, silent
  local w = newWorld()
  loadAddon(w)
  w.env.C_AddOns = nil
  clientLoaded(w)
  hover(w)
  check("flavor nil fallback", w.ns.clientFlavor() == "retail")
  check("flavor nil full list", missinglines(w):find("War Mode", 1, true) ~= nil)
end

-- 30. Regalia of Fabled Adventurers: heirloom count slows Rested use.
-- The set cuts Rested consumption 30% at 2 pieces and another 30% at 6;
-- the Rested line carries the live reduction, and the missing section
-- teaches the next threshold.
do -- Rested + 2 heirlooms annotates the Rested line
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  wear(w, "HeadSlot", "ChestSlot")
  auraTick(w)
  check("regalia 2pc annotates rested",
    greenlines(w) == "Rested · -30% use (Regalia 2pc)")
  check("regalia 2pc missing teaches 6pc",
    missinglines(w):find("-60% Rested use (Regalia 6pc, 2/6 worn)", 1, true) ~= nil)
end
do -- 6 pieces: the full -60%, nothing left to teach
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  wear(w, "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "LegsSlot")
  auraTick(w)
  check("regalia 6pc annotates rested",
    greenlines(w) == "Rested · -60% use (Regalia 6pc)")
  check("regalia 6pc missing quiet", not missinglines(w):find("Regalia", 1, true))
end
do -- one heirloom: plain Rested, the 2pc taught below
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  wear(w, "HeadSlot")
  auraTick(w)
  check("regalia 1pc rested plain", greenlines(w) == "Rested")
  check("regalia 1pc missing teaches 2pc",
    missinglines(w):find("-30% Rested use (Regalia 2pc, one more heirloom)", 1, true) ~= nil)
end
do -- unrested with the set banked: Rested stays the ask, Regalia the next step
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  wear(w, "HeadSlot", "ChestSlot")
  auraTick(w)
  check("regalia unrested no green line", tiphas(w, "No XP bonus"))
  check("regalia unrested missing",
    missinglines(w):find("Rested (rest in town)", 1, true) ~= nil
    and missinglines(w):find("-60% Rested use (Regalia 6pc, 2/6 worn)", 1, true) ~= nil)
end
do -- non-heirloom gear never counts
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  wear(w, "HeadSlot")
  w.equipped[w.slotIDs.ChestSlot] = 4 -- epic, not an heirloom
  auraTick(w)
  check("regalia ignores epics", greenlines(w) == "Rested")
  check("regalia epics still 1pc",
    missinglines(w):find("-30% Rested use (Regalia 2pc, one more heirloom)", 1, true) ~= nil)
end
do -- thresholds: 0-1 nothing, 2-5 the first cut, 6+ the full cut
  local w = newWorld()
  local ns = loadAddon(w)
  local r0 = ns.regaliaReduction(0)
  local r1 = ns.regaliaReduction(1)
  local r2, t2 = ns.regaliaReduction(2)
  local r5, t5 = ns.regaliaReduction(5)
  local r6, t6 = ns.regaliaReduction(6)
  local r8, t8 = ns.regaliaReduction(8)
  check("regalia thresholds", r0 == 0 and r1 == 0 and r2 == 30 and r5 == 30
    and r6 == 60 and r8 == 60 and t2 == "2pc" and t5 == "2pc" and t6 == "6pc" and t8 == "6pc")
end
do -- exactly the eight counting slots are scanned, never weapons or trinkets
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  local seen = {}
  for _, slotName in ipairs(w.slotQueries) do seen[slotName] = true end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  check("regalia scans eight slots", n == 8
    and seen.HeadSlot and seen.NeckSlot and seen.ShoulderSlot and seen.BackSlot
    and seen.ChestSlot and seen.LegsSlot and seen.Finger0Slot and seen.Finger1Slot)
end
do -- missing equipment API degrades to a plain Rested line, never an error
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  wear(w, "HeadSlot", "ChestSlot")
  w.env.C_PaperDollInfo = nil
  clientLoaded(w)
  auraTick(w)
  check("regalia no slot api degrades", greenlines(w) == "Rested")
  check("regalia no slot api missing quiet", not missinglines(w):find("Regalia", 1, true))
end
do
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  wear(w, "HeadSlot", "ChestSlot")
  w.env.GetInventoryItemQuality = nil
  clientLoaded(w)
  auraTick(w)
  check("regalia no quality api degrades", greenlines(w) == "Rested")
end
do -- Forever: heirlooms predate the set, so the count means nothing there
  local w = newWorld()
  w.addonInterfaceVersion = 16001
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  wear(w, "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "LegsSlot")
  auraTick(w)
  check("regalia forever rested plain", greenlines(w) == "Rested")
  check("regalia forever missing quiet", missinglines(w) == "")
end
do -- gear swaps re-render at once through PLAYER_EQUIPMENT_CHANGED
  local w = newWorld()
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  check("equipment event registered", w.frame.events.PLAYER_EQUIPMENT_CHANGED == true)
  wear(w, "HeadSlot")
  w.frame.scripts.OnEvent(w.frame, "PLAYER_EQUIPMENT_CHANGED", w.slotIDs.HeadSlot, false)
  hover(w)
  check("one heirloom plain", greenlines(w) == "Rested")
  wear(w, "HeadSlot", "ChestSlot")
  w.frame.scripts.OnEvent(w.frame, "PLAYER_EQUIPMENT_CHANGED", w.slotIDs.ChestSlot, false)
  hover(w)
  check("second heirloom annotates",
    greenlines(w) == "Rested · -30% use (Regalia 2pc)")
end
do -- instances keep the equipment-derived lines: the paper doll reads fine there
  local w = newWorld()
  w.inInstance = true
  w.restedXp = 400
  loadAddon(w)
  clientLoaded(w)
  wear(w, "HeadSlot", "ChestSlot")
  auraTick(w)
  check("regalia instance active",
    greenlines(w) == "Rested · -30% use (Regalia 2pc)")
  check("regalia instance missing", missinglines(w) == "+10% War Mode (toggle in a capital)\n"
    .. "-60% Rested use (Regalia 6pc, 2/6 worn)\n"
    .. "Aura scan unavailable in instances")
end

-- 35. Rep math: progress per kind, gains, labels, art.
do -- standard progress: in-rank numbers and labels
  local w = newWorld()
  local ns = loadAddon(w)
  local fd = { factionID = 101, name = "Court", reaction = 6,
    currentReactionThreshold = 12000, nextReactionThreshold = 21000,
    currentStanding = 15000, hasBonusRepGain = true }
  local p = ns.repStandardProgress(fd)
  check("standing progress", p.have == 3000 and p.need == 9000 and p.level == 6)
  check("standing labels", p.levelLabel == "Honored" and p.kind == "standing" and p.capped == false)
  check("standing bonus", p.bonus == true)
end
do -- standard cap: Exalted reads full with the cap label
  local w = newWorld()
  local ns = loadAddon(w)
  local p = ns.repStandardProgress({ factionID = 101, name = "Court", reaction = 8,
    currentReactionThreshold = 42000, nextReactionThreshold = 43000, currentStanding = 42999 })
  check("exalted capped", p.capped == true and p.capLabel == "Exalted" and p.have == 1 and p.need == 1)
end
do -- standard rejects bad rows and bad thresholds
  local w = newWorld()
  local ns = loadAddon(w)
  check("standing nil row", ns.repStandardProgress(nil) == nil)
  check("standing header rejected", ns.repStandardProgress(
    { factionID = 1, name = "H", isHeader = true }) == nil)
  check("standing header with rep kept", ns.repStandardProgress(
    { factionID = 1, name = "H", isHeader = true, isHeaderWithRep = true,
      reaction = 5, currentReactionThreshold = 0, nextReactionThreshold = 3000,
      currentStanding = 100 }) ~= nil)
  check("standing zero id rejected", ns.repStandardProgress({ factionID = 0, name = "X" }) == nil)
  check("standing flat thresholds rejected", ns.repStandardProgress(
    { factionID = 101, name = "C", reaction = 5,
      currentReactionThreshold = 3000, nextReactionThreshold = 3000, currentStanding = 3000 }) == nil)
end
do -- renown progress reads the in-level standing raw
  local w = newWorld()
  local ns = loadAddon(w)
  local fd = { factionID = 301, name = "Amani", reaction = 5,
    currentReactionThreshold = 0, nextReactionThreshold = 2500, currentStanding = 1200 }
  local p = ns.repRenownProgress(fd, { renownLevel = 7, renownLevelThreshold = 3000 }, false)
  check("renown progress", p.have == 1200 and p.need == 3000 and p.level == 7)
  check("renown label", p.levelLabel == "Renown 7" and p.kind == "renown")
  check("renown clamps overflow", ns.repRenownProgress(
    { factionID = 301, name = "A", currentStanding = 99999 },
    { renownLevel = 7, renownLevelThreshold = 3000 }, false).have == 3000)
  local maxed = ns.repRenownProgress(fd, { renownLevel = 25, renownLevelThreshold = 3000 }, true)
  check("renown maxed", maxed.capped == true and maxed.capLabel == "Renown 25")
  check("renown bad major", ns.repRenownProgress(fd, nil, false) == nil
    and ns.repRenownProgress(fd, { renownLevel = 7 }, false) == nil)
end
do -- paragon cycles modulo the threshold, pending pins full
  local w = newWorld()
  local ns = loadAddon(w)
  local fd = { factionID = 401, name = "Para", reaction = 8,
    currentReactionThreshold = 42000, nextReactionThreshold = 43000, currentStanding = 42999 }
  local p = ns.repParagonProgress(fd, 12300, 10000, false)
  check("paragon cycle", p.have == 2300 and p.need == 10000 and p.raw == 12300)
  check("paragon never capped", p.capped == false and p.pending == false)
  local pend = ns.repParagonProgress(fd, 12300, 10000, true)
  check("paragon pending full", pend.have == 10000 and pend.pending == true)
  check("paragon bad values", ns.repParagonProgress(fd, nil, 10000, false) == nil
    and ns.repParagonProgress(fd, 100, 0, false) == nil)
end
do -- friendship ranks, max rank full
  local w = newWorld()
  local ns = loadAddon(w)
  local fd = { factionID = 501, name = "Valeera", reaction = 5,
    currentReactionThreshold = 0, nextReactionThreshold = 0, currentStanding = 0 }
  local p = ns.repFriendshipProgress(fd,
    { friendshipFactionID = 9001, standing = 2500, reaction = "Good Friend",
      reactionThreshold = 2000, nextThreshold = 4000 },
    { currentLevel = 3, maxLevel = 6 })
  check("friendship progress", p.have == 500 and p.need == 2000 and p.level == 3)
  check("friendship label", p.levelLabel == "Good Friend" and p.kind == "friendship")
  local maxed = ns.repFriendshipProgress(fd,
    { friendshipFactionID = 9001, standing = 8000, reaction = "Best Friend",
      reactionThreshold = 6000, nextThreshold = nil },
    { currentLevel = 6, maxLevel = 6 })
  check("friendship maxed", maxed.capped == true and maxed.capLabel == "Best Friend")
end
do -- rep gains mirror the XP rules per faction
  local w = newWorld()
  local ns = loadAddon(w)
  local base = { id = 101, kind = "standing", have = 100, need = 1000, level = 6, capped = false }
  check("repGain nil baseline", ns.repGain(nil, base) == nil)
  check("repGain same rank", ns.repGain(base,
    { id = 101, kind = "standing", have = 300, need = 1000, level = 6, capped = false }) == 200)
  check("repGain loss resyncs", ns.repGain(base,
    { id = 101, kind = "standing", have = 50, need = 1000, level = 6, capped = false }) == nil)
  check("repGain rank-up carries", ns.repGain(
    { id = 101, kind = "standing", have = 900, need = 1000, level = 6, capped = false },
    { id = 101, kind = "standing", have = 100, need = 3000, level = 7, capped = false }) == 200)
  check("repGain multi-rank nil", ns.repGain(base,
    { id = 101, kind = "standing", have = 100, need = 3000, level = 8, capped = false }) == nil)
  check("repGain faction swap nil", ns.repGain(base,
    { id = 202, kind = "standing", have = 300, need = 1000, level = 6, capped = false }) == nil)
  check("repGain into cap nil", ns.repGain(base,
    { id = 101, kind = "standing", have = 1, need = 1, level = 8, capped = true }) == nil)
  check("repGain paragon delta", ns.repGain(
    { id = 401, kind = "paragon", raw = 100, capped = false },
    { id = 401, kind = "paragon", raw = 250, capped = false }) == 150)
  check("repGain paragon loss nil", ns.repGain(
    { id = 401, kind = "paragon", raw = 250, capped = false },
    { id = 401, kind = "paragon", raw = 100, capped = false }) == nil)
end
do -- bar labels and stats lines per kind
  local w = newWorld()
  local ns = loadAddon(w)
  check("rep label untracked", ns.repBarLabel(nil) == "No faction tracked")
  check("rep label capped", ns.repBarLabel({ name = "Court", capped = true }) == "Court")
  check("rep label progress", ns.repBarLabel(
    { name = "Court", capped = false, have = 3000, need = 9000 }) == "Court  3k/9k (33%)")
  check("rep stats standing", ns.repStatsLine(
    { kind = "standing", capped = false, have = 3000, need = 9000, level = 6,
      levelLabel = "Honored" }) == "Honored · 33% to Revered")
  check("rep stats renown", ns.repStatsLine(
    { kind = "renown", capped = false, have = 1200, need = 3000, level = 7,
      levelLabel = "Renown 7" }) == "Renown 7 · 40% to 8")
  check("rep stats paragon", ns.repStatsLine(
    { kind = "paragon", capped = false, have = 2300, need = 10000 }) == "Paragon · 23% to reward")
  check("rep stats friendship", ns.repStatsLine(
    { kind = "friendship", capped = false, have = 500, need = 2000,
      levelLabel = "Good Friend" }) == "Good Friend · 25% to next rank")
  check("rep stats capped hides", ns.repStatsLine({ kind = "standing", capped = true }) == nil)
  check("rep stats unknown hides", ns.repStatsLine(
    { kind = "mystery", capped = false, have = 1, need = 2 }) == nil)
end
do -- fill art follows the native rows
  local w = newWorld()
  local ns = loadAddon(w)
  local function fill(p) local a = ns.repAtlas(p) return a end
  check("rep atlas hated red", fill({ kind = "standing", level = 1 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Red")
  check("rep atlas hostile red", fill({ kind = "standing", level = 2 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Red")
  check("rep atlas unfriendly orange", fill({ kind = "standing", level = 3 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Orange")
  check("rep atlas neutral yellow", fill({ kind = "standing", level = 4 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Yellow")
  check("rep atlas honored green", fill({ kind = "standing", level = 6 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
  check("rep atlas renown blue", fill({ kind = "renown", level = 7 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Blue")
  check("rep atlas major paragon blue", fill({ kind = "paragon", blue = true }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Blue")
  check("rep atlas plain paragon green", fill({ kind = "paragon" }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
  check("rep atlas friendship green", fill({ kind = "friendship", level = 3 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
  check("rep atlas wild reads friendly", fill({ kind = "standing", level = 99 }) ==
    "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
  local _, flare, levelup = ns.repAtlas({ kind = "standing", level = 6 })
  check("rep atlas flare pair", flare == "UI-HUD-ExperienceBar-Flare-Reputation-2x-Flipbook"
    and levelup == "UI-HUD-ExperienceBar-Fill-Reputation-2x-Flipbook")
end
do -- standing names and the reaction ceiling
  local w = newWorld()
  local ns = loadAddon(w)
  check("standing names", ns.standingName(1) == "Hated" and ns.standingName(8) == "Exalted")
  check("standing wild", ns.standingName(99) == "Rank 99")
  check("max reaction reads global", ns.maxRepReaction() == 8)
  w.env.MAX_REPUTATION_REACTION = nil
  check("max reaction falls back", ns.maxRepReaction() == 8)
end

-- 36. Tracked-faction resolution: watched wins, then the latest
-- gainer, then the persisted ID, then the untracked state.
do -- watched wins over gains elsewhere
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.watchedID = 101
  local ns = loadAddon(w)
  clientLoaded(w)
  check("watched tracked", ns.repTracked() == 101 and ns.repFollowingWatched() == true)
  w.factions[2].standing = 9000 -- gains elsewhere don't steal a watched bar
  repEvent(w)
  check("watched sticks", ns.repTracked() == 101 and w.label.text == "Court  3k/9k (33%)")
end
do -- unwatched follows the latest gainer
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.savedVars = { repFaction = 101 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("persisted restores", ns.repTracked() == 101 and ns.repFollowingWatched() == false)
  w.factions[2].standing = 9000
  repEvent(w)
  check("follow switches", ns.repTracked() == 202)
  check("follow repaints", w.label.text == "Wardens  3k/6k (50%)")
  check("follow persists", ns.db.repFaction == 202)
end
do -- watching mid-session takes the bar on the next tick
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.savedVars = { repFaction = 202 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("unwatched persists", ns.repTracked() == 202)
  w.watchedID = 101 -- no event fires: the ticker notices
  w.tickers[1].fn()
  check("watch takes over", ns.repTracked() == 101 and ns.repFollowingWatched() == true)
  check("watch repaints", w.label.text == "Court  3k/9k (33%)")
end
do -- unwatching falls back to the latest gainer
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.watchedID = 101
  local ns = loadAddon(w)
  clientLoaded(w)
  w.factions[2].standing = 9000
  repEvent(w)
  check("gains noted under watched", ns.repTracked() == 101)
  w.watchedID = nil
  w.tickers[1].fn()
  check("unwatch falls back", ns.repTracked() == 202 and ns.repFollowingWatched() == false)
end
do -- losses never steal tracking, and later gains still count
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
  })
  w.watchedID = 101
  local ns = loadAddon(w)
  clientLoaded(w)
  w.factions[1].standing = 14000
  repEvent(w)
  check("loss keeps tracking", ns.repTracked() == 101)
  check("loss resyncs baseline", ns.repBaselineRead().have == 2000)
  w.now = w.now + 100
  w.factions[1].standing = 15000
  repEvent(w)
  hover(w)
  check("gains after loss count", tiptexts(w)[1] == "36k Rep/hr · 10m")
end
do -- one event with gains on two rows follows the largest
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.savedVars = { repFaction = 101 }
  local ns = loadAddon(w)
  clientLoaded(w)
  w.factions[1].standing = 15100
  w.factions[2].standing = 8500
  repEvent(w)
  check("largest gain wins", ns.repTracked() == 202)
end
do -- missing reputation API degrades to untracked, never an error
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  local ns = loadAddon(w)
  w.env.C_Reputation = nil
  clientLoaded(w)
  check("no rep namespace untracked", ns.repTracked() == nil and w.label.text == "No faction tracked")
  check("no rep namespace shown", w.frame.shown == true)
end
do -- missing renown API leaves a major faction unreadable, not misread
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 301, name = "Amani", reaction = 5, lo = 0, hi = 3000, standing = 1200 } })
  w.watchedID = 301
  w.isMajor[301] = true
  w.major[301] = { level = 7, threshold = 3000, hasMax = false }
  local ns = loadAddon(w)
  w.env.C_MajorFactions = nil
  clientLoaded(w)
  check("no renown api untracked", ns.repTracked() == nil)
end
do -- unreadable rows never track
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 1, name = "H", header = true } })
  w.watchedID = 999
  local ns = loadAddon(w)
  clientLoaded(w)
  check("dead rows untracked", ns.repTracked() == nil and w.label.text == "No faction tracked")
end

-- 37. Renown, Paragon, and friendship render through the same bar.
do -- renown: blue fill, renown stats
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 301, name = "Amani", reaction = 5, lo = 0, hi = 3000, standing = 1200 } })
  w.watchedID = 301
  w.isMajor[301] = true
  w.major[301] = { level = 7, threshold = 3000, hasMax = false }
  loadAddon(w)
  clientLoaded(w)
  check("renown label", w.label.text == "Amani  1k/3k (40%)")
  check("renown fill blue", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Blue")
  check("renown stats", w.sub.text == "Renown 7 · 40% to 8")
  check("renown animated", w.bar.animated[1] == 1200 and w.bar.animated[2] == 0
    and w.bar.animated[3] == 3000 and w.bar.animated[4] == 7)
end
do -- maxed renown: name-only label, cap title
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 301, name = "Amani", reaction = 5, lo = 0, hi = 3000, standing = 3000 } })
  w.watchedID = 301
  w.isMajor[301] = true
  w.major[301] = { level = 25, threshold = 3000, hasMax = true }
  loadAddon(w)
  clientLoaded(w)
  check("renown maxed label", w.label.text == "Amani")
  check("renown maxed rate", w.rate.text == "Renown 25")
  hover(w)
  check("renown maxed tooltip", tiptexts(w)[1] == "Renown 25" and tiptexts(w)[2] == "Rank complete")
  check("renown maxed hides stats", w.sub.shown == false)
end
do -- paragon: green cycle bar, reward line when pending
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 401, name = "Para", reaction = 8, lo = 42000, hi = 43000, standing = 42999 } })
  w.watchedID = 401
  w.paragon[401] = { current = 12300, threshold = 10000 }
  loadAddon(w)
  clientLoaded(w)
  check("paragon label", w.label.text == "Para  2k/10k (23%)")
  check("paragon fill green", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
  check("paragon stats", w.sub.text == "Paragon · 23% to reward")
  hover(w)
  check("paragon no pending line", not tiphas(w, "Paragon reward pending"))
  w.paragon[401].pending = true
  repEvent(w)
  check("paragon pending full", w.bar.value == 10000)
  hover(w)
  check("paragon pending line", tiphas(w, "Paragon reward pending"))
end
do -- major-faction paragon goes blue
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 401, name = "Para", reaction = 8, lo = 42000, hi = 43000, standing = 42999 } })
  w.watchedID = 401
  w.paragon[401] = { current = 12300, threshold = 10000 }
  w.isMajor[401] = true
  loadAddon(w)
  clientLoaded(w)
  check("major paragon blue", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Blue")
end
do -- friendship: forced green, rank words
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 501, name = "Valeera", reaction = 5, lo = 0, hi = 0, standing = 0 } })
  w.watchedID = 501
  w.friendship[501] = { fid = 9001, standing = 2500, reaction = "Good Friend",
    lo = 2000, next = 4000, curLevel = 3, maxLevel = 6 }
  loadAddon(w)
  clientLoaded(w)
  check("friendship label", w.label.text == "Valeera  500/2k (25%)")
  check("friendship fill green", w.bar.barAtlas == "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
  check("friendship stats", w.sub.text == "Good Friend · 25% to next rank")
  check("friendship animated level", w.bar.animated[4] == 3)
  hover(w)
  check("friendship tooltip", tiphas(w, "Valeera: Good Friend · 25% to next rank"))
end
do -- maxed friendship: name-only label, rank title
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 501, name = "Valeera", reaction = 5, lo = 0, hi = 0, standing = 0 } })
  w.watchedID = 501
  w.friendship[501] = { fid = 9001, standing = 8000, reaction = "Best Friend",
    lo = 6000, next = nil, curLevel = 6, maxLevel = 6 }
  loadAddon(w)
  clientLoaded(w)
  check("friendship maxed label", w.label.text == "Valeera")
  check("friendship maxed rate", w.rate.text == "Best Friend")
end
do -- exalted standard: name-only label, cap title
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 8, lo = 42000, hi = 43000, standing = 42999 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  check("exalted label", w.label.text == "Court")
  check("exalted rate", w.rate.text == "Exalted")
  check("exalted hides stats", w.sub.shown == false)
  hover(w)
  check("exalted tooltip", tiptexts(w)[1] == "Exalted" and tiptexts(w)[2] == "Rank complete"
    and tiphas(w, "Court — Exalted"))
end
do -- rep paints through the plain-bar fallback too
  local w = newWorld()
  w.failTemplate = true
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  check("rep fallback paints", w.bar.value == 3000 and w.bar.minmax[2] == 9000)
  check("rep fallback fill atlas", w.bar.fillTex.atlas == "UI-HUD-ExperienceBar-Fill-Reputation-Faction-Green")
end

-- 38. Rep/hr flows like XP/hr; the tooltip teaches the faction.
do -- gains accumulate into the session rate
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 5, lo = 6000, hi = 15000, standing = 6000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 1800
  w.factions[1].standing = 6500
  repEvent(w)
  hover(w)
  check("rep rate line", tiptexts(w)[1] == "3k Rep/hr · 4h15m")
  check("rep rate sub", tiptexts(w)[2] == "Last 10m")
  check("rep faction line", tiptexts(w)[3] == "Court: Friendly · 6% to Honored")
  check("rep follow line", tiphas(w, "Following watched faction"))
end
do -- full tooltip order in rep mode; XP-only buffs stay out
  local w = newWorld()
  capWorld(w)
  w.warMode, w.restedXp = true, 500
  w.auras[46668] = {}
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("rep tooltip order", table.concat(tiptexts(w), "|") == table.concat({
    "Collecting data",
    "Collecting data",
    "Court: Honored · 33% to Revered",
    "+10% WHEE!",
    "+10% Wickerman (Hallow's End)",
    "+10% Spirit of Sharing (Pilgrim's Bounty)",
    "Following watched faction",
    "/vxp shows or hides it. /vxp help lists the rest.",
  }, "|"))
  check("rep bonus green", sameColor(tipcolor(w, "+10% WHEE!"), GREEN_C))
end
do -- live bonus flag joins the green lines, unvalued
  local w = newWorld()
  capWorld(w)
  w.auras[46668] = {}
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000,
    standing = 15000, bonus = true } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("rep bonus flag line", greenlines(w) == "+10% WHEE!\nBonus rep gain")
end
do -- bare rep bar names the gap in red
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("rep no-bonus red", sameColor(tipcolor(w, "No rep bonus"), RED_C))
end
do -- pause and reset work in rep mode
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 12000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  local slash = w.env.SlashCmdList.VOCXP
  w.now = w.now + 60
  w.factions[1].standing = 12300
  repEvent(w)
  slash("pause")
  hover(w)
  check("rep pause display", tiptexts(w)[1] == "Paused" and tiptexts(w)[2] == "Tracking paused")
  slash("pause")
  hover(w)
  check("rep resume collects", tiptexts(w)[1] == "Collecting data")
  slash("reset")
  hover(w)
  check("rep reset collects", tiptexts(w)[1] == "Collecting data")
  check("rep reset announces", w.printed[#w.printed] == "|cff66ccffVocXP|r: session reset")
end
do -- forever rep mode recommends nothing
  local w = newWorld()
  capWorld(w)
  w.addonInterfaceVersion = 16001
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  hover(w)
  check("forever rep missing quiet", missinglines(w) == "Following watched faction")
  check("forever rep no bonus", tiphas(w, "No rep bonus"))
end
do -- rep copy branches on the unit
  local w = newWorld()
  local ns = loadAddon(w)
  check("rep ready title", ns.titleText({ status = "ready", xpPerHour = 3600, etaSeconds = 600, unit = "Rep" })
    == "4k Rep/hr · 10m")
  check("rep zero title", ns.titleText({ status = "no-recent-xp", xpPerHour = 0, unit = "Rep" }) == "0 Rep/hr")
  check("untracked title", ns.titleText({ status = "untracked" }) == "No reputation tracked")
  check("rep-capped title", ns.titleText({ status = "rep-capped", capLabel = "Exalted" }) == "Exalted")
  check("rep-capped fallback", ns.titleText({ status = "rep-capped" }) == "Rank complete")
  check("rep silent sub", ns.subText({ status = "no-recent-xp", observedSeconds = 600, windowSeconds = 600, unit = "Rep" })
    == "No rep in the last 10m")
  check("untracked sub", ns.subText({ status = "untracked" }) == "Watch a faction to track it")
  check("rep-capped sub", ns.subText({ status = "rep-capped" }) == "Rank complete")
  check("rep awaiting sub", ns.subText({ status = "awaiting-level-update", unit = "Rep" })
    == "Rank complete; awaiting update")
  check("rep unavailable sub", ns.subText({ status = "unavailable", unit = "Rep" }) == "Waiting for rep data")
end

-- 39. Rep sessions persist the faction and survive zone loads.
do -- tracked ID persists across reloads
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.savedVars = { repFaction = 202 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("reload restores faction", ns.repTracked() == 202 and w.label.text == "Wardens  2k/6k (33%)")
end
do -- stale persisted ID falls through to untracked
  local w = newWorld()
  capWorld(w)
  w.savedVars = { repFaction = 999 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("stale persisted clears", ns.repTracked() == nil and ns.db.repFaction == nil)
  check("stale persisted guides", w.label.text == "No faction tracked")
end
do -- zone load keeps rep history
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 12000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.factions[1].standing = 12300
  repEvent(w)
  w.now = w.now + 30
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  hover(w)
  check("rep zone keeps history", tiptexts(w)[1] == "12k Rep/hr · 44m")
end
do -- character switch in rep mode starts over
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 12000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.factions[1].standing = 12300
  repEvent(w)
  w.guid = "Player-11-0002"
  w.now = w.now + 5
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  hover(w)
  check("rep switch clears", tiptexts(w)[1] == "Collecting data")
end
do -- cap event while still capped is a no-op
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 12000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  w.now = w.now + 60
  w.factions[1].standing = 12300
  repEvent(w)
  hover(w)
  local line = tiptexts(w)[1]
  maxLevelEvent(w)
  hover(w)
  check("capped cap-event no-op", tiptexts(w)[1] == line and w.label.text == "Court  300/9k (3%)")
end

-- 40. Cap detection is a level comparison like Blizzard's own bar:
-- at cap the client reports a phantom 100M requirement, never 0.
do -- the live report: level 90 with max 100M pivots to rep
  local w = newWorld()
  w.level, w.xp, w.max = 90, 0, 100000000
  setFactions(w, { { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 } })
  w.watchedID = 101
  loadAddon(w)
  clientLoaded(w)
  check("phantom max pivots", w.frame.shown == true and w.label.text == "Court  3k/9k (33%)")
  check("phantom max hides native", w.native.shown == false)
end
do -- effective max level mirrors GameRulesUtil
  local w = newWorld()
  local ns = loadAddon(w)
  check("standard cap 90", ns.effectiveMaxLevel() == 90)
  check("90 capped", ns.isLevelCapped(90, 100000000) == true)
  check("10 uncapped", ns.isLevelCapped(10, 69130) == false)
  check("wild level uncapped", ns.isLevelCapped(nil, 0) == false)
  w.timerunning = true
  w.expansionMaxLevel, w.latestMaxLevel, w.playerMaxLevel = 80, 90, 90
  check("timerunner follows latest", ns.effectiveMaxLevel() == 90)
  check("timerunner 85 uncapped", ns.isLevelCapped(85, 100000000) == false)
  w.timerunning, w.trial = false, true
  w.playerMaxLevel = 20
  check("trial cap 20", ns.effectiveMaxLevel() == 20)
  check("trial 20 capped", ns.isLevelCapped(20, 5000) == true)
end
do -- watched struct wins over a stale ByID read (seen live: 3000 vs 1803)
  local w = newWorld()
  capWorld(w)
  setFactions(w, { { id = 301, name = "Amani", reaction = 5, lo = 0, hi = 2500,
    standing = 1803, byIDStanding = 3000 } })
  w.watchedID = 301
  w.isMajor[301] = true
  w.major[301] = { level = 7, threshold = 2500, hasMax = false }
  loadAddon(w)
  clientLoaded(w)
  check("watched struct wins", w.label.text == "Amani  2k/2k (72%)")
  check("watched struct fills partial", w.bar.value == 1803)
end
do -- missing max-level APIs fall back to the legacy zero-max test
  local w = newWorld()
  local ns = loadAddon(w)
  w.env.GetMaxLevelForLatestExpansion, w.env.GetMaxLevelForPlayerExpansion = nil, nil
  w.env.GetMaxPlayerLevel, w.env.PlayerIsTimerunning, w.env.IsTrialAccount = nil, nil, nil
  check("no api unknown cap", ns.effectiveMaxLevel() == nil)
  check("no api zero max capped", ns.isLevelCapped(10, 0) == true)
  check("no api nonzero uncapped", ns.isLevelCapped(10, 1000) == false)
end
do -- partial APIs degrade to the per-player max
  local w = newWorld()
  local ns = loadAddon(w)
  w.env.GetMaxLevelForLatestExpansion, w.env.GetMaxLevelForPlayerExpansion = nil, nil
  w.env.PlayerIsTimerunning, w.env.IsTrialAccount = nil, nil
  check("partial cap 90", ns.effectiveMaxLevel() == 90)
  check("partial 90 capped", ns.isLevelCapped(90, 100000000) == true)
end

-- 41. Follow-latest preference flips the tracking priority.
do -- followLatest ignores the watched faction once gains arrive
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.watchedID = 101
  w.savedVars = { followLatest = true }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("follow falls back to watched", ns.repTracked() == 101 and ns.repFollowingWatched() == true)
  w.factions[2].standing = 9000
  repEvent(w)
  check("follow takes gains", ns.repTracked() == 202 and ns.repFollowingWatched() == false)
  check("follow repaints", w.label.text == "Wardens  3k/6k (50%)")
  hover(w)
  check("follow line", tiphas(w, "Following latest gains"))
end
do -- persisted faction bridges sessions until fresh gains
  local w = newWorld()
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.watchedID = 101
  w.savedVars = { followLatest = true, repFaction = 202 }
  local ns = loadAddon(w)
  clientLoaded(w)
  check("follow restores persisted", ns.repTracked() == 202 and ns.repFollowingWatched() == false)
  w.factions[1].standing = 16000
  repEvent(w)
  check("follow takes watched gains too", ns.repTracked() == 101 and ns.repFollowingWatched() == true)
end
do -- toggling followLatest live switches immediately
  local w = newWorld()
  w.withSettings = true
  capWorld(w)
  setFactions(w, {
    { id = 101, name = "Court", reaction = 6, lo = 12000, hi = 21000, standing = 15000 },
    { id = 202, name = "Wardens", reaction = 5, lo = 6000, hi = 12000, standing = 8000 },
  })
  w.watchedID = 101
  local ns = loadAddon(w)
  w.env.VocXPDB = w.savedVars
  w.frame.scripts.OnEvent(w.frame, "ADDON_LOADED", "VocXP")
  w.frame.scripts.OnEvent(w.frame, "PLAYER_ENTERING_WORLD")
  w.factions[2].standing = 9000
  repEvent(w)
  check("default keeps watched", ns.repTracked() == 101)
  ns.db.followLatest = true
  w.settingCallbacks["VocXP_followLatest"]()
  check("toggle on follows gains", ns.repTracked() == 202)
  ns.db.followLatest = false
  w.settingCallbacks["VocXP_followLatest"]()
  check("toggle off restores watched", ns.repTracked() == 101 and ns.repFollowingWatched() == true)
end

print("tests/run.lua: " .. passed .. " checks passed")
