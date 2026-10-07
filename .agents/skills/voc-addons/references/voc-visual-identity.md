# Voc visual identity

How every Voc addon looks. This is the shared spec that makes the
family recognizable: textured and Blizzard-adjacent like Plumber, but
ours. Gold on dark is the house signature. Every current and future
addon implements these tokens independently; nothing here is shared
code, so there is nothing to couple.

## The idea

A Voc addon should be recognizable at a glance without shouting. The
look is textured, not flat: panels with weight, gold accents, quiet
grays. It is differentiated from the stock UI the way a good transmog
is differentiated from quest greens: same world, better tailored.

Plumber's lesson, made ours: distinctiveness is systematic. The same
panel treatment, the same palette, the same header style, on every
screen. No screen invents its own look.

## Color tokens

Define these once per addon (see the `no-hardcoded-colors.sh` check).
Never hardcode a hex at a call site.

| Token | Value | Role |
| --- | --- | --- |
| VocGold | `ffd100` | Titles, emphasis, the one accent per screen |
| VocText | white | Primary text |
| VocMuted | gray | Secondary text, hints, timestamps |
| VocRed | softened red | Warnings and restriction lines only |
| VocGreen | soft green | Valid state only |

Red and green appear only for state. When red appears it means
something, because it almost never appears. Pure Blizzard red is
harsh; soften it toward brick.

Panels are dark and textured: build on Blizzard's own 9-slice
backdrops, never a flat custom fill. Gold is the single warm accent
against the dark. If a screen has two gold elements competing, one of
them is wrong.

## Type hierarchy

Four levels, no more. Each level has exactly one job.

1. **Title.** Gold. One per panel. Names the thing the player is
   looking at.
2. **Section header.** White, one step down. Names a group of
   related controls or information.
3. **Body.** White, standard game size. The working text: values,
   labels, descriptions.
4. **Hint.** Gray, smaller. Secondary info: timestamps, footnotes,
   "last updated" lines.

Never skip a level. Never use color alone to separate levels; size
and weight do the structural work, color does the emphasis. All text
carries Blizzard's 1-pixel shadow. No custom fonts, ever.

## Information hierarchy

Order every screen the same way, top to bottom:

1. **The answer.** The one thing the player opened this for. Biggest,
   first, unmissable. (VocXP: the XP/hr number. VocWarbank: the
   ranked list. VocGear: the verdict.)
2. **Supporting context.** The detail that explains the answer.
   (Bonus list, item counts, which piece upgraded.)
3. **Actions.** What the player can do about it, in one place.
4. **Configuration.** Last, least prominent, or behind its own
   section. Most players will never scroll this far; the defaults
   must carry them (see the skill's principle 5).

Progressive disclosure throughout: summary first, detail on hover or
click. A screen that shows everything at once has no hierarchy.

## Panel construction

- 9-slice Blizzard backdrops, snapped to the pixel grid. Corners stay
  crisp at any size.
- One consistent padding rhythm inside panels; related controls sit
  closer than unrelated ones.
- Section headers are labeled plaques, not bare text floating in
  space: a short gold or white label that names the group.
- Disabled controls desaturate; they never just dim.

## Icon language

Every addon gets a medallion: a circular gold emblem on a dark field
with a single gold glyph naming the job (coin for the bank, gear for
equipment, arrow for XP). Rules for new medallions:

- One glyph, readable at 32 pixels.
- Gold line work, dark recessed field, thin gold rim.
- Ornate but not busy: the glyph must survive shrinking to the
  addon compartment.

## Motion and sound

- Panels fade or scale in subtly; nothing pops.
- Every interaction confirms with a Blizzard sound (see the skill's
  principle 3). Toggles use the checkbox pair. Nothing is silent.
- Hover tooltips follow the contract: title, one-line description,
  red restriction line when it does not apply.

## Chat voice

Chat output follows FAMILY.md "Chat voice": short, plain, no spam.
The addon announces what it did and stays quiet otherwise.

## Anti-patterns

These never ship, no matter how modern they look elsewhere:

- Flat web-style panels with no texture.
- Custom fonts or unshadowed text.
- Rainbow colors; gold is the only warm accent.
- Silent buttons or toggles.
- Config-first screens that bury the answer below the options.
- One-off visual inventions per screen. If it is not in this spec,
  it does not go in the addon without a proposal to change the spec.
