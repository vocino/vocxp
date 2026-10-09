-- Lint config shared across the Voc family (see FAMILY.md). The WoW
-- client runs Lua 5.1; tests may use 5.4 features behind guards.
--
-- read_globals is the allowlist of WoW API verified against the build
-- in `## Interface:` (Blizzard_APIDocumentationGenerated for that
-- build, see FAMILY.md "Sources of truth"). Lint fails on any other
-- global on purpose: add a name here only after confirming it exists,
-- under that namespace, in the current build. Never from a wiki.
std = "lua51"
max_line_length = false
self = false
unused_args = false
exclude_files = { ".reference/**" }

-- Globals this addon owns: SavedVariables, slash registration, and the
-- addon compartment entry points named in the .toc.
globals = {
  "VocXPDB",
  "SLASH_VOCXP1", "SLASH_VOCXP2",
  "SlashCmdList",
  "VocXP_CompartmentClick", "VocXP_CompartmentEnter", "VocXP_CompartmentLeave",
}

-- WoW API and UI globals read by the addon.
read_globals = {
  "C_PvP", "C_Timer", "C_UnitAuras",
  "CreateFrame", "GameTooltip", "GetTime", "GetXPExhaustion", "IsInInstance",
  "Settings", "UIParent",
  "UnitGUID", "UnitLevel", "UnitXP", "UnitXPMax", "strtrim",
  "PlaySound", "SOUNDKIT", -- presence-gated; ns.play falls back to numeric IDs
}

files["tests/**"] = {
  std = "+lua54",
  globals = { "print" },
  read_globals = { "setfenv", "loadstring", "unpack" },
}
