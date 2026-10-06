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

local frame = CreateFrame("Frame", "VocXPFrame", UIParent)
frame:SetSize(150, 32)
frame:SetClampedToScreen(true)

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

local function bonusLine()
  local parts = {}
  if warMode() then parts[#parts + 1] = "+10% War Mode" end
  if rested() then parts[#parts + 1] = "Rested" end
  if #parts == 0 then return "No XP bonus" end
  return table.concat(parts, " · ")
end

local function refresh()
  local o = opts()
  local maxed = (lastMax or 0) == 0
  if maxed then
    text:SetText("Max level")
  else
    local elapsed = math.max(time() - sessionStart, 1)
    text:SetText(fmt(sessionXP / elapsed * 3600) .. " XP/hr\n" .. bonusLine())
  end
  frame:SetShown(o.shown)
end

local function onXP()
  local xp, max = UnitXP("player"), UnitXPMax("player")
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
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" then
    lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
    sessionXP, sessionStart = 0, time()
    local o = opts()
    frame:ClearAllPoints()
    frame:SetPoint(o.point, UIParent, o.point, o.x, o.y)
    frame:EnableMouse(not o.locked)
  else
    onXP()
  end
  refresh()
end)

-- Keep the rate ticking between XP events.
C_Timer.NewTicker(5, refresh)

-- Drag to move; position persists in VocXPDB.
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function()
  if not opts().locked then frame:StartMoving() end
end)
frame:SetScript("OnDragStop", function()
  frame:StopMovingOrSizing()
  local o = opts()
  o.point, _, _, o.x, o.y = frame:GetPoint(1)
end)

SLASH_VOCXP1 = "/vxp"
SlashCmdList.VOCXP = function(msg)
  msg = (msg or ""):lower():trim()
  local o = opts()
  if msg == "lock" then
    o.locked = not o.locked
    frame:EnableMouse(not o.locked)
    print("VocXP: " .. (o.locked and "locked." or "unlocked. Drag to move."))
  elseif msg == "reset" then
    sessionXP, sessionStart = 0, time()
    refresh()
    print("VocXP: session reset.")
  else
    o.shown = not o.shown
    refresh()
    print("VocXP: " .. (o.shown and "shown." or "hidden."))
  end
end
