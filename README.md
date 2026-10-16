# VocXP

Leveling an alt and wondering if your XP rate is any good, or whether
you left War Mode off again. VocXP answers both with one elegant
experience bar: your level progress with rested XP and
ready-to-turn-in quest XP overlaid, hiding Blizzard's default bar
while it shows. Hover for XP per hour, time to the next level, and
every XP bonus you are running, plus the ones you are missing and
how to get them. At max level the same bar follows reputation
instead: your watched faction (or the latest gains) with Rep/hr
and time to the next rank.

## Install

Download the latest zip from [GitHub
Releases](https://github.com/vocino/vocxp/releases) (also on
CurseForge), copy the folder into `Interface/AddOns`, and make sure
it is named `VocXP` (the folder name must match the `.toc` file). The
same package runs on Retail and on the Forever client.

## Use

A single XP bar built from Blizzard's own bar art and animated bar template, so gains sweep, dings flash, and the rested pip rides like the default bar. Drag it anywhere;
it remembers where you put it, and it drags during Edit Mode sessions
even when locked. The addon compartment on the minimap toggles it
too. The label reads level, current and required XP, and percent:

```
10  45k/100k (45%)
```

Under the bar, a rate line keeps XP/hr and time-to-level on screen (`144k XP/hr · 25m`), and a stats line keeps ready quests and rested reach below it (`2 quests ready: 5% · Rested: 6%`), no hover needed. On the bar itself, progress, quest turn-ins, and rested XP stack in the order you would play them, each ending in a hard edge: native XP purple, then the prediction material tinted pending-gain gold for banked quest XP, then prediction blue for rested reach, with the rested pip marking where rested runs out.
Hover the bar for the payoff, refreshed every second: XP per hour
over the trailing ten minutes, plus time to next level
(`144k XP/hr · 25m`). The forecast runs at your
trailing-fifteen-minute pace, so one-off bursts don't rewrite
it: a pace reading, never a promise. Below it, how the headline
was earned: `Last 10m` when steady;
`Warming up · last 3m of 10m` while the window fills;
`Idle 2m · last 10m` once a minute has passed with no gains;
`Collecting data` for the first thirty seconds, while the
headline shows pace alone; `No XP in the last 10m` when the
window is empty, with the headline reading `0 XP/hr`.
Warming up owns the second line until the window fills, so
idle only ever appears beside a full window. Then rested and
quest reach (`Rested: 30% of level`, `2 quests ready: 5% of
level`), one line per active bonus, and gray lines naming the
bonuses you are missing, each with its value and a short
how-to:

```
+20% Warband Mentored
+10% War Mode
Rested
+10% WHEE! (Faire week)
+10% Wickerman (Hallow's End)
-60% Rested use (Regalia 6pc, 4/6 worn)
```

Bonuses read live: War Mode (live
Enlisted value, +10% base, higher under Call to Arms),
Warband Mentored Leveling with your current %, WHEE! and Darkmoon
Top Hat (+10%, Darkmoon, either/or), Grim Visage / Unburdened (+10%,
Hallow's End), and Rested. When worn heirlooms earn the Regalia of
Fabled Adventurers set, the Rested line carries the live burn
reduction (`Rested · -30% use (Regalia 2pc)`): the set stretches
Rested instead of raising the rate, so it annotates Rested rather
than joining the valued list. No bonus, no mystery: it says "No XP
bonus" so you know to fix it.

```
/vxp           show or hide the bar
/vxp lock      lock or unlock the position
/vxp pause     pause or resume tracking
/vxp reset     restart the session
/vxp config    open Settings > AddOns > VocXP
/vxp help      this list (/vocxp works too)
```

In dungeons and other instances the game hides world-granted
auras from addons, so aura lines pause there with an honest note
instead of pretending your buffs expired; War Mode and Rested
keep reporting live.

On World of Warcraft Forever only Rested is ever suggested: War
Mode, Warband Mentored, and the event buffs are unconfirmed
there, so the addon shows them when active but never recommends
them. Regalia never appears there: the heirloom set is retail-only.
The bar, rate, and forecast work the same on both clients.
Reputation mode works there too, minus rep buff recommendations
(all unconfirmed there).

At max level the bar pivots to reputation automatically: it follows
the watched faction ("Show as Experience Bar"), or the last faction
to gain reputation when nothing is watched, with Rep/hr and time
to the next rank on the rate line and the rank context below it
(`Honored · 33% to Revered`, `Renown 7 · 40% to 8`) across
standard standings, Renown, Paragon, and friendship tracks,
including a heads-up when a Paragon reward is pending. The fill takes
the faction's standing color (blue for Renown); rested, quest, War
Mode, Mentored, and Regalia lines retire with the XP side, and the
bonus list narrows to the buffs that raise reputation (Faire and
Wickerman pairs, Spirit of Sharing, and the live bonus flag). Turn it off
with "Track reputation at max level" to restore the old dormancy:
hidden bar, native bar back, nothing running. "Follow latest
reputation gains" flips the priority: the bar always follows your
latest earners instead of the watched faction. The tracked
faction survives reloads; with nothing watched and no gains yet,
the bar says so instead of guessing.

## Config

Settings > AddOns > VocXP, or `/vxp config`:

- Show the bar (default on)
- Hide the default XP bar (default on; hides Blizzard's whole
  status cluster, so watched reputation and honor bars hide too)
- Track reputation at max level (default on)
- Follow latest reputation gains (default off)
- Lock the position (default off)

All are the same switches the slash line flips, and every change
applies at once.

## How it works

The XP bar is the single source of truth: every `PLAYER_XP_UPDATE`
reconstructs one award from the snapshot delta and stamps it on a
monotonic clock. A trailing ten-minute window gives the rate, a
fifteen-minute window gives the forecast, and neither is ever
persisted, so a reload starts an honest fresh session. Rested XP
is drawn from the client's exhaustion value, and the quest
overlay sums the XP rewards of quests ready to turn in (saving
and restoring your quest selection as it scans). Bonuses are
read live from the client (War Mode, rested state, the mentored and
holiday auras, heirloom count) and nothing is multiplied twice:
awarded XP already
includes every bonus. The default bar stays hidden through a
re-applied hide, and an open Edit Mode session tempers the lock
so the bar drags while you arrange the rest of the UI. At max
level the same rolling window runs over reputation snapshots
instead of XP: gains diff from the tracked faction's baseline, the
tracked faction resolves watched-first, and switching factions
restarts observation.

## What's inside

- `main.lua`: the whole addon: XP/rep bar, overlays, quest scan, rolling rates, tooltip, settings, slash
- `VocXP.toc` / `VocXP_Camelot.toc`: metadata for Retail and the Forever client
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
