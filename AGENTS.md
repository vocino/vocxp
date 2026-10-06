# AGENTS.md

## Code Map

- `main.lua` — the whole addon: XP events, session rate, bonus line, readout
- `VocXP.toc` — addon metadata (`Interface: 120100`)
- `VERSIONING.md` — tag-driven semver releases (same scheme as vocgear)

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
- Slash: `/vxp` (toggle), `/vxp lock`, `/vxp reset`.
