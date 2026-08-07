# RFC: Game constants — one folder, YAML per domain, inlined at build time

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-08-06
**Sibling RFC:** [RFC-I18N](./RFC-I18N.md) — shares the scan-and-codegen machinery (§6)

## Problem

Tuning values live wherever the code that reads them happens to live. In `flying-platform-labelle` today there are **38 such constants across 17 files**, and the pattern is not that they are hard to find — it is that nothing relates them to each other.

The construction family:

```
packs/rooms/…/26_construction_progress.zig      BUILD_TIME              = 5.0
packs/rooms/…/32_carcase_build_dispatcher.zig   CONSTRUCTION_DURATION_S = 5.0
packs/rooms/…/40_repair_progress.zig            REPAIR_TIME             = 5.0
packs/rooms/…/40_repair_progress.zig            PER_PIECE_TIME          = 5.0
packs/rooms/…/29_deconstruction_progress.zig    DECONSTRUCT_TIME        = 4.0
```

Five timings, four files, four sharing the value `5.0` with no record of whether that is intent or coincidence. Changing "how long building takes" means finding all five and deciding, per site, whether it is one of the five.

`SHIP_SPEED` is defined twice with different values — `280` in `packs/transport/scripts/playing/37_transport_delivery.zig`, `150` in `packs/combat/scripts/playing/ship_animation.zig`. Both are legitimate (different ships), but nothing says so, and nothing would catch it if one were meant to track the other.

Decay rates cluster in `libs/needs_machine/src/config.zig`, which is the closest thing the game has to this proposal already — and it demonstrates the failure mode. It holds `health_drain_rate = 0.0`, a value with consequences big enough that the game's `CLAUDE.md` spends four paragraphs on it ("**When diagnosing a stalled colony, check for needs pinned at 0 instead of waiting for deaths**"). That warning exists because the value is invisible where it sits. A balance value that changes how the game fails should not be discoverable only by reading a plugin's source.

## Goals

1. **One folder.** `constants/` at project root; every tuning value in the game reachable from one place.
2. **One file per domain**, named for the domain — `construction.yaml`, `decay.yaml` — so related values sit together and a diff reads as a balance change.
3. **YAML**, for hand-editing by whoever is balancing the game.
4. **Zero runtime cost.** Values inline exactly as the `const` literals they replace. A shipped game reads no files and carries no parser.
5. **A misspelled constant does not compile**, the same property [RFC-I18N](./RFC-I18N.md) §3 gives keys.
6. **Packs bring their own**, namespaced, so a pack stays drop-in.

## Non-goals

- **Hot reload / live tuning.** Explicitly out: values are inlined, so changing one is a rebuild. §4 covers why the door stays open and what it would cost to change our minds.
- **Per-entity or per-prefab overrides.** A workstation that builds faster than the global rate is prefab data (`prefabs/*.jsonc`), not a global constant. This RFC is for values that are global to a domain.
- **A settings / options system.** Player-facing toggles are runtime state that persists to disk. Unrelated machinery despite the surface similarity.
- **Full YAML.** §2 defines the supported subset. Anchors, aliases, multi-document streams, custom tags, and flow-style collections are rejected, not silently mishandled.
- **Units and dimensional analysis.** `build_time` is seconds because it is named so and commented so. Enforcing that in the type system is a much bigger idea (Open Question 4).

## Design

### 1. Directory convention

```
constants/
  construction.yaml
  decay.yaml
  combat.yaml
```

Flat, scanned like `scripts/` and `locales/`. Filename is the namespace; adding `economy.yaml` adds `C.economy.*` with nothing to register.

Packs use `packs/<name>/constants/*.yaml`, namespaced `<pack>__` exactly as pack components, scripts, prefabs, and locales already are — so `packs/combat/constants/ship.yaml` surfaces as `C.combat__ship.*`.

```yaml
# constants/construction.yaml
# How long a room takes to go from carcase to finished, in seconds.
build_time: 5.0
repair_time: 5.0
per_piece_time: 5.0
deconstruct_time: 4.0
```

Nesting is allowed one or more levels and maps onto the accessor path:

```yaml
# constants/decay.yaml
hunger:
  rate: 0.02          # need units per second
  yellow_threshold: 0.5
  red_threshold: 0.2
health:
  drain_rate: 0.0     # DISABLED — see CLAUDE.md §Needs System
```

→ `C.decay.hunger.rate`, `C.decay.health.drain_rate`.

### 1.1 The game takes precedence over the pack

Same rule as [RFC-I18N](./RFC-I18N.md) §2.1: a game overrides any of a pack's
constants, and the game wins. A `C.citizens__hunger.drain_rate` defined in the
game's `constants/` replaces the pack's.

No visibility gate — every pack constant is overridable. A gate would ask a pack
author to predict which values a game will want to tune, and each wrong guess
sends that game back to forking the pack or redefining the value somewhere else,
which is the drift this RFC exists to remove. The evidence in §Problem is
entirely of that shape: five construction timings across four files, `SHIP_SPEED`
defined twice, `health_drain_rate` stranded in a plugin's `config.zig`.

**The consequence, accepted deliberately: a pack's constant names are part of its
compatibility surface.** Once a game overrides `citizens__hunger.drain_rate`,
renaming it in the pack is a breaking change for that game. Packs already take
this bargain elsewhere — RFC-packs makes a pack's `name` save-stable because it
is the component prefix, so renaming a shipped pack is a save migration. Constant
names join that list.

**Every write under a pack's namespace is an override, and one that matches
nothing is an error.** Constants have no counterpart to i18n's *adding* case:
there is no second axis, so a value a pack does not define is simply the game's
own constant in the game's own namespace. That makes the rule here strictly
simpler than i18n's — no "unless it is a new locale" branch — and it is what
turns a pack renaming a constant in v2 into a build failure rather than a game's
tuning silently reverting to the pack's default.

In file form the rule follows from §1 — the filename is the namespace, and a
pack's namespace is `<pack>__<file>` — so the game overrides by carrying the
prefixed name as a filename:

```yaml
# constants/citizens__hunger.yaml — the game retuning the citizens pack
drain_rate: 0.015
```

The `__` filename is deliberate, not pretty. It keeps "filename is the
namespace" a single rule with no override-specific carve-out, and a directory
listing of `constants/` then shows exactly which packs this game has retuned.

An override must also keep the **scalar kind** it replaces: `5.0` stays `5.0`,
not `5`. Values are emitted untyped and coerce at the use site (§3), so an
int-for-float override can change behaviour without changing the number — the
same class of silent failure the strict scalar policy in §2 exists to prevent.

### 2. YAML subset, and strict scalars

YAML's implicit typing is the one real hazard in a constants file, and it is worth being blunt about because the failure is silent:

| Written | YAML 1.1 infers | What the author meant |
|---|---|---|
| `enabled: no` | boolean `false` | possibly the string `"no"` |
| `delay: 12:30` | sexagesimal `750` | `"12:30"` |
| `version: 1.20` | float `1.2` | `"1.20"` |
| `id: 0755` | octal `493` | `"0755"` |

So the parser runs a **strict scalar policy**: numbers must match an unambiguous numeric literal (`-?\d+` or `-?\d+\.\d+`, optional exponent), booleans must be exactly `true` or `false`, and anything else is a string. `no` / `yes` / `on` / `off` as bare scalars are a **build error** naming the file and line and telling the author to write `false` or `"no"` explicitly. Sexagesimal and octal are not recognised at all. This is a deliberate narrowing of YAML, and it makes the format safe for the job rather than merely familiar.

Supported: block mappings, nesting, scalars, comments. Rejected with a clear error: anchors (`&`/`*`), tags (`!!`), multi-doc (`---`), flow collections (`{a: 1}`), sequences (Open Question 3).

### 3. Comptime, via codegen — not a comptime YAML parser

"Comptime only" must not be read as `@embedFile` plus a comptime parse. YAML is far too large a grammar to parse pleasantly in Zig's comptime, and a comptime parser cannot call a C library.

The assembler does it instead, and it is the same move it already makes everywhere else:

```
constants/*.yaml  →  assembler (native code, any YAML library)  →  generated constants.zig  →  game imports
```

```zig
// generated — .labelle/<backend>_<platform>/constants.zig
pub const C = struct {
    pub const construction = struct {
        pub const build_time = 5.0;
        pub const deconstruct_time = 4.0;
    };
    pub const decay = struct {
        pub const hunger = struct { pub const rate = 0.02; };
    };
};
```

Three consequences worth stating:

1. **The YAML dependency is the assembler's, not the game's.** It is a build-time tool dependency; no parser is linked into the shipped binary and no `.yaml` file is shipped. That substantially defuses the "new dependency" cost of choosing YAML.
2. **Values are emitted untyped** — `comptime_int` / `comptime_float` — so they coerce at the use site to whatever it needs (`f32`, `f64`, `usize`, `u32`) with no annotations in the YAML and no cast at the call site. This is strictly more flexible than declaring types in the file, and precision or range problems surface as ordinary Zig compile errors where the value is used.
3. **`C.construction.buld_time` does not compile**, naming the missing declaration — goal 5, for free, because these are real Zig declarations.

### 4. On hot reload

Ruled out by the chosen tuning loop: inlined values cannot change without a rebuild. Edit → `labelle run` is the loop, and an incremental rebuild touching only the generated constants file is cheap.

The door is not closed, and it is worth recording the shape now so the decision can be revisited without an API break: a debug-only path could make `C.x.y` a function call reading a mutable table loaded from disk, while release keeps the inlined constant. Same call sites, same names. The cost is that debug and release stop sharing a code path for every constant read, which is exactly the kind of divergence that hides bugs — the reason not to do it by default.

### 5. Usage awareness

Mirroring [RFC-I18N](./RFC-I18N.md) §3.1: the assembler scans game and pack sources for `C.<path>` references and **warns on constants nothing reads**. A tuning value no code consumes is either dead or a symptom of a rename that missed a call site, and in a folder whose purpose is discoverability, stale entries are the main way it would rot.

Sound for the same reason it is sound there — the accessor path is the only way to name a constant, and it cannot be assembled from a runtime string.

### 6. Shared machinery with RFC-I18N

These two RFCs are the same shape: *scan a convention-named folder → generate nested namespaces of comptime-checked accessors → warn on entries nothing uses.* They should share one assembler pass — one directory scanner, one nested-namespace emitter, one `X.<path>` usage scanner parameterised by root symbol — rather than growing two near-identical implementations. Whichever lands first should be built with the second in mind.

They differ in two respects, and both are small enough to be parameters of the shared pass rather than reasons to fork it.

**Runtime selection.** Locales need a runtime-selectable table because the active language changes while the game runs; constants resolve to a single value at build time.

**Override versus add.** Both share the precedence rule — the game beats the pack (§1.1, RFC-I18N §2.1) — and the check that a write under a pack's namespace must match a key the pack defines. i18n needs one branch constants do not: a game may *add* a locale a pack never shipped, so a `<pack>__` key appearing in a locale file the pack has no counterpart for is legitimate. Constants have no second axis and therefore no such case, which makes the constants rule a strict subset of the i18n one. Build the general form once and let constants use the simpler half.

## Phasing

| Phase | Scope |
|---|---|
| 1 | `constants/` scan, strict-scalar YAML subset, codegen, `C.*` accessors |
| 2 | Usage-awareness warnings (§5), shared with RFC-I18N's scanner |
| 3 | Pack-scoped constants (`packs/<name>/constants/`, `<pack>__` namespacing), game override precedence and the must-exist check (§1.1) |
| 4 | Migrate FP's 38 existing constants, domain by domain |

Phase 4 is deliberately last and deliberately incremental. New tuning values go in `constants/` from phase 1; existing ones move when their domain is next touched. A big-bang migration of 17 files would be a large, untestable diff over gameplay-affecting values.

## Open questions

1. **Which YAML library?** The assembler has no YAML dependency today (checked). A pure-Zig parser keeps the toolchain dependency-free and cross-compiles trivially; libyaml through C is more battle-tested but adds a C dependency to a build tool. The strict subset in §2 is small enough that a hand-written parser is also credible — and would make the subset enforceable by construction rather than by post-validation.
2. **Do constants and prefab data overlap?** `build_time` as a global vs. a per-workstation override in `prefabs/*.jsonc`. Declared a non-goal here, but the boundary will be contested the first time a designer wants one fast-building room.
3. **Sequences.** Rejected in phase 1. But tiered values (`upgrade_costs: [10, 25, 60]`) are a natural fit and would generate a comptime array. Worth it, or does it invite structure that belongs in prefabs?
4. **Units.** `build_time: 5.0` is seconds by convention and comment only. A suffix convention (`_s`, `_px`, `_per_s`) is nearly free and self-documenting; a real unit type is not. Is the convention worth mandating?
5. **Cross-domain duplicate lint.** Should the assembler flag identical leaf names with differing values across domains — the `SHIP_SPEED` 280/150 case? It is legitimate there, so this would be a warning with a suppression, and it may be more noise than signal.
