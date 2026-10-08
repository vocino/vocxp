# AGENTS.md

## Code Map

- `main.lua` — the whole addon: rolling XP rate, time-to-level, bonus list, tooltip readout
- `VocXP.toc` — addon metadata (`Interface: 120100`)
- `VERSIONING.md` — tag-driven semver releases (same scheme as vocgear)
- `tests/run.lua` — stub-harness regression tests (`lua tests/run.lua`)
- `FAMILY.md` — conventions shared by every Voc addon (identical in
  every repo; see its "change it in one, copy it to all" rule)
- `.luacheckrc` — lint config: api-first WoW API allowlist (see
  FAMILY.md "Sources of truth")
- `.reference/api-verification.md` — per-API verification record
  (gitignored); the api-first rule lives here and in `.luacheckrc`
- `.github` — `test.yml` (tests + lint) and `release.yml` (packager)

## Live testing

`_retail_\Interface\AddOns\VocXP` should be a directory junction to
this repo, so edits go live on `/reload`. The client only loads
`.toc`-listed files; dev files (`.git`, docs) sitting in the folder
are ignored.

Recreate: `New-Item -ItemType Junction -Path '<AddOns>\VocXP' -Target D:\Code\vocxp`
Remove: `Remove-Item '<AddOns>\VocXP'` (link only — never `-Recurse`)

## Conventions

- `local name, ns = ...` first line; module state on `ns`.
- `VocXPDB` is the only addon-created global.
- Slash: `/vxp` (toggle), `/vxp lock`, `/vxp pause`, `/vxp reset`.
- Debugging follows `FAMILY.md` "Debugging": !BugGrabber +
  BugSack, errors read from `!BugGrabber.lua` after `/reload`.
- Craft follows the `voc-addons` skill, the source of truth for how Voc
  addons look, feel, and behave; load it before UI, settings, tooltip,
  sound, or visual-polish work.

## Tests

Run `lua tests/run.lua` (Lua 5.1 or 5.4) and `luacheck .` from the
repo root after behavior changes. Both run in CI on every push.
Tests are excluded from the packaged addon (see `.pkgmeta`).
