# RFC: Internationalisation — locale files with comptime-checked keys

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-08-06
**Tracking issue:** _(filed with this RFC — see below)_

## Problem

Games hardcode every user-visible string as a Zig literal. From `flying-platform-labelle/scripts/menu/menu_ui.zig`:

```zig
if (ui.button("New Game", BUTTON_WIDTH, BUTTON_HEIGHT, .accent)) { … }
if (ui.button("Load Game", BUTTON_WIDTH, BUTTON_HEIGHT, .normal)) { … }
```

There is no way to ship a second language short of editing source and rebuilding a separate binary. Nothing in `labelle-core`, `labelle-engine`, `labelle-gui`, or `labelle-cli` mentions locales, translation, or i18n today — this is a clean slate.

Rails is the reference point: one YAML file per locale, nested keys, `t("menu.new_game")`, interpolation. That shape is right. The *syntax* is not the transferable part, and neither is the runtime failure mode — Rails discovers a typo'd key as `translation missing: en.menu.new_game` rendered in front of a user, because nothing validates keys until the lookup happens.

labelle's assembler already generates code at build time. That means the entire class of missing-key and wrong-argument bugs can be a **compile error** instead. That, not the file format, is the reason to build this rather than have each game roll its own string table.

## Goals

1. **One file per locale, convention-scanned.** A `locales/` directory at project root; no registry to keep in sync — the same rule `scripts/` already uses.
2. **Nested keys with dotted access**, so keys group by screen/domain the way Rails' do.
3. **A misspelled key does not compile. An untranslated key that is actually rendered warns.** Those are different failures and deserve different severities: a typo is always a bug, whereas a string the reference locale has and `fr` does not is routine mid-feature — unless something on screen draws it. Coverage diagnostics are therefore scoped to keys the game genuinely uses (§3.1).
4. **Interpolation with comptime-checked arguments.** Passing the wrong placeholder name, or omitting one, is a compile error.
5. **Runtime locale switching** without a restart — the Options menu is the motivating consumer.
6. **Zero added cost for single-language games.** A game with one locale should pay nothing beyond the string table it would have written by hand.

## Non-goals

- **RTL / bidi layout and complex-script shaping.** Arabic and Indic text need shaping, which is a renderer concern — see RFC-FONT-LOADER §Non-goals, which defers shaping for the same reason. i18n produces *strings*; glyph coverage and layout are the font/renderer layer's problem. A game can ship a `he` locale today and get wrong-direction text; that is a font-stack gap, not an i18n gap.
- **Locale-aware number, date, and currency formatting.** Separate concern with a much larger surface (CLDR data tables). A game that needs it can format before interpolating.
- **Translator tooling.** No `.po`/`.xliff` import-export, no web editor, no machine-translation hook. Locale files are hand-edited JSONC.
- **OS locale auto-detection.** Platform-specific (`CFLocale`, `GetUserDefaultLocaleName`, `LANG`) and best added once one game actually wants it. Startup locale comes from config or env — see §8.
- **Per-entity or data-driven translation.** Item and workstation display names living in prefab `.jsonc` files are a plausible follow-up, but phase 1 covers UI strings written in scripts only.

## Design

### 1. Format: JSONC, not YAML

labelle already parses JSONC for scenes and prefabs, and the runtime-scenes work extends that. Adding YAML would mean a second config dialect and a new parser dependency for one feature. Rails chose YAML because Rails is YAML-shaped; the transferable idea is one-file-per-locale with nested keys, which JSONC expresses just as well — and comments in locale files are genuinely useful for translator notes.

```jsonc
// locales/pt-BR.jsonc
{
  "menu": {
    "new_game": "Novo Jogo",
    "load_game": "Carregar Jogo",
    "options": "Opções",
    "exit": "Sair",
  },
  "hud": {
    // {count} and {max} must match en.jsonc — the build checks this.
    "stock": "{count} de {max}",
  },
}
```

### 2. Directory convention

```
locales/
  en.jsonc
  pt-BR.jsonc
```

Flat, not recursive. Filename is the BCP-47 tag and the only place a locale is declared — adding `fr.jsonc` adds French, deleting it removes it.

**Packs ship their own.** `packs/<name>/locales/*.jsonc` is scanned too, with keys namespaced `<pack>__` exactly as pack components, scripts, and prefabs already are. A pack stays self-contained and drop-in.

### 2.1 The game takes precedence over the pack

A pack ships the languages its author had. A game shipping to a market the pack
never considered cannot be made to fork it, so:

- **The game overrides.** A `<pack>__` key defined in the game's `locales/` wins
  over the pack's. Same for constants (RFC-CONSTANTS §5.1).
- **The game adds.** A pack shipping `en` and `fr` does not stop a game adding
  `pt`. The game writes the pack's keys into its own `pt.jsonc`.

**The namespace is invisible inside a pack and explicit outside it.** Inside
`packs/citizens` you write `hunger.starving` and never see the prefix, as
RFC-packs promises. A game addressing that key has no other way to name it, so at
the override site it is `citizens__hunger.starving`. Both are true; the packs RFC
should say so, because it currently reads as "authors never type or see the
prefix" without qualification.

**Overriding asserts the key exists; adding does not.** These are different
operations and only one of them is a claim about the pack:

| the game writes | means | if no such key in the pack |
|---|---|---|
| a `<pack>__` key in a locale the pack ships | override | **error** |
| a `<pack>__` key in a locale the pack lacks | add | **error** |

Both error, and for the same reason: writing under a pack's namespace is a claim
that the pack defines that key. §3.1 makes *unused* keys silent, which is right
for pack-authored keys and wrong here — if a game writes
`citizens__hunger.starvng`, or the pack renames the key in v2, the game silently
gets the pack's string while believing it had replaced it. This check is the only
thing that turns a pack upgrade breaking a game's translations into a build
failure instead of a surprise in front of a player.

What *adding* changes is coverage, not existence: a `pt` file for a pack that
ships `en`/`fr` is new-locale-for-existing-key, so it is measured against the
pack's key space rather than against a `pt` that does not exist yet.

Placeholder parity (§4) applies unchanged, because overrides and additions go
through the same codegen: a `pt` string that drops `{count}` fails exactly as a
game's own would.

### 2.2 A pack declares its own reference locale

`.reference` in `project.labelle` (§8) is the backfill source that makes §3.1's
table rectangular, and that is what lets §5 promise **no runtime fallback code
needs to exist**. That promise assumes the reference locale contains every used
key.

For a pack's keys it does not. A pack ships `en` and `fr`; a studio authoring in
Portuguese sets `.reference = "pt"`; the pack's keys are in neither the game's
`pt` nor anywhere the project reference can see. There is nothing to backfill
from and the table cannot be made rectangular.

So `pack.labelle` declares its own `.reference`, and backfill resolves:

```
locale → pack reference → project reference
```

A `pt` player then reads the pack's English for strings nobody has translated
yet, which is the right outcome, and the no-runtime-failure guarantee survives
contact with a pack the game does not control. A pack that declares no
`.reference` falls back to the project's, which is correct for in-tree packs
authored alongside the game.

### 3. Key generation — the part Rails structurally cannot do

The assembler scans `locales/`, reads the **reference locale** from `project.labelle` (§8), and generates a key type plus a string table.

Naïvely flattening `menu.new_game` to `menu_new_game` collides: `a.b_c` and `a_b.c` produce the same identifier. Instead, generate nested namespaces of typed constants, which preserves the dotted call site *and* the tree:

```zig
// generated
pub const Key = enum(u16) { _ };
pub const K = struct {
    pub const menu = struct {
        pub const new_game: Key = @enumFromInt(0);
        pub const load_game: Key = @enumFromInt(1);
    };
    pub const hud = struct {
        pub const stock: Key = @enumFromInt(7);
    };
};
```

Call site:

```zig
if (ui.button(t(K.menu.new_game), BUTTON_WIDTH, BUTTON_HEIGHT, .accent)) { … }
```

`K.menu.new_gme` is a compile error at the point of use, naming the missing declaration. No lookup, no fallback, no runtime string comparison.

**Build-time validation**, run by the assembler after the scan:

| Condition | Result |
|---|---|
| Key **used in code**, present in reference, missing from locale *L* | **Warning**, naming the key and every locale missing it |
| Key **unused**, missing from locale *L* | Silent (reported only under `--verbose`) |
| Key in *L*, absent from reference | **Build error** — catches renames that updated one file only |
| Placeholder set differs between reference and *L* | **Build error**, showing both placeholder sets |
| `locales/` exists, no `i18n.default` declared | **Build error** (§8) |
| `i18n.default` / `.reference` names a locale with no file | **Build error**, with "did you mean" against scanned tags |

The first two rows are the important ones, and §3.1 is why they can be split at all.

`i18n.strict = true` in `project.labelle` promotes row 1 to a hard error — the setting a release build turns on. Default is warn, because a key that no locale but the reference has yet is the *normal* state while a feature is being written, and blocking the build on it would make adding a string to `en.jsonc` an immediate cross-locale chore.

### 3.1 Usage-aware diagnostics — why this works here and not in Rails

A key sitting in `en.jsonc` that no locale translates and **no code renders** is dead weight, not a defect. A key that some screen actually draws and only the reference locale defines is a user-visible hole. Rails cannot tell these apart, because its keys are runtime strings and may be computed:

```ruby
t("menu.#{action}_label")   # what key is this? unknowable without running it
```

Static usage analysis of a Rails app is therefore unsound, so Rails checks nothing until lookup. labelle's key space is **closed and syntactically visible**: a `Key` can only be named as a `K.<path>` constant, it cannot be built from a runtime string, and there is no `t(comptime_string)` overload to leave one. That makes "which keys does this game actually use" a decidable, cheap build-time question — and it is the reason the warning above can be scoped to keys that matter.

Two enforcement points, because they have different powers:

**(a) Call site, at comptime — errors only.** `t` takes `comptime key: Key`, so it instantiates *only* for keys the game actually references. A coverage check inside it is usage-driven by construction, with no scan at all:

```zig
pub fn t(comptime key: Key) [:0]const u8 {
    comptime if (strict and missing_in(key).len > 0)
        @compileError("i18n: key '" ++ name(key) ++ "' missing from: " ++ missing_in_list(key));
    return table[active][@intFromEnum(key)];
}
```

The diagnostic lands on the exact line that would have rendered the missing string — better than any report a scanner can produce. But this path can only *fail*: Zig has no comptime warning. `@compileLog` is not one — it prints its values and then ends the build with `error: found compile log statement` (verified on 0.16.0). So comptime alone cannot express the default policy.

**(b) Assembler, at build time — warnings.** The assembler already scans game and pack sources to discover scripts. The same pass collects `K.<path>` references into a used-set and diffs it against each locale, printing warnings for row 1. This is where the non-strict default lives.

So: **comptime enforces, the assembler advises.** Strict flips the policy from (b) to (a).

The soundness of (b) rests on the closed key space — worth stating its one hole plainly: `@enumFromInt` can forge a `Key` that no `K.` path names, which would evade the scan. That is pathological, has no legitimate use, and is out of contract.

**No runtime fallback logic is needed either way.** When a locale is missing a used key, codegen fills that table slot with the **reference locale's string** — the pack's own reference for a `<pack>__` key, the project's otherwise (§2.2). The table is always rectangular and always complete, so §5's guarantee holds unchanged — the warning tells you a slot was backfilled, and the game renders reference-language text there rather than a blank or a `translation missing` marker.

### 4. Interpolation and argument checking

Placeholders are `{name}`. Because codegen knows each key's placeholder set, it can generate a per-key argument type:

```zig
pub fn Args(comptime key: Key) type;   // generated: anonymous struct with exactly that key's placeholders
pub fn tf(comptime key: Key, args: Args(key)) [:0]const u8;
```

```zig
tf(K.hud.stock, .{ .count = 5, .max = 10 })   // ok
tf(K.hud.stock, .{ .count = 5 })              // compile error: missing field 'max'
tf(K.hud.stock, .{ .cnt = 5, .max = 10 })     // compile error: no field 'cnt'
```

**Two functions, because the costs genuinely differ:**

- `t(key)` — no placeholders. Returns `[:0]const u8` straight out of the static table. No allocation, no formatting, and the sentinel means it hands directly to cimgui.
- `tf(key, args)` — has placeholders. Must format into a buffer.

Splitting them keeps the zero-cost path honest instead of hiding an allocation behind a uniform API. Codegen knows which keys have placeholders, so calling `t` on an interpolated key is itself a compile error.

`tf`'s buffer comes from a **frame arena** reset once per frame. UI strings are per-frame and short-lived; an arena avoids both a per-call allocation and any free discipline at the call site. The returned slice is valid until the next frame — documented, and the reason `tf` results must never be stored in a component. (Ownership is Open Question 1.)

### 5. Storage and runtime switching

Two options, and they trade the same way everywhere:

**(a) Bake every locale into the binary** as a comptime `[n_locales][n_keys][:0]const u8` table. Switching swaps an index. No I/O, no allocation, no failure path, instant.

**(b) Bake only the reference**, load others from disk on switch. Smaller binary, but reintroduces a runtime failure path — a missing or malformed file at switch time — which is exactly the property §3 buys.

**Recommend (a) for the first cut.** UI text is a few KB per locale, negligible next to art. It also preserves the strongest guarantee in this RFC: with the table made rectangular at build time (§3.1 — gaps backfilled with the reference string) and every locale resident, **no runtime path can fail and no fallback code needs to exist**. Revisit if a game ships enough locales for binary size to matter (Open Question 5).

```zig
pub fn setLocale(tag: []const u8) bool;   // false = unknown tag, active locale unchanged
pub fn activeLocale() []const u8;
pub fn locales() []const []const u8;      // for building the Options selector
```

### 6. No comptime interface slot

Render, audio, and input are interface slots in `labelle-core` because each has multiple backends. i18n has **no backend variability** — it is pure data plus generated lookup. So it does not get an interface slot; the assembler injects a generated `i18n` module the way it already injects `gui_backend`, and scripts reach it with `@import("i18n")`. Adding a slot here would be ceremony with one implementation behind it.

### 7. Consumer: the Options menu

`flying-platform-labelle`'s Options view already has the shape a language selector needs — it gained kit-styled checkbox rows in FP#779. A locale row lands next to Fullscreen and Vsync, driven by `locales()` and `setLocale()`, and the menu's own strings become the first thing converted. That makes FP the proving ground for whether the ergonomics hold.

### 8. Configuration — `project.labelle` declares the default language

`project.labelle` is ZON, so the block nests like the existing `.asset_compression` / `.backend_package` entries:

```zig
.i18n = .{
    .default = "pt-BR",   // REQUIRED — the locale the game starts in
    .reference = "en",    // optional  — the locale keys are authored in (defaults to .default)
    .strict = false,      // optional  — promote coverage warnings to errors (§3.1)
},
```

**`.default` is mandatory whenever `locales/` exists.** No implicit `"en"`. A game's shipping language is a deliberate product decision, not something the build should guess from a filename — and an inferred default is exactly the kind of thing that goes unnoticed until someone launches in the wrong language. A `locales/` directory with no `i18n.default` is a build error; so is a `.default` naming a locale with no matching file (with "did you mean" against the scanned tags, since a BCP-47 typo like `pt_BR` for `pt-BR` is easy).

Games with no `locales/` directory declare nothing and pay nothing — the whole block is absent and codegen emits no i18n module.

**Two settings, because they answer different questions.** `.default` is *what the player sees at first launch*; `.reference` is *which locale defines the canonical key set* and is the backfill source for gaps (§3.1). They coincide for most games, which is why `.reference` falls back to `.default`. They come apart when a studio authors keys in English but ships Portuguese first — then `en` is the complete, canonical set while `pt-BR` is the startup language. Folding them into one field would make that project choose between an English launch and losing its authoring language as the coverage baseline.

**Startup resolution**, first match wins:

1. `LABELLE_LOCALE` env var — a *dev and CI* override, matching the existing `LABELLE_*` run knobs (`LABELLE_SCENE`, `LABELLE_HEADLESS`). It makes screenshotting every locale a loop over one variable. An unknown tag here is a warning and is ignored, not a crash — it must not be able to break a player's run if it leaks into a shipped environment.
2. A persisted player choice, once `setLocale` is wired to settings (out of scope for phase 1).
3. `i18n.default`.

OS detection is deliberately absent (see Non-goals). If it lands later it slots in above `.default` and below the player's own choice.

## Phasing

| Phase | Scope |
|---|---|
| 1 | `locales/` scan, key codegen, static `t()`, usage-aware coverage diagnostics (§3.1), `setLocale` |
| 2 | Interpolation: `tf()`, per-key `Args`, frame arena, placeholder-parity validation |
| 3 | Pack-scoped locales (`packs/<name>/locales/`, `<pack>__` namespacing), game override/add precedence and the must-exist check (§2.1), per-pack `.reference` (§2.2) |
| 4 | Plurals — CLDR categories (`zero`/`one`/`two`/`few`/`many`/`other`) as a nested key convention with per-locale category sets |

Phase 1 alone converts the FP menu and is independently useful.

## Open questions

1. **Frame arena ownership.** Engine-owned and reset in the frame loop, or game-owned and passed in? Engine-owned is less ceremony but puts an allocator in the i18n module that single-language games never touch.
2. ~~**Strict by default?**~~ **Resolved** (§3 / §3.1): default is a *warning*, scoped to keys actually used in code; `i18n.strict = true` promotes it to a comptime error for release builds. Unused untranslated keys are silent. Remaining sub-question: should `strict` also be settable per-locale, so a game can ship `pt-BR` strictly while `fr` is still in progress?
3. **Key type stability.** `@enumFromInt` indices are assigned by scan order. Reordering a locale file must not silently change what a key means — sort keys deterministically before assigning, and confirm nothing persists a `Key` value to disk.
4. ~~**Pack key collisions.**~~ **Resolved** (§2.1): two packs both defining `ui.title` namespace to `a__ui.title` / `b__ui.title`. And yes — a game overrides a pack's string without forking it, and may add locales the pack never shipped. The game takes precedence.
5. **Binary-size ceiling** for strategy (a). At what locale count does baking everything stop being obviously right?
6. **Font coverage interaction.** A locale needing glyphs outside the baked atlas renders blanks. Should the assembler cross-check locale codepoints against `FontBakeParams.ranges` (RFC-FONT-LOADER §2) and fail the build? That would be a genuinely novel check — and cheap, since both are build-time data.

## Prior art

| System | Format | Key checking | Notes |
|---|---|---|---|
| Rails i18n | YAML | Runtime — renders `translation missing: …` | The shape this RFC borrows |
| gettext | `.po`/`.mo` | Runtime, falls back to msgid | Mature tooling, C-oriented |
| Unity Localization | Asset tables | Runtime (editor warns) | GUI-driven table editing |
| Mozilla Fluent | `.ftl` | Runtime | Richest grammar (genders, plurals as first-class) |

All four check keys at runtime, because all four load translations at runtime. labelle's build already generates the game's wiring, so it can check at compile time instead — that is the one thing this design does that none of the prior art can.

The sharper distinction is §3.1. Every system above can report "locale *L* is missing key *k*"; none can reliably answer "…and is *k* actually rendered anywhere?", because in all four the key space is open — keys are strings assembled at runtime. labelle's keys are comptime symbols from a closed set, which turns coverage from a list you skim into a diagnostic that only fires on holes a player could see.
