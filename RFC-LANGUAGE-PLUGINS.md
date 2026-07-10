# RFC: Language Plugins — Lua, C#, Rust, and Ruby/Crystal as plugins

**Issue:** labelle-toolkit/labelle-engine#237 (updated 2026-07 — re-scoped from "Lua module" to the language-plugin family)  
**Status:** Draft  
**Author:** Alexandre  
**Date:** 2026-07-10 (rev 2 — POC validated: PR #734; rev 3 — single-repo packaging: `labelle-scripting` with language sub-modules)

## Problem

Game logic in labelle is Zig-only: scripts are `.zig` files auto-discovered by the assembler and compiled into the game, with a comptime API (`tick(game: anytype, dt)`, zero-cost hooks). That is the right default — but it forecloses four things #237 motivated in January and that still stand:

- **iteration speed** — tweak AI/rules/dialog without recompiling;
- **mod support** — user content in a sandbox;
- **accessibility** — non-Zig developers scripting games;
- **hot reload** — live editing in the dev loop.

#237 proposed a single `labelle-lua` plugin. Since then the ground shifted, and the scope grew: **Lua, C#, Rust, and Ruby/Crystal should each be a plugin** — riding the plugin model the toolkit now has, not a bespoke integration per language.

### What changed since #237 (and why it needs this update)

- **Scripts are auto-discovered, not scene-declared.** #237's `"lua:player_ai"` scene-list prefix predates convention discovery and the two-block execution order (root scripts, then plugin/pack scripts). Language scripts must ride the same conventions.
- **The plugin system matured into the attachable unit.** Plugin controllers (setup/tick/deinit, proven by the pathfinding v4 consolidation), `plugin.labelle` convention dirs, `MergeEngineHooks`, and the asset-plugins RFC (#725: plugins carry assets, packs, studio panels). A language runtime is the ultimate "full plugin."
- **The runtime component-access primitive now exists.** `editor_set_component` (`src/editor_api.zig:327`) applies a component **by name from JSON at runtime** over the serde-reflection registry — exactly the bridge primitive a foreign VM needs. In January this didn't exist.
- **labelle-studio exists.** Hot reload should integrate with the preview hot-push contract, and a language plugin can ship a studio panel (e.g. a script console) via the asset-plugins panel mechanism.
- `ScriptFns` (#237's adapter target) still exists (`src/root.zig:532`) — the scene-hook seam is real, but the primary seam is now the plugin controller.

## The crux: comptime engine, runtime languages

The engine API is comptime-parameterized — there is no stable ABI a VM can call. Every language integration therefore needs the same missing piece: a **versioned runtime contract** the engine exposes once, and every language plugin binds to. That contract is the core of this RFC; the languages are consumers.

## Two integration families

| Family | Languages | Mechanism | Scripts are | Hot reload | Sandbox |
|---|---|---|---|---|---|
| **Embedded VM** | Lua (ziglua / LuaJIT), Ruby (mruby), C# (CoreCLR hosting) | plugin embeds the interpreter/runtime | data (embedded at release, disk-watched in dev) | yes | per-VM (Lua easily, CLR partially) |
| **Native-compiled** | Rust, Crystal | game code compiles against the contract as `extern "C"`, linked by the plugin's build integration | code (compiled at build) | dev-only via dylib swap (optional) | no (native) |

WASM is a *third* possible mechanism unifying both (any language → wasm module in an embedded runtime, sandboxing for free) — treated in Alternatives; deliberately not the only path.

## Proposal

### 1. The Script Runtime Contract (engine-side, the one shared piece)

A small, versioned, C-ABI surface — the runtime mirror of how the pluggable-backends RFC carries comptime contracts in `labelle-platform-abi`:

```zig
// Conceptual v1 surface (C ABI; strings are ptr+len, payloads are JSON)
entity_create() -> u64            entity_destroy(id)
entity_find(name) -> u64          prefab_spawn(name, params_json) -> u64
component_get(id, name) -> json   component_set(id, name, json)
component_has(id, name) -> bool   component_remove(id, name)
query(names_json) -> ids_json     // view over component names
event_emit(name, payload_json)    event_poll(subscriber) -> json
input_key_down(key) -> bool       input_key_pressed(key) -> bool
input_mouse() -> x,y              time_dt() -> f32
scene_change(name)                log(level, msg)
```

- **Component encoding v1 = JSON**, riding the proven machinery: `component_set` generalizes `editor_set_component` (same serde-reflection dispatch, minus the editor gating); `component_get` is its read twin. A tagged-value binary encoding is a later optimization — the #237 performance framing stands (hot paths stay Zig; scripted logic tolerates the boundary).
- **Main-thread-only in v1.** Calls are valid during the plugin's tick.
- **Comptime-gated**: the contract surface compiles into the game **only when a language plugin is attached** — zero cost for every game that doesn't use one, like every other engine seam.
- Versioned like the editor contract; plugins declare the contract version they target.

**Validated by POC** (PR #734, `spike/language-plugins/`): the same behavior in Lua (VM family), Rust and Crystal (native family) against one flat C-ABI surface — including **both event directions** (emit + subscribe/poll-drain) — produces byte-identical world state, host-asserted. Findings folded in: Rust needs no bindings (the header *is* the binding); Crystal requires `Crystal.init_runtime` boot, `ld -r` main-localization, and **non-raising script entry points** (raise's backtrace capture segfaults across foreign stacks) — labelle-crystal's first work items; C#/hostfxr and mruby recipes documented in the spike README.

### 2. Packaging: ONE plugin repo, language sub-modules

All languages ship in a single first-party plugin repo — **`labelle-scripting`** — rather than one repo per language. The shared layer (contract binding, script discovery, hot-reload machinery, the plugin controller) dominates every language integration; one repo writes it once, and each language is a thin sub-module over it (the in-tree sub-package convention, applied to a plugin). One `.plugins` entry, one version train pinned to one contract version — no per-language compat matrix — and a game using two languages gets one controller with one deterministic tick order instead of two plugins with duplicated glue.

**Choosing languages costs nothing for the rest.** Selection is by convention with comptime gates: a game containing a `lua/` dir compiles the Lua VM in; no `rust/` dir means the Rust glue folds out entirely. Vendored runtimes ride `b.lazyDependency`, so an unchosen language's runtime is never even *fetched*. Per-language maturity is labeled per release (lua = stable first; csharp = experimental, last). Third parties can still ship independent language plugins over the public contract — `labelle-scripting` is the first-party bundle, not a monopoly.

Anatomy (shared once, per-language where noted):

1. **runtime**: each sub-module embeds or links its runtime (ziglua VM / mruby VM / CoreCLR host / nothing for Rust+Crystal), behind its comptime gate + lazy dependency;
2. **one plugin controller**: `setup` (init the enabled runtimes, load scripts), `tick` (run script updates — in the plugin block of the two-block order), `deinit`;
3. **script convention dirs** per language (`lua/`, `ruby/`, …) via `plugin.labelle` — the assembler **embeds** scripts (`@embedFile`) for release; dev builds disk-watch for hot reload;
4. **idiomatic bindings** per sub-module over the shared contract binding — #237's Lua API sketch (`game:findEntity`, `entity:get/set`, `input:isKeyDown`, `vec2`) kept verbatim as the reference design;
5. optionally a **studio panel** (asset-plugins RFC) — a script console / REPL panel is the natural v2.

### 3. Per-language notes (sub-modules of labelle-scripting)

- **lua** — the flagship (P1). Lua 5.4 via ziglua (~200 KB), LuaJIT as a build option (the #237 open question stands). Everything in #237's Phases 1–2 carries over; only the integration points change (convention dir instead of scene prefixes; plugin config instead of a `.lua` project block).
- **rust / crystal** — the native family. The contract ships as a C header; game Rust/Crystal code builds as a static lib the plugin's build integration links into the game binary. Full native performance, no VM, no sandbox; hot reload only as an optional dev-mode dylib swap. Crystal gives the Ruby-shaped syntax at native speed.
- **ruby** — **mruby**, not CRuby (CRuby is not designed for embedding). Embedded-VM family; smaller community than Lua but the same shape.
- **csharp** — the heaviest: CoreCLR hosting via `hostfxr`, desktop-first (Android/iOS AOT constraints are real — Godot's Mono history is the cautionary precedent). Explicitly last.

## Backward compatibility

- Zero impact when no language plugin is attached (comptime-gated contract).
- Zig scripts, flows, packs, and hooks are untouched; language scripts are additive and run in the plugin block of the existing order.
- #237's authored Lua API surface is preserved; only its integration points are replaced (scene `lua:` prefixes → convention discovery; `.lua` project block → plugin declaration).

## Phasing

- **Phase 1 — contract + labelle-scripting with Lua.** Script Runtime Contract v1 (JSON encoding, comptime-gated) in the engine; the `labelle-scripting` repo with the shared glue + the `lua` sub-module enabled: VM init, script loading from the convention dir (embedded), `init/update/deinit` per script, entity/component/input bindings. Proof: an FP-adjacent demo scene driven by a `.lua` behavior.
- **Phase 2 — dev experience.** Hot reload (disk watch + studio preview integration), Lua stack-trace error UX, the sandbox profile for mods (no `io`/`os` by default), script console studio panel.
- **Phase 3 — native family.** The `rust` (and `crystal`) sub-modules: C header generation from the contract, the **assembler build-integration hook** (plugins declaring "run cargo/crystal, link this artifact" — the one new assembler seam the native family needs), optional dev dylib swap. Decide WASM-vs-dylib here with real data.
- **Phase 4 — the long tail.** The `ruby` (mruby) and `csharp` (CoreCLR, desktop-first) sub-modules.

## Alternatives considered

1. **One WASM runtime instead of per-language plugins.** Strongest sandboxing story and one integration for N languages — but it taxes the native family (Rust/Crystal can link directly at zero cost), loses LuaJIT, and adds a heavyweight runtime dep to every consumer. Kept as a candidate mechanism for Phase 3 and for the mods story, not the architecture.
2. **Transpile-to-Zig at build time** (the flow-codegen precedent). Loses the two headline motivations — hot reload and mods — and flows already serve the visual/designer-authoring niche.
3. **Per-language bespoke integrations** (each language binds the comptime API directly). N×M explosion against every engine change; the whole point of the runtime contract is to pay the bridge cost once.
4. **CRuby instead of mruby.** CRuby embedding is fragile and GC-heavy; mruby exists precisely for this use case.
5. **One repo per language** (labelle-lua, labelle-rust, …). Rejected — the shared glue (contract binding, discovery, hot reload, controller) would be duplicated N times and drift; versions form an N×contract compat matrix; and multi-language games would attach N plugins with N controllers. The single `labelle-scripting` repo with comptime-gated, lazily-fetched sub-modules keeps unchosen languages at literal zero cost while cutting the repo count. Third-party language plugins over the public contract remain possible.

## Open questions

- **LuaJIT vs Lua 5.4** (carried from #237): ship 5.4 first, LuaJIT as an opt-in backend?
- **Encoding ceiling**: is JSON good enough for component-heavy scripts, or does v1 need the tagged-value ABI sooner? Measure on the Lua MVP.
- **GC in the frame budget**: Lua incremental GC and CLR GC pauses — per-tick step budgets?
- **Script-defined components**: can a Lua script register a *new* component type at runtime, or are components Zig-defined only (script data lives in a generic `ScriptData` component)? Leaning Zig-defined + generic bag for v1.
- **mruby vs Crystal priority** for the Ruby-shaped slot — they are different beasts (embedded-dynamic vs compiled-static); demand should pick.
