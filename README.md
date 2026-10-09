# VocXP

Leveling an alt and wondering if your XP rate is any good, or whether
you left War Mode off again. VocXP answers both with one tiny readout:
XP per hour, time to the next level, and every XP bonus you are
running, plus the ones you are missing and how to get them.

## Install

Download the latest zip from [GitHub
Releases](https://github.com/vocino/vocxp/releases) (also on
CurseForge), copy the folder into `Interface/AddOns`, and make sure
it is named `VocXP` (the folder name must match the `.toc` file). The
same package runs on Retail and on the Forever client.

## Use

A small tooltip-styled window. Drag it anywhere; it remembers where
you put it. The addon compartment on the minimap toggles it too.

```
144k XP/hr · 25m
Last 10m
+20% Warband Mentored
+10% War Mode
Rested
```

```
/vxp           show or hide the readout
/vxp lock      lock or unlock the position
/vxp pause     pause or resume tracking
/vxp reset     restart the session
/vxp config    open Settings > AddOns > VocXP
/vxp help      this list (/vocxp works too)
```

Line one is the payoff, refreshed every second: XP per hour
over the trailing ten minutes, plus time to next level
(`144k XP/hr · 25m`). The forecast runs at your
trailing-fifteen-minute pace, so one-off bursts don't rewrite
it: a pace reading, never a promise. Line two
says how the headline was earned: `Last 10m` when steady;
`Warming up · last 3m of 10m` while the window fills;
`Idle 2m · last 10m` once a minute has passed with no gains;
`Collecting data` for the first thirty seconds, while the
headline shows pace alone; `No XP in the last 10m` when the
window is empty, with the headline reading `0 XP/hr`.
Warming up owns the second line until the window fills, so
idle only ever appears beside a full window. Below it, one
line per active bonus: War Mode (live
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

On World of Warcraft Forever only Rested is ever suggested: War
Mode, Warband Mentored, and the event buffs are unconfirmed
there, so the addon shows them when active but never recommends
them. The rate and forecast work the same on both clients.

Max-level characters never see the window at all, and the addon
runs no ticker and no XP, level, or aura event handlers for them.

## Config

Settings > AddOns > VocXP, or `/vxp config`:

- Show the readout (default on)
- Lock the position (default off)

Both are the same switches the slash line flips, and every change
applies at once.

## How it works

The XP bar is the single source of truth: every `PLAYER_XP_UPDATE`
reconstructs one award from the snapshot delta and stamps it on a
monotonic clock. A trailing ten-minute window gives the rate, a
fifteen-minute window gives the forecast, and neither is ever
persisted, so a reload starts an honest fresh session. Bonuses are
read live from the client (War Mode, rested state, the mentored and
holiday auras) and nothing is multiplied twice: awarded XP already
includes every bonus.

## What's inside

- `main.lua`: the whole addon: rolling XP rate, ETA, bonus list, the readout, settings, slash
- `VocXP.toc` / `VocXP_Forever.toc`: metadata for Retail and the Forever client
- `tests/run.lua`: stub-harness regression tests, no WoW client needed

## Tests

```
lua tests/run.lua
luacheck .
```

## License

MIT

---

Part of the Voc family: tiny addons that do one job.
[wow.vocino.com](https://wow.vocino.com) ·
[VocWarbank](https://github.com/vocino/vocwarbank) ·
[VocGear](https://github.com/vocino/vocgear) ·
[VocXP](https://github.com/vocino/vocxp) ·
[VocVendor](https://github.com/vocino/vocvendor)
