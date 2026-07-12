# RFC: Language Plugins — Lua, C#, Rust, and Ruby/Crystal as plugins

**Issue:** labelle-toolkit/labelle-engine#237 (updated 2026-07 — re-scoped from "Lua module" to the language-plugin family)  
**Status:** Draft  
**Author:** Alexandre  
**Date:** 2026-07-10 (rev 2 — POC validated: PR #734; rev 3 — single-repo packaging: `labelle-scripting` with language sub-modules; rev 4 — reference bindings: Lua queries, Ruby events; rev 5 — Ruby controllers: script-language domain owners; rev 6 — script-declared components: generate-time codegen, runtime tier for mods; rev 7 — native declaration idioms per language; rev 8 — policy: one language per project, enforced at generate; rev 9 — policy rationale: role-based, pack/mod carve-outs; rev 10 — Zig plugins in script-language projects; rev 11 — script-language packs; rev 12 — TypeScript (QuickJS) and Go (c-archive) join the families; rev 13 — language rides generic plugin params; rev 14 — per-frame allocation idioms: FrameArray, into: reuse; rev 15 — idioms generalized per language; rev 16 — the 2026-07-12 product decisions: purity mandate (100% selected-language games), convention dirs shipped (scripts/, components/, events/), the declare contract as the language-neutral seam, the language-agnostic assembler (capability rows))

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
| **Embedded VM** | Lua (ziglua / LuaJIT), **TypeScript (QuickJS)**, Ruby (mruby), C# (CoreCLR hosting) | plugin embeds the interpreter/runtime | data (embedded at release, disk-watched in dev) | yes | per-VM (Lua & QuickJS easily, CLR partially) |
| **Native-compiled** | Rust, Crystal, **Go (c-archive)** | game code compiles against the contract as `extern "C"`, linked by the plugin's build integration | code (compiled at build) | dev-only via dylib swap (optional) | no (native) |

WASM is a *third* possible mechanism unifying both (any language → wasm module in an embedded runtime, sandboxing for free) — treated in Alternatives; deliberately not the only path.

## The purity mandate: 100% selected-language (rev 16)

**Product decision (2026-07-12, #237): every shipped language must be able to go 100% selected-language — no Zig at all.** A ruby game is `scripts/*.rb` + `components/*.rb` + `events/*.rb` + scenes (data) + `project.labelle` (config); the same sentence must hold for every language the plugin ships. Native `hooks/*.zig` remain the **optional** escape hatch — a capability, not a requirement.

Why a mandate and not a nice-to-have: the accessibility motivation is only real if the language stands alone — a "ruby game" that needs one `.zig` file for a custom event has a Zig prerequisite in its onboarding path, and the audience the language was added for is exactly the audience that trips there. The mandate also keeps the two-layer architecture honest from the other side: Zig is the *performance* layer, opted into for hot paths — never the tax for finishing a game.

Consequences:

- **Completeness is measured per kind**: everything a game must author — behavior, component declarations, event declarations — must be authorable in the selected language. Engine builtin events already need no declaration; the last gap was custom events, closed by #772.
- **CI enforces it structurally**: each example game carries a *purity variant* — a scratch copy with `hooks/` deleted must generate, build, and run green. "Hooks are optional" stops being a claim and becomes a gate.
- **The escape hatch stays load-bearing**: nothing here removes native hooks — the plugin-interop story (proposal 5) and the performance framing are unchanged. The mandate fixes the *floor* (zero Zig must work), not the ceiling.

Status against the bar: **lua / ruby** close with #772 (components shipped, assembler v0.86.0; events in flight, v0.87.0); **typescript** → #773 (a declare runner over the already-pinned tsc + the already-vendored QuickJS — the cheap close, and the `.d.ts` loop closes on itself: a component declared in TS comes back to every script as typed `Entity.get/set`); **rust** → #774 (`labelle::component!`/`event!` macros + extraction, probe-vs-parser decided on the ticket — the typed-struct expansion is the prize *beyond* parity); **crystal** → #775 (follows rust's extraction decision, so both native lanes share one design).

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

**Policy: one language per project** (rev 8; declaration shape revised rev 13). The language is declared through the **generic plugin-parameters mechanism** — `.params = .{ .language = "lua" }` on the plugin entry — rather than a bespoke `PluginDep` field. Plugin-specific options must never grow the assembler's config schema: `.params` is a per-plugin bag validated against a schema the plugin declares in `plugin.labelle` (shipped: the manifest's `params_schema` declares the vocabulary — exactly the implemented languages, test-pinned against the `Language` enum — and the assembler validates at generate since v0.83.0, labelle-assembler#591). The parameter is **singular** — mixing stays unrepresentable. Enforcement is layered:

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
3. **the Zig convention dirs, extension-keyed** (revised rev 16 — `scripts/` + `components/` SHIPPED in assembler v0.86.0, `events/` lands in v0.87.0): script-language files live in the SAME structure a Zig game uses — not per-language dirs (`lua/`, `ruby/`, …), not a new name. Files live where their **kind** lives: behavior in `scripts/` (`scripts/hunger.rb` sits exactly where `scripts/hunger.zig` would; numeric ordering prefixes order registration; Zig and script files coexist in one dir — the two-layer architecture in one structure), component declarations in `components/*.<ext>`, event declarations in `events/*.<ext>`. The extension selects the language; registration order is pinned **components → events → scripts**, so declared constants exist when scripts load. The assembler **embeds** (`@embedFile`) for release; dev builds disk-watch for hot reload. The rev-2..15 per-language dirs got one release of grace with a pointed note, then examples and docs migrated;
4. **idiomatic bindings** per sub-module over the shared contract binding — #237's Lua API sketch (`game:findEntity`, `entity:get/set`, `input:isKeyDown`, `vec2`) kept verbatim as the reference design;
5. optionally a **studio panel** (asset-plugins RFC) — a script console / REPL panel is the natural v2.

### 3. Per-language notes (sub-modules of labelle-scripting)

- **lua** — the flagship (P1) — **SHIPPED**. Lua 5.4 via ziglua (~200 KB), LuaJIT as a build option (the #237 open question stands). Everything in #237's Phases 1–2 carried over; only the integration points changed (convention dir instead of scene prefixes; plugin config instead of a `.lua` project block).
- **rust / crystal** — the native family — **SHIPPED**. The contract ships as a C header; game code lives in `scripts/` under a native module root (`scripts/mod.rs` / `scripts/game.cr`) and builds via the manifest's `.language_builds` steps — cargo emits a static lib, crystal a main-localized object (the POC's `ld -r` recipe) — linked into the game binary. Full native performance, no VM, no sandbox; hot reload only as an optional dev-mode dylib swap. Crystal gives the Ruby-shaped syntax at native speed. Declarations close the purity bar: #774 (rust), #775 (crystal).
- **ruby** — **mruby**, not CRuby (CRuby is not designed for embedding) — **SHIPPED**. Embedded-VM family; smaller community than Lua but the same shape.
- **typescript** — **QuickJS** (the Lua of JS: small, embeddable, no JIT, sandboxes well — a strong mods candidate) — **SHIPPED**, with the **TS→JS transpile at generate** running on the pinned tsc 7 toolchain (#745/#613 — platform-package pins with hashes; the one trust exception in proposal 7), not esbuild as revs 12–15 sketched. The largest-audience accessibility play, and the best-typed DX of the VM family: **`.d.ts` files are codegen'd from the component schemas + contract**, so scripts get real autocomplete; declare-mode rides the same prelude pattern as lua/ruby (#773: a quickjs declare host evaluating the transpiled declaration files), and the loop closes on itself — a TS-declared component comes back to every script typed.
- **go** — demand-driven (#746), unshipped. Feasible via `-buildmode=c-archive` (cgo `//export` entries over the contract header), with honest caveats: Go brings its **own runtime as a guest** (scheduler, GC, signal handlers — coexistence needs explicit cgo configuration), +2–8 MB binary, goroutines vs the main-thread-only contract (guard rails), and cgo cross-compilation pain on mobile. The awkward middle of the native family; behind rust/crystal.
- **csharp** — the heaviest: CoreCLR hosting via `hostfxr`, desktop-first (Android/iOS AOT constraints are real — Godot's Mono history is the cautionary precedent). Explicitly last — **in flight** (#743, its own workstream; the manifest already carries its vocabulary row and `dotnet publish` step).

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

**Per-frame allocation idioms (Ruby/Lua)** — Zig's `clearRetainingCapacity` pattern, ported deliberately because the naive port silently fails: **mruby's `Array#clear` frees the heap buffer** (resets to the embedded representation — unlike CRuby, which retains), so per-frame scratch arrays cleared with `.clear` reallocate every tick inside the GC arena. The ruby prelude therefore ships the idiom as a utility:

- `Labelle::FrameArray.new(cap)` — preallocated backing + logical length; `<<` is in-bounds index assignment (never reallocates), `clear` is `len = 0`, growth is deliberate. `clearRetainingCapacity` by construction.
- `e.get(Hunger, into: @cached)` — refills a setup-allocated Struct instance instead of materializing a new one per read: the same reuse idea applied to the component boundary, where the real per-frame garbage comes from. With the per-tick `mrb_gc_arena_save/restore`, a hot script's steady state allocates nothing.
- **Per-language matrix** (the need is universal; who provides it varies):

| language | scratch-clear idiom | shipped by us | GC discipline (plugin-owned) |
|---|---|---|---|
| Ruby (mruby) | `Array#clear` **frees** — trap | `Labelle::FrameArray` + `into:` | GC arena save/restore per tick |
| Lua 5.4 | no `table.clear` builtin | prelude FrameArray (logical `n`) + `e:get(name, into)` | `lua_gc(LUA_GCSTEP)` per-tick budget |
| TypeScript (QuickJS) | `length = 0` is engine-internal — don't rely | prelude FrameArray + `into:`; **typed arrays** (reused `Float64Array`) = true zero-alloc numeric scratch | refcount+cycle GC — smooth by nature |
| Go | **native**: `s = s[:0]`, `sync.Pool` | nothing — wrapper layer reuses marshal buffers internally | guest Go GC, background |
| Rust / Crystal / Zig | native (`Vec::clear` etc.) | nothing | n/a |

The unifying rule: the real per-frame allocator in every VM language is **the boundary** (each get/decode materializes objects) — so `into:`-reuse and a FrameArray are standard prelude equipment for the whole VM family, not per-language afterthoughts.

**Controllers in Ruby** — script-language *domain owners*, not just leaf behaviors. Subclassing registers (Ruby's `inherited` hook — convention over config); the file's numeric prefix orders ticks:

```ruby
# scripts/10_hunger_controller.rb
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

**Components and events declared in script languages** — first-class via generate-time codegen (components **SHIPPED**, assembler v0.86.0; events land in v0.87.0 — #772):

```ruby
# components/hunger.rb — beside components/worker.zig
Hunger = Labelle.component "Hunger", level: 0.875, starving: false

# events/hunger__feed.rb — one line, any number of consumers
HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5
```

Components are comptime Zig types (typed ECS storage, reflection registry, save/load, scene instantiation) and custom events are comptime union rows — a VM cannot conjure either at runtime. So declarations are consumed at **`labelle generate`**: the sub-module ships a *declare-mode runner* (the vendored VM loads `components/*.<ext>` and `events/*.<ext>` — plus in-script chunk-scope declarations, legal for compatibility — under a declare prelude that records declarations and dumps schema JSON; the language introspects itself, no ruby/lua parser in the assembler), and the assembler **codegens real Zig** into the normal paths (pack-namespaced when the declaring dir lives in a pack). Everything then works with zero special cases: scenes/prefabs (`"Hunger": {"level": 0.8}`), save/load with the declared bucket, cross-language name access, typed queries, boundary validation (`e.set(Hunger, h)` checks the schema → script errors instead of silent drift) — and a declared event's union row comes out byte-identical to a Zig-authored one.

**The declare contract (rev 16) — THE language-neutral seam.** One schema JSON from any declare tool:

```json
{ "components": [ { "name": "Hunger", "persist": "persistent",
                    "fields": [ { "name": "level", "type": "f32", "default": 0.875 } ] } ],
  "events":     [ { "name": "hunger__feed",
                    "fields": [ { "name": "entity", "type": "u64", "default": 0 } ] } ] }
```

- **Type vocabulary**: `f32` / `bool` / `i32` / `vec2` / `str` / `u64` — the last via the **`Labelle.id`** sentinel (event payloads carry entity ids; ids default to `0`; deliberately no value constructor in v1 — `Labelle.id` classifies, it does not wrap). Legal in component fields too. `"events"` is emitted **only when non-empty**, and events carry no `persist` (they aren't saved) — old assemblers read only `"components"` from the JSON Value tree, so the key was compat-safe by construction.
- **Byte-parity is pinned by cross-runner goldens**: every declare tool must emit byte-identical JSON for the same declarations (alphabetized fields, shared field caps, one drift pin across the tools). The golden is the proof that downstream is producer-agnostic — the property proposal 7 builds on.
- **Downstream never knows the producer**: components codegen into the registry as `scripting_components.zig`; events materialize as **one generated `scripting_events.zig`** whose union rows import it inline. One file rather than per-event staged `events/*.zig` for a load-bearing reason: staged convention dirs are **whole-directory symlinks** into the game tree, so per-event materialization would write through into the game's sources. Documented consequence: a native hook consuming a *declared* event spells its payload param `anytype` (the dispatcher never inspects param types; Zig-authored events keep their typed imports).
- **Runtime halves in the same file**: the declaration file also **embeds and evaluates** at runtime — `Labelle.component` returns the view class, `Labelle.event` the frozen name string — so the declared constant feeds `get`/`set`/`emit`/`on` directly, and the pinned components → events → scripts order guarantees the constants exist when scripts load.

Two tiers, one DSL:

- **Tier 1 — game developers (v1)**: declaration → generate-time codegen → first-class component. The schema lives in the script language, the type lives in Zig, nothing is written twice.
- **Tier 2 — mods (later)**: the same declaration registers at **runtime** into a dynamic component store (JSON-typed, generic serde) — modders cannot run `labelle generate`. Dynamic components stay invisible to comptime Zig systems, which is acceptable for sandboxed mod content.

**Native idioms per language, one schema underneath.** The terse form above is canonical; every language declares in its own native shape, and the declare extraction produces the same schema JSON:

- **Ruby**: types inferred from the default literals (`1.0`→f32, `0`→i32, `false`→bool, `""`→str, `{x:,y:}`→vec2, `Labelle.id`→u64); the class DSL (`field :level, :f32, default: 1.0`, `persist :transient`) remains for what inference can't express (enums, width control, non-default persistence). Instances are **Struct-backed** with attribute accessors (`h.level -= …; e.set(h)`) — `mruby-struct` is in the standard gem set; `Data.define` is not in mruby and its immutability fights the get→mutate→set flow.
- **Lua**: `labelle.component("Hunger", { level = 1.0, starving = false })` — table form, same inference; `labelle.event` symmetric.
- **TypeScript (#773)**: `export const Hunger = Labelle.component("Hunger", { level: 0.875, starving: false })` — evaluated by a quickjs declare host after the pinned-tsc transpile; joins the cross-runner golden.
- **Rust (#774)**: `labelle::component! { Hunger { level: f32 = 0.875, starving: bool = false } }` + `labelle::event! { … }` — extraction is the ticket's decision: a compile-and-run probe under `cfg(feature = "declare")` with a persistent target-dir cache (recommended — the real compiler evaluates, and cargo is already required at build), vs a constrained literal-only grammar (zero toolchain at generate, grammar-drift risk). The same macro expands at build into a **real typed struct** over the ABI — typed component access is the prize beyond parity, and layout-parity by construction opens a later zero-serialization path for hot events.
- **Crystal (#775)**: the rust twin (macros/DSL + probe with persistent cache — compiler speed makes the cache load-bearing), landing after rust's extraction decision settles so both native lanes share one design.
- **C# (#743)**: `[LabelleComponent] record Hunger(float Level, bool Starving);`

### 5. Zig plugins in script-language projects

A "C# project" is still a **Zig binary whose scripts are C#** — the assembler generates `main.zig`, and every Zig plugin (pathfinding, fsm, imgui) compiles in unchanged: comptime hooks, controllers, zero-cost gates, full native speed. The CLR/VM is a guest. Interop is the pathfinder-triad, crossed once:

- **Events — free by construction**: plugin events ride `GameEvents`; the contract's subscribe/poll drains the same bus. `Labelle.On("pathfinder__arrived", ev => …)`.
- **Components — free by construction**: plugin components live in the shared registry; scripts read/write them by name like any component.
- **Commands/queries — one seam, already designed once**: comptime calls (`pathfinder.Controller.navigate(game, …)`) are unreachable from a VM, so the contract adds `labelle_plugin_call(plugin, command, params_json) → json` — dispatched through the **same named-handler registry as `_editor_plugin_command`** (asset-plugins Phase 3, engine#729). A plugin registers its handlers once (~20 lines: parse params → call its own Controller) and becomes reachable from **studio panels and every scripting language simultaneously**. `Labelle.Command("pathfinder", "navigate", new { entity, x, y })`.
- **Typed wrappers (polish tier)**: the handler manifest is introspectable, so `labelle generate` can emit per-language typed wrappers (`Pathfinder.Navigate(worker, 340, 186)`) — the component declare-mode codegen run in reverse.

The performance framing is the architecture's best case: heavy machinery (graph, walkers, arrival detection) runs at full Zig speed inside the plugin; the script pays the JSON boundary only at orchestration points. Hot paths stay native — with plugins as the hot path.

### 6. Script-language packs

Packs can be authored in a script language — `packs/dungeon/` with language-neutral `prefabs/` + `assets/` (asset-plugins #725) and the same extension-keyed convention dirs a game root uses (rev 16): the pack's controllers in `scripts/*.rb`, its declarations in `components/*.rb` and `events/*.rb`. Composition of pinned decisions:

- **Components**: the declare-mode extraction already handles pack-nested declaration files — codegen'd Zig components arrive **pack-namespaced** (`dungeon__Room`); scenes, save buckets, and cross-language access identical to Zig-pack components.
- **Controllers**: loaded into the existing two-block order — pack controllers tick in their pack's slot (project plugin order between packs, file prefix within).
- **Policy**: the pack declares `requires_language = "ruby"` (v1 installs into matching projects); the rev-9 pack-language exemption is what later lets a script-language pack install anywhere, scoped to its own VM.
- **New work item — event names**: the invisible bare→`pack__*` event rewrite is AST-level and does not translate safely to dynamic script strings. v1 rule: script-language pack code writes **namespaced event names explicitly**, with generate-time validation that emitted/subscribed names resolve.
- **Crystal packs** inherit the native-family caveats: consumer toolchain, the `.language_builds` build steps, and the POC's non-raising-entry rules (a validator lint candidate).

This completes the vendor story: a full content pack — atlases, prefabs, a generator controller, a studio panel — with **zero Zig**, sellable as one plugin. Zig remains the floor (engine, plugins, hot paths), not the entry fee.

### 7. The language-agnostic assembler (rev 16)

> "in the future languages like python can be added without touching the assembler, just the labelle-script" — the user directive, verbatim.

Shipping five languages left per-language knowledge smeared across the assembler as built-in tables: the `DECLARE_RUNNERS` rows (declare tool step name, tool dir, extension, capability pins), the native-language splice rows (`NATIVE_LANGUAGES` wiring — which game dir stages over which module root), and the TS transpile phase's toolchain pins. Every row is data the assembler *consumes* but labelle-scripting *owns* — the same inversion the pluggable-backends RFC (labelle-assembler#378) applies to render backends, and rev 13's own rule ("plugin-specific options must never grow the assembler's config schema") applied to the assembler's internals instead of its config. The design: those tables migrate to **language capability rows in labelle-scripting's `plugin.labelle`**, and the assembler becomes a generic executor of rows.

A row carries everything the assembler knows per language today: name, extension(s), family (`embedded` | `native`), the native module root (`mod.rs` / `game.cr`), the declare capability (tool step name + tool dir; the presence of an `.events` sub-capability is what "supports declared events" *means*), transpile needs (emitted extension + toolchain requirement), and the runtime embed wiring. Sketch, spelling aligned with the manifest's existing `params_schema` / `language_builds`:

```zig
.languages = .{
    .{ .name = "ruby", .extensions = .{"rb"}, .kind = .embedded,
       .declare = .{ .tool = "labelle-declare-ruby", .dir = "tools/declare-ruby",
                     .events = true } },       // .events present ⇒ declared events supported
    .{ .name = "rust", .extensions = .{"rs"}, .kind = .native,
       .module_root = "mod.rs" },              // scripts/mod.rs; build steps stay in .language_builds
    .{ .name = "typescript", .extensions = .{"ts"}, .kind = .embedded,
       .transpile = .{ .emits = "js", .toolchain = "tsc" },
       .declare = .{ .tool = "labelle-declare-ts", .dir = "tools/declare-ts", .events = true } },
},
```

- **Self-describing capabilities replace min-pin tables.** Today the assembler carries `min_pin`/`events_min_pin` per runner row — a version compare against knowledge that lives in another repo, and a table that must grow every time labelle-scripting does. Under capability rows the check inverts: the **resolved pin's own manifest** declares what it supports. `events/*.rb` under an old pin fails because *that manifest's* ruby row lacks the `.events` capability — a pointed error naming the pin — with no version compare in the assembler at all. (The v0.85.0 forward-compat rule generalizes: only the *selected* language's row validates strictly; non-selected rows tolerate unknown keys, so a new capability never breaks bystander projects.)
- **Trust model — nothing new.** Plugin-declared tool builds and fetches already execute at generate: the declare tools, `.language_builds` steps, build hooks. Capability rows add no new trust; they relocate existing knowledge from assembler tables into the manifest of the package that owns it. The ONE deliberate exception to full agnosticism: **third-party toolchain fetch pins** (the tsc platform-package sha512 hashes). Two options: (a) they stay assembler-owned as a supply-chain control point — the assembler decides what third-party code generate may fetch; (b) they move to the manifest with the assembler **enforcing hash presence** and doing the verifying. Recommended: **(b), manifest-with-mandatory-hashes** — agnosticism with integrity: labelle-scripting declares *what* to fetch and its exact hashes, the assembler refuses hash-less toolchain rows and still verifies every byte.
- **Honest boundary.** Typed-binding sidecar generation — the `labelle-components.d.ts` built from the registry — is assembler *codegen keyed to a language*, not table-lookup wiring. v1 agnosticism deliberately scopes to collection, declare, embed, and native wiring; binding codegen stays a **named extension point** (future: template-driven, plugin-supplied templates), not a silent gap.
- **Migration.** The assembler's built-in tables become **fallback defaults** for manifests predating `.languages` rows — resolved pins of today's releases keep working unchanged. New languages MUST come via manifest; the built-ins are frozen, never extended again.

The litmus test this section must pass: **adding python = a labelle-scripting PR** — `src/python/` VM embed + `tools/declare-py` + a `.languages` row — **zero assembler changes**.

## Backward compatibility

- Zero impact when no language plugin is attached (comptime-gated contract).
- Zig scripts, flows, packs, and hooks are untouched; language scripts are additive and run in the plugin block of the existing order.
- #237's authored Lua API surface is preserved; only its integration points are replaced (scene `lua:` prefixes → convention discovery; `.lua` project block → plugin declaration).
- The convention-dir move (rev 16) shipped with one release of grace: legacy per-language dirs kept working with a pointed note; examples and docs migrated the same release, and examples CI fails if the deprecation note ever reappears.
- The declare schema grows without breaking old assemblers: `"events"` is emitted only when non-empty, and old assemblers read only `"components"` from the JSON Value tree. Capability rows (proposal 7) keep the property — only the selected language's row validates strictly.

## Phasing and status

Status at rev 16 (2026-07-12): **five languages live** — lua, ruby, typescript, rust, crystal — one runtime each behind the singular `.language` param (labelle-scripting builds and tests every sub-module per `-Dlanguage`); **csharp in flight** (#743, its own workstream); **go demand-driven** (#746). Version markers: labelle-scripting **v0.10.0** (declare tools + runtime preludes, events included), labelle-assembler **v0.86.0** (DECLARE_RUNNERS, `scripts/` + `components/` convention dirs, pinned-tsc transpile) → **v0.87.0-pending** (declared events, #772 slice 2).

- **Phase 1 — contract + labelle-scripting with Lua** (**SHIPPED**). Script Runtime Contract v1 (JSON encoding, comptime-gated) in the engine; the `labelle-scripting` repo with the shared glue + the `lua` sub-module enabled: VM init, script loading from the convention dir (embedded), `init/update/deinit` per script, entity/component/input bindings. Proof: an FP-adjacent demo scene driven by a `.lua` behavior.
- **Phase 2 — dev experience** (**partial**: the script console studio panel shipped as the bundled `scripting_console` pack; the rest is open). Hot reload (disk watch + studio preview integration), Lua stack-trace error UX, the sandbox profile for mods (no `io`/`os` by default).
- **Phase 3 — native family** (**SHIPPED** — the build-integration seam landed as manifest `.language_builds` steps, not a bespoke assembler hook: cargo static-lib and crystal main-localized-object splice rows, with v0.85.0's forward-compat rule minted for this lane). The `rust` (and `crystal`) sub-modules: C header generation from the contract, optional dev dylib swap (still open; WASM stays an Alternatives candidate).
- **Phase 4 — the long tail** (**in flight**). The `typescript` (QuickJS + pinned-tsc transpile + `.d.ts` codegen — **SHIPPED**) and `ruby` (mruby — **SHIPPED**) sub-modules; `go` (c-archive, demand-driven — #746) and `csharp` (CoreCLR, desktop-first, last — #743) remain.
- **Phase 5 — purity + the agnostic assembler (new, rev 16).** Close the purity bar per language — #772 (lua/ruby events), #773 (ts declare), #774 (rust macros + extraction), #775 (crystal) — with the CI purity variant per example game; then migrate the assembler's per-language tables to the capability rows of proposal 7, freezing the built-ins into fallback defaults. Exit criterion: the python litmus test.

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
- ~~**mruby vs Crystal priority** for the Ruby-shaped slot~~ — resolved by shipping (rev 16): demand picked *both* (they serve different buyers — embedded-dynamic vs compiled-static), and the purity bar now tracks them separately (#772 / #775).
- **Native declare extraction (#774/#775)**: compile-and-run probe (recommended — the real compiler evaluates, and cargo/crystal are already required at build time) vs constrained literal-only grammar (zero toolchain at generate, grammar-drift risk). Decided on the rust ticket; crystal follows it.
- **Toolchain-pin ownership (rev 16, proposal 7)**: assembler-owned fetch pins as the supply-chain control point, or manifest-owned with assembler-enforced mandatory hashes? The recommendation on the table is the manifest; decide on the first capability-row PR.
