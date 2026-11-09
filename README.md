# VocXP

Leveling an alt and wondering if your XP rate is any good. VocXP answers
with one elegant experience bar: your level progress with rested XP and
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
too. Hover the bar and the label reads level, current and required XP,
and percent:

```
10  45k/100k (45%)
```

On the bar itself, progress, quest turn-ins, and rested XP stack in the order you would play them, each ending in a hard edge: native XP purple, then the prediction fill borrowed in gold for banked quest XP, then the native prediction fill for rested reach, with the rested pip marking where rested runs out. When rested overflows the bar the native client hides the reach; the bar follows that rule where the client states one.
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
level`), one line per active bonus, and a gray line naming the
bonus you are missing and how to get it:

```
Well Fed · kill XP (10m left)
```

Bonuses read live from a short verified-only registry: Well Fed,
the food buff that raises kill XP. Every food grants its own Well Fed
spell, so the entry matches by name first (with the spell ID as the
locale-proof fallback) and carries its remaining time when the client
reports one. Missing it, the gap names the fix (`Well Fed · kill XP
(eat food)`, or `food in bags` when food sits in your bags). No bonus,
no mystery: it says "No XP bonus" so you know to fix it. A short
registry that is right beats a long one that is guessed, so unverified
event and mode buffs have no entry at all; rested needs none either,
since the bar's own reach lines already report it.

```
/vxp           show or hide the bar
/vxp lock      lock or unlock the position
/vxp pause     pause or resume tracking
/vxp reset     restart the session
/vxp rep       reputation tracking on or off
/vxp config    open Settings > AddOns > VocXP
/vxp help      this list (/vocxp works too)
```

In dungeons and other instances the game hides world-granted
auras from addons, so the bonus scan pauses there with an honest note
instead of pretending your buffs expired.

On World of Warcraft Forever the registry reads the same: the name
query, the ID fallback, the remaining time, and the bag hint are all
verified on both clients. The bar, rate, and forecast work the same
on both clients. Reputation mode works there too.
Reputation bonuses at max level keep the list they already had.

At max level the bar pivots to reputation automatically: it follows
the watched faction ("Show as Experience Bar"), or the last faction
to gain reputation when nothing is watched, with Rep/hr and time
to the next rank in the label and tooltip
(`Honored · 33% to Revered`, `Renown 7 · 40% to 8`) across
standard standings, Renown, Paragon, and friendship tracks,
including a heads-up when a Paragon reward is pending. The fill takes
the faction's standing color (blue for Renown); rested, quest,
and XP-bonus lines retire with the XP side, and the
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
and restoring your quest selection as it scans). The bonus registry
reads live from the client (the Well Fed aura by name with an ID
fallback, its remaining time, and food in bags) and nothing is
multiplied twice:
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

## Support

Bugs, questions, and suggestions go in the [VocXP support thread](https://discord.com/channels/101033046475546624/1563993438452457502) on Discord. That thread is the main place for support.

## License

MIT

---

Part of the Voc family: tiny addons that do one job.
[wow.vocino.com](https://wow.vocino.com) ·
[VocWarbank](https://github.com/vocino/vocwarbank) ·
[VocGear](https://github.com/vocino/vocgear) ·
[VocXP](https://github.com/vocino/vocxp) ·
[VocVendor](https://github.com/vocino/vocvendor)
