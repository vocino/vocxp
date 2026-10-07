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
+20% Warband Mentored
+10% War Mode
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
level at your trailing-fifteen-minute pace, so one-off bursts
don't rewrite the forecast — the tilde means approximate, never a
promise. Below it, one line per active bonus: War Mode (live
Enlisted value, +10% base, higher under Call to Arms),
Warband Mentored Leveling with your current %, WHEE! and Darkmoon
Top Hat (+10%, Darkmoon, either/or), Grim Visage / Unburdened (+10%,
Hallow's End), and Rested. No bonus, no mystery: it says "No XP
bonus" so you know to fix it. Below that, gray lines name the
bonuses you are missing, each with its value and a short
how-to:

```
+10% WHEE! (Faire week)
+10% Wickerman (Hallow's End)
```

In dungeons and other instances the game hides world-granted
auras from addons, so aura lines pause there with an honest note
instead of pretending your buffs expired; War Mode and Rested
keep reporting live.

Max-level characters never see the
window at all, and the addon
runs no ticker and no XP, level, or aura event handlers for them.

## What's inside

- `main.lua`: the whole addon - rolling XP rate, ETA, the readout
- `VocXP.toc`: metadata

---

Part of the Voc family: tiny addons that do one job.
