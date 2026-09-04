# Language-plugins spike (RFC-LANGUAGE-PLUGINS, #237)

Proof that **one Script Runtime Contract serves every language family**: the
same behavior script, written in three languages across both integration
families, drives the same C-ABI surface and produces **byte-identical world
state** — asserted by the host, not eyeballed.

```
== verdict ==
FAMILIES AGREE: one contract, three languages (Lua VM, Rust, Crystal), identical world state.
```

Run it (macOS; needs brew `lua`, `cargo`, `crystal`):

```sh
zig build run    # Zig 0.16
```

## What each run proves

Every language: creates an entity, sets `Position` by name as JSON, reads it
back each tick, moves +10/tick for 5 ticks, spawns a bullet on tick 3,
**emits** `bullet_spawned` — and on the receive side **subscribes** to
`tick_started` in `init`, **drains a poll loop** each tick, and reacts to
tick 4 by writing a `TickLog` component. Snapshots (entities + components +
events) must match exactly across languages.

| | family | mechanism | file |
|---|---|---|---|
| **Lua 5.4** | embedded VM | brew `liblua.a` + ~20 hand-declared C externs (no `@cImport`), binding shims → `labelle.*` table | `scripts/behavior.lua`, `main.zig` |
| **Rust** | native-compiled | zero-dep `staticlib` via cargo, `extern "C"` against the contract, linked into the host | `rust/src/lib.rs` |
| **Crystal** | native-compiled | `--cross-compile` object, `ld -r` localizes its `main`, boot via `Crystal.init_runtime` | `crystal/script.cr` |

## The event system across languages

The contract's receive side is deliberately minimal — **subscribe + poll**:

```c
void   labelle_event_subscribe(const char *name, size_t name_len);
size_t labelle_event_poll(char *out, size_t out_cap); /* "<name> <json>", 0 = empty */
```

- The host queues events into a per-script FIFO inbox **only for subscribed
  names** (the engine analog: `GameEvents` dispatch fanning out to
  language-plugin subscribers, exactly like hook consumption folds events in
  today — the zero-cost gate flips on per subscription).
- Scripts **drain the inbox at the top of their tick** — one `while`/`loop`
  in every language, no callbacks in the ABI. Callback dispatch is
  *language-plugin sugar built over the drain loop*: labelle-lua registers
  Lua functions per event name and calls them from the drain; labelle-rust
  exposes a match/handler trait; labelle-csharp maps to C# events. The ABI
  stays one function.
- Emit (script→host) is symmetric (`labelle_event_emit`) and feeds the same
  engine event bus; both directions are proven here in all three languages.
- Ordering: the host emits before the tick's `update`; scripts observe a
  deterministic FIFO. Payloads are JSON (encoding v1), names are the
  subscription key — same identity model as the engine's event tags.

## Findings (the "clear path" part)

1. **The contract is small and sufficient.** Entities + components-by-name
   (JSON) + events + log covered the whole behavior; nothing language-specific
   leaked into the ABI. `component_set` is the runtime generalization of the
   engine's existing `editor_set_component` — the engine-side work is a
   surface, not a rewrite.
2. **Lua is as easy as advertised** (#237 stands): ~20 extern declarations,
   five shim closures, done. LuaJIT is a link-time swap later.
3. **Rust needs no bindings work at all** — the contract header *is* the
   binding. A real labelle-rust is mostly build integration (cargo → staticlib
   → link) plus ergonomic wrappers.
4. **Crystal works but has real sharp edges** (all solved here, all must be
   institutionalized by labelle-crystal):
   - no `--no-main`: localize the object's `main` via
     `ld -r -exported_symbols_list` (see `build.zig`);
   - boot via **`Crystal.init_runtime`** (`Crystal.main_user_code` segfaults
     under a foreign stack);
   - **raising APIs segfault**: Crystal's `raise` captures a backtrace by
     walking the stack, and foreign (host) frames break the walk — the POC's
     `to_i64?(strict: false)` (raise-and-rescue inside) crashed at 0x2c until
     replaced with a non-raising parse. The real plugin must wrap script
     entry points non-raising and/or disable callstack capture;
   - GC ran with `GC.disable` here; the plugin's first work item is
     registering the host stack bounds with bdw-gc properly.
5. **C# (documented, not coded — dotnet 8 present, heaviest lift):** host
   `hostfxr` (`hostfxr_initialize_for_runtime_config` →
   `load_assembly_and_get_function_pointer`), script entry points as
   `[UnmanagedCallersOnly]` static methods, contract consumed via
   `[LibraryImport]` resolved against the host process (`dlopen(NULL)`
   resolution). Desktop-first; mobile AOT constraints per the RFC.
6. **mruby (documented, not coded — not installed here):** same shape as the
   Lua half verbatim (`mrb_open`, `mrb_define_module_function`, drain loop).
7. **Zig 0.16 host notes:** `link_libc`/`addObjectFile` moved to the module;
   `std.Io.Writer.fixed` replaces `std.io`; hand-declared externs beat
   `@cImport` for stable C APIs.

## What this deliberately does not prove

The real engine integration (the comptime-gated contract surface over the
serde-reflection registry), hot reload, sandboxing profiles, GC pressure, and
performance — all Phase 1+ work in the RFC, none of them boundary risks.
