---
name: voc-addons
description: Craft philosophy, visual identity, and source of truth for the Voc WoW addon family (VocWarbank, VocGear, VocXP, VocVendor). Load this skill when creating a new Voc addon, and before any UI, settings, tooltip, sound, or visual-polish work on one, and before reviewing addon code for craft quality. Defines the visual language, interaction standards, and scope discipline every Voc addon follows.
---

# voc-addons

## Source of truth

This skill is the source of truth for how Voc addons look, feel, and behave.
When this skill and a repo's local notes disagree about craft, this skill wins.
Principles evolve here; repos consume them, never fork them.

Install: clone into your agent's skills directory
(`~/.config/opencode/skills/`, `~/.claude/skills/`, or
`~/workspace/skills/`). CI consumes `checks/` directly (see below).

## The standard

One sentence: respect the player's attention. Nothing loads unneeded,
nothing shows broken, nothing is silent when it should confirm, and nothing
requires configuration that a good default could replace.

## Visual identity

Gold on dark is the house signature: textured 9-slice Blizzard panels,
snapped to the pixel grid, one gold accent per screen. Color tokens:
gold `ffd100` for titles and emphasis, white for text, gray for
secondary text, red and green for state only. Type has four levels:
gold title, white section header, white body, gray hint. Every screen
orders information the same way: the answer first, supporting context
second, actions third, configuration last. Each addon gets a medallion
icon: a circular gold emblem on a dark field with one glyph naming the
job, readable at 32 pixels. Full tokens, panel construction, and
anti-patterns: `references/voc-visual-identity.md`.

## Principles

### 1. Blizzard-native is technique, not art

Build windows on 9-slice layouts and snap everything to the pixel grid.
Use Blizzard's own textures and backdrops. A frame looks like it belongs
in the game when it is constructed the way Blizzard constructs frames.
Never draw a custom border when a Blizzard one exists. Never ship a
custom font; use Blizzard font objects, and keep the 1-pixel text shadow.

### 2. A tiny palette, used semantically

White for text, gold for emphasis, gray for secondary text. Red and green
only for state: warnings, valid/invalid. When red appears it means
something, because it almost never appears. Define the palette once per
addon; never hardcode a hex color at a call site.

### 3. Every interaction confirms

Play a Blizzard sound on every meaningful interaction, with a numeric
fallback (`SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856`) so a Blizzard
rename never silently kills the polish. Hovering a control shows a
tooltip: title, one-line description, and a red restriction line when it
does not apply ("does not work in instances"). Tooltips never fire
mid-drag; guard with `IsMouseButtonDown()`.

### 4. Settings are data, applied live

Options are declarative tables, not bespoke frames. A central store
broadcasts change events; UI subscribes. Changing a setting applies
immediately. No reload prompts, no polling loops. Emit on change, never
on poll.

### 5. Defaults are the onboarding

There is no first-run wizard. New features default ON for existing users,
announced with a chat notice and a "New" tag that expires after 7 days.
The rare exception lives in one explicit list, not scattered conditionals.
If a feature needs explaining, simplify the feature.

### 6. One file, one job

Each module does one thing, registers itself with a small descriptor
(name, toggle, validity check), and initializes inside a protected call
so one broken module can never take down the rest. Boundaries are drawn
where the player's mental model draws them.

### 7. Scope discipline, with a paper trail

Say no by default. Removed code stays as a comment with its reason
("fixed by Blizzard in 10.2.0"). Gate irrelevant code at load time so it
never runs. Anything heavy or situational is a separate addon loaded on
demand, not a toggle in this one.

### 8. Zero dependencies

No libraries folder, no hard requirements on other addons. Other addons
are guests: detect, integrate softly, degrade silently. (FAMILY.md
principle 4; this skill states the craft consequence.)

### 9. Unavailable is a designed state

Validity checks hide what cannot work instead of showing it broken.
If the UI must disappear (a raid countdown, a queue popup), it restores
itself afterward. The player is never left blind or staring at an error.

### 10. Design for the next developer

Public widgets get documented. Wire the addon compartment. Teach the
slash command in the toc notes. A stranger should be able to extend the
addon without reading your mind.

### 11. Every version of the game

V plays Midnight and Forever, so every addon ships a toc for both and
the same code runs on each. Verify every API against both clients (the
`live` and `forever` branches of the UI source mirror) before relying
on it. When a feature only exists on one version, presence-gate it:
the addon loads and works everywhere, and the feature quietly sits out
where it can't run. A missing API is never a missing addon. Dual tocs
are the mechanism; presence gates are the safety net.

## Checks

Principles that can be verified mechanically live in `checks/` and run
in CI on every Voc repo. Prose states the standard; checks enforce it.

- `no-hardcoded-colors.sh`: no `|cff` hex literals or numeric
  `CreateColor` at call sites (principle 2)
- `no-reloadui.sh`: settings apply live; `ReloadUI` never ships
  (principle 4)
- `dual-toc.sh`: every addon ships a Retail toc and a Forever toc
  (principle 11)

Run: `bash ~/workspace/skills/voc-addons/checks/<check>.sh <repo-dir>`.
Exit nonzero on violation. Keep checks fast, dependency-free, and
false-positive-free; a noisy check gets fixed or deleted, never ignored.

## How this skill evolves

Principles start as experiments, not laws. When working on an addon,
try things outside these principles when the work calls for it. Push
the boundaries and see what feels right. When a pattern proves itself
in a shipped addon and matches the standard above, push it back here:
add or sharpen the principle, and add a script under `checks/` if the
rule can be verified mechanically. This skill grows from what actually
shipped, not from speculation.

Checks are the proven tier: a check only lands here once every repo
already passes it. They describe what is true, never what is wished
for.

## References

- `references/voc-visual-identity.md`: the shared visual spec. Color
  tokens, type hierarchy, information hierarchy, panel construction,
  the medallion icon language, motion and sound, anti-patterns.
- `references/foolkevin-craft-study.md`: the 14-principle study of
  Peterodox's addon craft (Plumber, Narcissus, DialogueUI) this
  philosophy is distilled from. Patterns only; his code is GPL and
  is never copied.
