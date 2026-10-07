# Foolkevin Craft Study

A study of Peterodox's addon craft (Plumber, Narcissus, DialogueUI), distilled for the Voc addon family. Patterns and principles only. No code was lifted; Plumber is GPL-3.0 and the family's rule stands: emulate the approach with original code and Blizzard-native textures, never copy his code or art.

## 1. The Blizzard-native look comes from technique, not art

What he does: every custom window is built on the 9-slice layout technique with snap-to-pixel-grid rendering. The frames look like they belong in the game because they are constructed the way Blizzard constructs frames: sliced borders that scale cleanly, corners that stay crisp at any size, pixels that align to the grid instead of blurring.

Why it works: players cannot articulate it, but they feel the difference between a frame that sits on the pixel grid and one that floats half a pixel off it. Blizzard-native is a rendering discipline first and an art style second.

For the Voc family: use Blizzard's own NineSlice layouts and textures for any backdrop. Turn on pixel snapping. Never draw a custom border when a Blizzard one exists.

## 2. A tiny palette, used semantically

What he does: across hundreds of files the colors repeat. White for text, gold (ffd100) for highlights and labels, grays for secondary text, red and green only for state (warnings, valid/invalid). DialogueUI goes further with a named theme palette: every color has a name (DarkBrown, Ivory, Brick) and every theme (parchment, dark mode) maps the same names to different values. He even softens Blizzard's own harsh pure-red quest text to a readable brick red.

Why it works: restraint reads as polish. When red appears, it means something, because it almost never appears.

For the Voc family: define four or five colors once per addon and never hardcode a hex at a call site. Gold is for emphasis, red is for warnings, everything else is white or gray.

## 3. Blizzard fonts, with every alphabet covered

What he does: his font definitions use Blizzard's FRIZQT typeface and declare a member for every client alphabet: roman, Korean, simplified Chinese, traditional Chinese. Each gets a matching native font file and a 1-pixel text shadow. Non-Latin players get the same crafted look, not a fallback accident.

Why it works: most addon authors set one font and forget that half the player base sees something else. He treats localization as visual design, not string translation.

For the Voc family: do not ship custom fonts. Use Blizzard font objects. If a custom FontString is ever needed, remember the shadow offset; unshadowed text on a bright background is the fastest way to look amateur.

## 4. Blizzard sounds, with defensive fallbacks

What he does: every interaction sound is a Blizzard SOUNDKIT constant: checkbox on/off, window open/close, talent apply. Each reference carries a numeric fallback (`SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856`) so a renamed constant can never silence the UI. DialogueUI, which needed sounds Blizzard does not have, added exactly three tiny thematic ones: paper collect, page turn. Nothing more.

Why it works: familiar sounds make a custom window feel like part of the game. The fallbacks mean the polish never silently breaks on a patch day.

For the Voc family: give every clickable thing a Blizzard sound. Toggles get the checkbox pair. Never leave an interaction silent, and never invent a sound Blizzard already has.

## 5. Hover states are a contract, not decoration

What he does: his checkbox widget shows a tooltip on hover with a title line, a description line, and optionally a red restriction line (for example, when a feature does not work inside instances). The hover handler bails out while a mouse button is down, so tooltips never pop up mid-drag. Disabled controls desaturate and gray out instead of just dimming.

Why it works: the tooltip is where discoverability lives. A user who hovers learns what a thing does, when it works, and when it does not, without opening documentation.

For the Voc family: every control gets a tooltip. Every tooltip explains what the control does in one line. If a feature has a restriction (combat, instance, level), say so in the tooltip in red.

## 6. Settings are data, and they apply live

What he does: options are declared as data tables (type, label, tooltip, dbKey, click handler, and a validity function), not hand-built frames. A central database API broadcasts every change as a named event (`SettingChanged.<key>`), and modules subscribe to the keys they care about. Flipping a toggle takes effect immediately; nothing requires a reload, and nothing polls the database.

Why it works: data-driven options stay consistent as the addon grows, and the event broadcast is what makes "settings apply live" actually true instead of aspirational.

For the Voc family: this validates the family's live-settings principle. When a setting changes, the addon should react to the change event, not re-read the database on the next tick.

## 7. New things turn on; the user opts out, not in

What he does: when a new module ships, existing users get it enabled automatically, with a chat message announcing it and a "New" tag in the settings that expires after seven days. The exceptions live in one short explicit list (`NeverEnableByDefault`). There is no first-run wizard and no tutorial; the defaults are the onboarding, and the changelog appears on update.

Why it works: most users never open settings. If a feature is worth shipping, it is worth being seen. The opt-out list forces a conscious decision about what is too opinionated to enable silently.

For the Voc family: pick defaults as if nobody will ever open the settings page, because most players will not. When adding a feature, default it on unless there is a real reason not to, and write down the reason.

## 8. One module, one file, one job, self-registering

What he does: each Plumber module is a single file that defines a small descriptor (name, database key, description, toggle function, category, display order) and registers itself with the control center. The toggle function fully enables or disables the module, registering and unregistering its events. Module initialization runs inside a protected call, so one broken module reports an error instead of breaking the other sixty.

Why it works: the architecture makes the scope of each feature legible. You can read one file and know exactly what a module does, what it listens to, and how it cleans up after itself.

For the Voc family: this is the family contract with sharper edges. Each addon already does one job; inside each addon, keep features in the same self-contained shape: own state, own events, clean teardown, no cross-talk except through explicit channels.

## 9. Old code is retired in public, with reasons

What he does: removed modules stay in the defaults file as commented lines with the reason attached ("Fixed by Blizzard in 10.2.0", "Ridden with compatibility issue"). Expansion-old settings categories collapse by default. The table of contents gates files per game client, so code that cannot run on a client never loads there. Dev-only tools exist in the repo but are commented out of the shipped build.

Why it works: the "no" decisions are documented where the next reader will find them, which stops the same bad idea from being re-added. Shipping less is treated as a feature.

For the Voc family: when Blizzard fixes something an addon worked around, remove the workaround and leave a one-line note saying why. Keep a visible list of things deliberately not done.

## 10. Heavy features load on demand, not at login

What he does: Narcissus ships optional pieces (barbershop integration, gamepad support) as separate addons inside the same package. The main addon loads them only when their trigger event fires: barbershop code loads when the barbershop opens, gamepad code when a gamepad connects. Login stays light no matter how big the feature set grows.

Why it works: startup cost is paid by everyone, feature cost only by users of the feature. It is the difference between a big addon and a heavy one.

For the Voc family: the addons are already tiny, so this applies at the margin. If a feature needs a lot of code for a rare situation, gate it behind the event that defines the situation instead of loading it at startup.

## 11. He reads Blizzard's source, not just the API docs

What he does: he maintains a fork of Blizzard's interface code as a working reference. His bug fixes read like root-cause analyses: one module overrides a Blizzard API with a comment explaining exactly why the original returns the wrong value for one specific item. When an API differs across expansions, the differences live in a dedicated transition layer with one file per expansion, so the rest of the code never branches on version.

Why it works: API documentation says what a function should do; Blizzard's source says what it actually does. The transition layer keeps version hacks quarantined instead of scattered.

For the Voc family: this is already the family rule (client-first verification, api-verification.md per repo). The new takeaway is the quarantine pattern: when expansion or client differences force a workaround, isolate it in one clearly named place instead of sprinkling version checks through the logic.

## 12. Zero dependencies, vendored with attribution

What he does: there is no Libs folder and no bundled libraries. The one place that touches LibStub does so defensively, only if the user already has it, to offer optional integration. When he needs easing math, he vendors the functions with the original BSD license and attribution intact instead of embedding a library.

Why it works: every dependency is a thing that can break, bloat the download, or conflict with another addon. Vendoring a small pure function with credit is lighter than adopting a library for one feature.

For the Voc family: no change needed; the family already ships dependency-free. Keep it that way, and if a snippet is ever borrowed, attribute it in the file.

## 13. Unavailable is a designed state, not an error

What he does: modules declare a validity check, and the settings UI hides or disables anything that cannot work right now: wrong expansion, wrong season, a feature Blizzard has not enabled yet. Housing options appear only when housing exists. His photo-mode fade refuses to leave the player blind: it snaps the UI back on for raid countdowns, group finder popups, and choice dialogs.

Why it works: the unglamorous states are where trust is built. An addon that quietly disables what cannot work feels reliable; one that shows broken controls feels buggy, even when the bug is Blizzard's.

For the Voc family: every feature should know the conditions under which it cannot work, and say so plainly. A greyed control with a red tooltip line beats a control that silently does nothing.

## 14. He designs for other developers, not just players

What he does: a Documentation file describes his public widgets so other authors can reskin or reposition them. A dedicated folder holds compatibility shims for popular addons. The table of contents wires the addon into the compartment menu with hover callbacks. The addon list tooltip teaches the slash command, in every supported language.

Why it works: addons live in an ecosystem. The authors who document their seams get free integration work from everyone else, and their addons survive UI overhauls because others build on stable documented pieces.

For the Voc family: the guest hooks (VOCDBG, and any future shared pieces) deserve the same treatment: a short documented contract, stable names, and no surprises. The family footer on the CurseForge pages is the player-facing version of this; the code-facing version is a documented API other authors can rely on.

---

## The through-line

Every one of these is the same instinct applied at different scales: respect the player's attention. Nothing loads that is not needed, nothing shows that cannot work, nothing is silent when it should confirm, nothing requires configuration that a good default could replace. The craft is not in any single technique; it is in the refusal to ship the rough edge.
