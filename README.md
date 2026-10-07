# VocXP

## Problem

Leveling an alt and wondering if your XP rate is any good, or
whether you left War Mode off again. VocXP answers both with one
tiny readout.

## Use

A small tooltip-styled window. Drag it anywhere;
it remembers where you put it.

```
144k XP/hr · last 5m
Next level: ~25m
+10% War Mode
+20% Warband Mentored
Rested
```

```
/vxp        show/hide
/vxp lock   lock/unlock position
/vxp pause  pause/resume tracking
/vxp reset  restart the session timer
```

Line one is XP per hour over the trailing five minutes,
refreshed every second. While the window fills it names what it
has actually watched (`last 2m · warming up`); the first thirty
seconds just say Collecting data. Line two forecasts the next
level at that rate — the tilde means approximate, never a
promise. Below it, one line per active bonus: War Mode (live
Enlisted value, +10% base, higher under Call to Arms),
Warband Mentored Leveling with your current %, WHEE! and Darkmoon
Top Hat (+10% each, Darkmoon), Grim Visage / Unburdened (+10%,
Hallow's End), and Rested. No bonus, no mystery: it says "No XP
bonus" so you know to fix it. Max-level characters never see the
window at all, and the addon
runs no ticker and no XP, level, or aura event handlers for them.

## What's inside

- `main.lua`: the whole addon - rolling XP rate, ETA, the readout
- `VocXP.toc`: metadata

---

Part of the Voc family: tiny addons that do one job.
