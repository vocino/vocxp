local name, ns = ...
-- VocXP: session XP/hr plus active XP bonuses in one tiny readout.
-- Nothing else.

VocXPDB = VocXPDB or {}
ns.db = VocXPDB

local defaults = { shown = true, locked = false, point = "CENTER", x = -340, y = 200 }
local function opts()
  for k, v in pairs(defaults) do
    if ns.db[k] == nil then ns.db[k] = v end
  end
  return ns.db
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

local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
text:SetPoint("TOPLEFT", 4, -4)
text:SetJustifyH("LEFT")
text:SetShadowOffset(1, -1)

-- Session state.
local sessionXP, sessionStart, lastXP, lastMax = 0, time(), 0, 0

local function fmt(n)
  if n >= 1e6 then return ("%.1fm"):format(n / 1e6) end
  if n >= 1e3 then return ("%.0fk"):format(n / 1e3) end
  return ("%.0f"):format(n)
end

local function warMode()
  return type(C_PvP) == "table"
    and type(C_PvP.IsWarModeDesired) == "function"
    and C_PvP.IsWarModeDesired()
end

local function rested()
  return GetXPExhaustion() ~= nil
end

-- Fixed-value XP-buff auras by spell ID: WHEE!
-- (Darkmoon carousel/coaster/Top Hat), Grim Visage / Unburdened
-- (Hallow's End Wickerman, one per faction).
local xpBuffs = {
  { id = 46668, label = "+10% WHEE!" },
  { id = 24705, label = "+10% Grim Visage" },
  { id = 95987, label = "+10% Unburdened" },
}

local function playerAura(spellID)
  if type(C_UnitAuras) ~= "table" then return nil end
  if type(C_UnitAuras.GetPlayerAuraBySpellID) ~= "function" then return nil end
  return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

-- Tooltip text hierarchy: white title line, green bonus lines, red warning.
local WHITE, GREEN, RED = "ffffff", "40ff40", "ff4040"
local function painted(color, s) return "|cff" .. color .. s .. "|r" end

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
  local lines = {}
  local o = opts()
  local maxed = (lastMax or 0) == 0
  if maxed then
    frame:SetShown(false)
    return
  else
    local elapsed = math.max(time() - sessionStart, 1)
    lines[1] = painted(WHITE, fmt(sessionXP / elapsed * 3600) .. " XP/hr")
  end
  local bonuses = bonusParts()
  if #bonuses == 0 then
    lines[#lines + 1] = painted(RED, "No XP bonus")
  else
    for _, b in ipairs(bonuses) do lines[#lines + 1] = painted(GREEN, b) end
  end
  text:SetText(table.concat(lines, "\n"))
  frame:SetSize(text:GetStringWidth() + 8, text:GetStringHeight() + 8)
  frame:SetShown(o.shown)
end

-- At max level the addon goes fully dormant: no ticker, no hot
-- events. PLAYER_ENTERING_WORLD stays registered as the wake path
-- (loading screens only); a cap raise restarts everything there.
local ticker
local function shutdown()
  frame:SetShown(false)
  if ticker then ticker:Cancel() ticker = nil end
  frame:UnregisterEvent("PLAYER_XP_UPDATE")
  frame:UnregisterEvent("UNIT_AURA")
end

local function onXP()
  local xp, max = UnitXP("player"), UnitXPMax("player")
  if max == 0 then
    lastXP, lastMax = xp, max
    shutdown()
    return
  end
  if max and max > 0 then
    if xp >= lastXP then
      sessionXP = sessionXP + (xp - lastXP)
    else
      sessionXP = sessionXP + (lastMax - lastXP) + xp -- leveled up
    end
  end
  lastXP, lastMax = xp, max
  refresh()
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_ENTERING_WORLD" then
    ns.db = VocXPDB or ns.db -- client replaced the file-top table
    lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
    if lastMax == 0 then shutdown() return end
    sessionXP, sessionStart = 0, time()
    local o = opts()
    frame:ClearAllPoints()
    frame:SetPoint(o.point, UIParent, o.point, o.x, o.y)
    frame:RegisterEvent("PLAYER_XP_UPDATE")
    frame:RegisterEvent("UNIT_AURA")
    if not ticker then ticker = C_Timer.NewTicker(5, refresh) end
    frame:EnableMouse(not o.locked)
  else
    if event == "UNIT_AURA" then
      if arg1 ~= "player" then return end
    else
      onXP()
    end
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
  elseif msg == "reset" then
    sessionXP, sessionStart = 0, time()
    refresh()
    print(name .. ": session reset.")
  else
    o.shown = not o.shown
    refresh()
    if (lastMax or 0) == 0 then
      print(name .. ": max level (stays hidden).")
    else
      print(name .. ": " .. (o.shown and "shown." or "hidden."))
    end
  end
end
