# VocXP

## Problem

Leveling an alt and wondering if your XP rate is any good, or
whether you left War Mode off again. VocXP answers both with one
tiny readout.

## Use

A small transparent window, FPS-tracker style. Drag it anywhere;
it remembers where you put it.

```
412k XP/hr
+10% War Mode · Rested
```

```
/vxp        show/hide
/vxp lock   lock/unlock position
/vxp reset  restart the session timer
```

Line one is XP per hour for the current session (resets on
login). Line two lists your active XP bonuses: War Mode (+10%)
and Rested. No bonus, no mystery: it says "No XP bonus" so you
know to fix it.

## What's inside

- `main.lua`: the whole addon - XP events, rate math, the readout
- `VocXP.toc`: metadata

---

Part of the Voc family: tiny addons that do one job.
