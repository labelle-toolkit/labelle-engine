# RFC: Language Plugins — Lua, C#, Rust, and Ruby/Crystal as plugins

**Issue:** labelle-toolkit/labelle-engine#237 (updated 2026-07 — re-scoped from "Lua module" to the language-plugin family)  
**Status:** Draft  
**Author:** Alexandre  
**Date:** 2026-07-10 (rev 2 — POC validated: PR #734; rev 3 — single-repo packaging: `labelle-scripting` with language sub-modules; rev 4 — reference bindings: Lua queries, Ruby events; rev 5 — Ruby controllers: script-language domain owners; rev 6 — script-declared components: generate-time codegen, runtime tier for mods; rev 7 — native declaration idioms per language; rev 8 — policy: one language per project, enforced at generate; rev 9 — policy rationale: role-based, pack/mod carve-outs)

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

All languages ship in a single first-party plugin repo — **`labelle-scripting`** — rather than one repo per language. The shared layer (contract binding, script discovery, hot-reload machinery, the plugin controller) dominates every language integration; one repo writes it once, and each language is a thin sub-module over it (the in-tree sub-package convention, applied to a plugin). One `.plugins` entry, one version train pinned to one contract version — no per-language compat matrix — and should the one-language-per-project policy (below) ever be lifted, multi-language games get one controller with one deterministic tick order instead of N plugins with duplicated glue.

**Policy: one language per project** (rev 8). The plugin declaration carries a **singular** `.language = "lua"` field — mixing is unrepresentable in config. Enforcement is layered:

- **Generate-time validation**: the assembler scans every script convention dir — game root *and* pack-bundled — and errors (file list included) on any script outside the declared language. Content packs/plugins that bundle scripts declare `requires_language = "…"` in their manifest (symmetric with `depends_on_resources`), validated on attach, so a Lua-scripted pack fails loudly in a Rust project.
- **Comptime**: only the declared sub-module compiles; `b.lazyDependency` means other runtimes are never fetched, built, or linked — the binary physically contains one language runtime. Dir-presence detection remains as a cross-check, not the selector.
- **Why the ban is right for the game's own scripts**: the legitimate "iteration layer + native layer" architecture already exists in every project as **Zig + script** — Zig is the engine language, always present as the performance escape hatch. `labelle-rust` serves Rust-preferring teams as their *primary*, not as a sidecar to Lua. With that objection defused, the ban is pure upside: one hiring/reading/debugging story, one GC in the frame budget, no cross-VM event spaghetti.
- **Carve-outs (by role, not by exception)**:
  - *Content packs*: v1 enforces `requires_language` matching (strict). The documented follow-up — when the first scripted pack exists — is exempting **pack-internal scripts** (the pack's language sub-module enables scoped to that pack): a pack's language is an implementation detail the game author never reads, and project-wide enforcement would fragment the pack market by language, against the asset-plugins marketplace vision (#725). Cost stated honestly: a second VM in the binary, paid only by choosing that pack, surfaced by `labelle plugins`.
  - *Mods*: the mod sandbox runtime (Lua or WASM) is orthogonal to `.language` — a Rust-scripted game with Lua mods is legal by construction; `.language` governs authoring, never the sandbox.
- **Review triggers**: widen to a plural field on real multi-language demand; enable the pack exemption on marketplace demand. Both are additive — the shared glue supports N by construction; the ban is policy in the schema, not architecture.

Per-language maturity is labeled per release (lua = stable first; csharp = experimental, last). Third parties can still ship independent language plugins over the public contract — `labelle-scripting` is the first-party bundle, not a monopoly.

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

### 4. Reference bindings: what the sugar looks like

The ABI stays minimal (one `query` function, subscribe+poll for events); everything idiomatic is per-language sugar. Two worked references pin the style.

**Queries in Lua** — FP's cloud-drift loop as a script:

```lua
function update(dt)
    for e in game:query("CloudDrift", "Position") do
        local drift = e:get("CloudDrift")
        local pos   = e:get("Position")
        pos.x = pos.x + drift.speed * dt
        if pos.x >= drift.tile_width then pos.x = pos.x - 2 * drift.tile_width end
        e:set("Position", pos)
    end
end
-- filters:  for e in game:query("Enemy", "Position"):without("Dead") do … end
```

- Maps to one contract call: `labelle_query(names_json) -> ids_json` (engine resolves names via the comptime component registry, runs a normal ECS view). The generic-for iterator, `Entity` handles, and JSON⇄table marshaling live in the lua sub-module.
- **Snapshot semantics**: the id list is captured at query time — spawn/destroy inside the loop is safe; `e:get` on a destroyed entity returns `nil`. Main-thread, during the plugin tick.
- **Cost model**: each `get`/`set` is one FFI crossing + JSON codec — fine at game-logic scale; hot paths stay Zig. A batched v2 escape hatch (`game:each(names, fn)` — one crossing fetches all rows, dirty rows write back in one call) is reserved for when profiling demands it.

**Events in Ruby (mruby)** — blocks over the drain loop:

```ruby
def init
  @turret = Labelle.entity_create
  Labelle.set(@turret, "Position", x: 100, y: 50)

  Labelle.on("combat__fight_started") do |ev|
    @armed = true
    Labelle.log "turret arming against raid #{ev[:raid_id]}"
  end

  Labelle.on("pathfinder__arrived") do |ev|
    fire_at(ev[:entity]) if @armed
  end
end
```

- `Labelle.on` subscribes (once per name) via `labelle_event_subscribe` and registers the block; the shared controller **drains the inbox before each `update`** and dispatches to blocks with the JSON payload parsed to a symbol-keyed Hash. `Labelle.emit("turret__fired", turret: @turret)` is the symmetric kwargs→JSON emit. The ABI never grows callbacks — blocks are dispatcher sugar, identical in shape to Lua handler tables and C# events.
- **mruby embedding rules** (the ruby sub-module's homework): wrap every dispatch in `mrb_protect` so a script exception is logged, not fatal to the tick — mruby exceptions are VM-internal and safe, unlike Crystal's cross-foreign raise (POC finding); and save/restore the **GC arena** (`mrb_gc_arena_save/restore`) around each tick's dispatch, the classic mruby-embedding overflow guard. Payload parsing uses a vendored JSON mrbgem.

**Controllers in Ruby** — script-language *domain owners*, not just leaf behaviors. Subclassing registers (Ruby's `inherited` hook — convention over config); the file's numeric prefix orders ticks:

```ruby
# ruby/controllers/10_hunger_controller.rb
class HungerController < Labelle::Controller
  def setup
    on "hunger__feed" { |ev| feed(ev[:entity], ev[:amount] || 0.5) }  # command-as-event
  end

  def tick(dt)
    each("Hunger", "Worker") do |e|
      h = e.get("Hunger")
      h[:level] -= 0.02 * dt
      h[:level] <= 0 ? (emit "hunger__starved", entity: e.id) : e.set("Hunger", h)
    end
  end

  def feed(id, amount) … end   # same-VM public API for other Ruby scripts
  def teardown … end
end
```

- **Lifecycle mapping**: the shared plugin controller's `setup` instantiates registered classes in file order and calls `setup` (subscriptions land there); `tick` drains the inbox, dispatches event blocks, then ticks each controller in order; `deinit` runs `teardown` in reverse. All under `mrb_protect` + arena guards. The ABI is unchanged — controllers are dispatcher structure, not contract surface.
- **Cross-language API = commands-as-events + components-as-state** (the pathfinder-v4 triad, minus direct calls): any language "calls" a Ruby controller by emitting its command event; the controller answers via events and component writes. Direct cross-language function calls are deliberately not in v1 — the bus is the boundary. Same-language callers use plain method calls.
- **Authoritative state lives in components; ivars are caches.** The VM is transient — save/load rehydration and hot reload reset it (the FP plugin-State lesson). Keeping durable state in engine-serialized components makes script controllers save-safe and hot-reloadable for free.

**Components declared in script languages** — first-class via generate-time codegen:

```ruby
# ruby/components/hunger.rb
class Hunger < Labelle::Component
  field :level,    :f32,  default: 1.0
  field :starving, :bool, default: false
  persist :persistent          # Saveable bucket, same vocabulary as Zig components
end
```

Components are comptime Zig types (typed ECS storage, reflection registry, save/load, scene instantiation) — a VM cannot conjure one at runtime. So the declaration is consumed at **`labelle generate`**: the sub-module ships a *declare-mode runner* (the vendored VM loads `ruby/**/*.rb` under a stub `Labelle` that records `field`/`persist` and dumps JSON — Ruby introspects itself, no Ruby parser in the assembler), and the assembler **codegens a real Zig component struct** into the normal registry (pack-namespaced when the `ruby/` dir lives in a pack). Everything then works with zero special cases: scenes/prefabs (`"Hunger": {"level": 0.8}`), save/load with the declared bucket, cross-language name access, typed queries, and boundary validation (`e.set(Hunger, h)` checks the schema → script errors instead of silent drift).

Two tiers, one DSL:

- **Tier 1 — game developers (v1)**: declaration → generate-time codegen → first-class component. The schema lives in Ruby, the type lives in Zig, nothing is written twice.
- **Tier 2 — mods (later)**: the same class registers at **runtime** into a dynamic component store (JSON-typed, generic serde) — modders cannot run `labelle generate`. Dynamic components stay invisible to comptime Zig systems, which is acceptable for sandboxed mod content.

**Native idioms per language, one schema underneath.** The `field` DSL is the explicit form; every language also declares in its own native shape, and the declare-mode extraction produces the same schema JSON:

- **Ruby terse form**: `Hunger = Labelle.component(level: 1.0, starving: false)` — types inferred from the default literals (`1.0`→f32, `0`→i32, `false`→bool, `""`→str, `{x:,y:}`→vec2); the class DSL remains for what inference can't express (`:entity`, enums, width control, `persist :transient`). Instances are **Struct-backed** with attribute accessors (`h.level -= …; e.set(h)`) — `mruby-struct` is in the standard gem set; `Data.define` is not in mruby and its immutability fights the get→mutate→set flow.
- **Lua**: `labelle.component("Hunger", { level = 1.0, starving = false })` — table form, same inference.
- **Rust**: `#[labelle::component] struct Hunger { level: f32, starving: bool }` — the proc-macro emits schema JSON at build; the type system is the DSL.
- **Crystal**: annotated struct, schema dumped by a declare-mode compile (same runner pattern as Ruby).
- **C#**: `[LabelleComponent] record Hunger(float Level, bool Starving);`

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
- ~~**Script-defined components**~~ — resolved (rev 6): generate-time codegen from the script DSL makes them first-class for developers; a runtime dynamic-store tier covers mods later.
- **mruby vs Crystal priority** for the Ruby-shaped slot — they are different beasts (embedded-dynamic vs compiled-static); demand should pick.
