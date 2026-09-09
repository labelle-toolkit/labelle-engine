# Hook & Event Delivery Contract

**Status:** reference (descriptive, not a proposal). Describes shipped
behaviour as of labelle-engine v2.18.0 / labelle-core v1.30.x on Zig 0.16.0.
**Issue:** [#857](https://github.com/labelle-toolkit/labelle-engine/issues/857),
child of [#854](https://github.com/labelle-toolkit/labelle-engine/issues/854).

This document is the single authoritative answer to *"when does my handler
run, in what order, and how long is the payload valid?"* Everything here is
pinned by executable tests:

| File | Covers |
|------|--------|
| `test/hook_delivery_contract_test.zig` | every numbered guarantee below (D1–D10) |
| `test/hook_dispatch_scaling_test.zig` | the dispatcher's comptime branch-quota headroom (§9) |
| `test/engine_events_test.zig` | the `engine__*` lifecycle variants themselves |
| `test/input_events_test.zig` | input-event scan → buffer → drain |

> **This is a description, not a design.** Where behaviour below is
> surprising (§2 drain-before-tick, §7 scene-reset drop, §5 borrowed
> slices, §8 silent enqueue failure) it is written down as-is and flagged.
> Changing any of it needs its own issue and its own migration note.

---

## 1. The emit paths

Four ways to get a handler called. They differ in **when** — and one of them
also differs in **who**.

> ⚠️ `emitSync` is not merely a faster `emit`. The buffered path copies the
> event into the script-contract inbox on its way through; `emitSync` bypasses
> that tap entirely. Switching an emit to `emitSync` for latency therefore
> **silently stops delivering it to language-script subscribers**. Choose
> `emitSync` for ordering, never as an optimisation.

| Call | Timing | Reaches | Notes |
|------|--------|---------|-------|
| `game.emitHook(payload)` | **immediate** | hook receivers | The closed `HookPayload(Entity)` union — engine-internal lifecycle (`frame_start`, `scene_load`, `entity_created`, …). No buffer, ever. |
| `game.emit(event)` | **buffered** — next `dispatchEvents` | hook receivers, flows, script inbox | The project's `GameEvents` union. The normal path. |
| `game.emitSync(event)` | **immediate** | hook receivers | Same union as `emit`, bypasses the buffer. Does **not** reach the script-contract inbox tap (§2), which reads the buffer. |
| `game.emitEngineEvent("engine__x", .{…})` | **buffered** | as `emit` | Comptime-gated tolerant helper for the engine's own `Events`. Folds to a **no-op** when the project's `GameEvents` has no such variant. `emitEngineEventSync` is the immediate twin (used by the fixed-timestep phase). |

`emitHook` and `emit`/`emitSync` end at the same place: the hooks receiver's
`emit` method — `core.MergeHooks.emit` for a multi-receiver (assembled)
game, `core.HookDispatcher.emit` for a single receiver.

**Zero listeners is not an error.** If `setHooks` was never called, or the
receiver declares no matching handler, the event is dispatched to nobody and
silently dropped. In a hook-less build (`Hooks = void`) the whole path folds
away at comptime.

---

## 2. Drain points — where `dispatchEvents` actually runs

**Exactly one drain per generated-loop iteration that runs the SIM half, and
it runs BEFORE `g.tick(dt)`.**

The qualifier is load-bearing: under editor preview (`labelle-studio` Play
mode) a paused iteration fails `shouldTick()` and skips the whole SIM half —
`g.dispatchEvents()` included — so **zero** drains happen while paused and the
buffer grows unbounded (§11). "Once per frame" is true of a running sim, not of
every iteration of the loop.

Every shipped backend template (raylib/sokol/bgfx desktop, mobile, wasm, and
the null headless runner) emits the assembler's `tick_code` — which *ends*
in `g.dispatchEvents()` — immediately *before* `g.tick(dt)`. Verified against
a real generated main (`flying-platform-labelle/.labelle/bgfx_desktop/main.zig`,
lines 2946–2968) and against
`labelle-assembler/src/codegen/lifecycle/render.zig`:

```zig
while (running) {
    // ── SIM half ────────────────────────────────────────────────────
    const scaled_dt = dt * g.time_scale;
    if (scaled_dt > 0) {
        runner.tick(&g, scaled_dt);        // Zig scripts   — they emit here
        PluginSystems.tick(&g, scaled_dt); // plugin systems — they emit here
        PluginSystems.postTick(&g, scaled_dt);
        scripting.Controller.tick(...);    // language-script VMs (if spliced)
    }
    engine.script_contract.drainEvents(&g); // script inbox TAP — copies, does not consume
    g.dispatchEvents();                     // ◀── THE DRAIN
    g.tick(dt);                             // engine lifecycle events emitted HERE
    // ── RENDER half ─────────────────────────────────────────────────
    window.beginFrame(); g.render(); g.renderGizmos(); ... window.endFrame();
}
```

### Consequences (D9)

* **A script or plugin that emits during its own tick is delivered later in
  the SAME iteration.** Sub-frame latency. This is the common case and it
  behaves the way authors expect.
* **Anything the ENGINE emits inside `g.tick` waits for the NEXT
  iteration's drain.** That covers `engine__tick`, `engine__post_tick`,
  the input-event scan
  (`engine__key_pressed`, `engine__mouse_button_pressed`, …), sprite-animation
  events, and any `entity_created` / `scene_loaded` raised by work `tick`
  drives. **One frame of latency, by construction.**
* The engine's own `emitHook` path (`HookPayload.frame_start` etc.) is
  *immediate*, so a native hook receiver sees `frame_start` a full frame
  before a flow listening to `engine__tick` does.

> ⚠️ **Two source comments contradict this and are wrong.**
> `src/game/loop_mixin.zig` says input events "drain together on the next
> `dispatchEvents` (called by the generated main loop right after `tick`) —
> i.e. they dispatch the SAME frame", and `src/game/events_mixin.zig` calls
> `dispatchEvents` an "end of frame" drain. Neither matches any shipped
> template. The templates are the source of truth; the comments were
> corrected under #857 to point here.

### Other drain points

* **`Game.deinit`** drains exactly once, after emitting `game_deinit` (§7).
* **Editor preview (labelle-studio Play mode)** gates the entire SIM half —
  the drain included — on `engine.editor_api.shouldTick()`. While the editor
  is paused **no drain happens at all** and the buffer accumulates. The
  render half still runs.
* **Nothing else.** `Game.render()` has no drain point. A game that never
  calls `dispatchEvents` grows `event_buffer` without bound: there is no cap,
  no eviction, and no back-pressure.

---

## 3. Ordering

### D2 — within one drain: FIFO by enqueue

`dispatchEvents` swaps the buffer out and iterates the snapshot front to
back. Events are delivered in the order `emit` was called, with no
coalescing, dedup, or priority reordering across kinds.

### D2 — within one event: receiver-tuple order

`MergeHooks.emit` walks `ReceiverTypes` in declaration order and calls every
receiver that declares a handler for the active variant. That tuple order is
**generated**, not chosen by the game: the assembler emits it in scanner-sort
order (`labelle-assembler/src/main_zig.zig`). Native handlers and the flow
handlers' separately-ordered priority tail are the assembler's business —
tracked in [labelle-assembler#723](https://github.com/labelle-toolkit/labelle-assembler/issues/723).
From the engine's side the only guarantee is: *the order of the tuple you
were handed, stable within a build.*

### D5 — consumable events stop at the first claim

A payload struct declaring `pub const consumable = true;` switches
`MergeHooks.emit` to the return-aware path: handlers return `bool` and the
loop **breaks** on the first `true`. Later receivers never run. Without the
marker the return value is discarded and every receiver runs
(RFC-PLUGIN-EVENTS O4).

### D4 — `emitSync` jumps the queue

`emitSync` does **not** drain the buffer first. An event emitted
synchronously runs before every event `emit` queued earlier in the same
frame. Mixing the two on one event kind produces out-of-order handler calls.
Use `emitSync` only for leaf operations that genuinely cannot tolerate the
buffered window. There are **three** in-tree justifications, and the list is
meant to be exhaustive:

* the surface-loss events (#820) — the GPU context dies the moment the backend
  call returns, so a buffered delivery would arrive after every handle is dead;
* the fixed-timestep phase (#751) — flow-driven fixed systems must stay in
  phase with the `fixed_update` hook;
* `engine__editor_plugin_command` (`src/game/editor_command_mixin.zig`) — the
  handler borrows host-owned command buffers and must produce a response
  *before* the bridge call returns. Buffering it would both invalidate the
  payload's lifetime and break the synchronous response contract.

### Cross-frame

There is no global sequence number and no ordering guarantee between an
`emitSync` in frame N and a buffered `emit` from frame N−1 other than the
one the drain point implies.

---

## 4. Handler-emitted events (D3)

**An event emitted from inside a handler arrives on the NEXT drain.**

`dispatchEvents` swaps `event_buffer` into a local snapshot before iterating,
so a handler's `emit` lands in the *fresh* buffer and is invisible to the
drain that is running:

```zig
var dispatch_buf: EventBuffer = .empty;
std.mem.swap(EventBuffer, &self.event_buffer, &dispatch_buf);
for (dispatch_buf.items) |event| { …dispatch… }   // snapshot — cannot grow
```

* A chain of *N* hops therefore costs *N* drains ≈ *N* frames.
* The design is deliberate: it makes an infinite `A → B → A` loop spread
  across frames instead of hanging the drain, and it keeps the iterated slice
  from being invalidated by a reallocation mid-loop.
* If a handler needs the follow-up to run *now*, `emitSync` is the escape
  hatch — with §3's re-entrancy caveats.

**Capacity recycling.** If the drain finishes and no handler emitted
anything, the (now-empty) snapshot buffer is swapped back so its capacity is
reused. If a handler *did* emit, the snapshot's capacity is freed and the new
buffer keeps its own. Purely an allocation optimisation — no observable
behaviour rides on it.

**Re-entrancy.** Handlers run on the caller's stack. A handler that calls
`emitSync`, mutates entities, or calls back into the emitter's own code
interleaves with partially-completed work above it. A handler that calls
`dispatchEvents` re-entrantly will drain the events its siblings queued —
supported by construction, but not a pattern the engine uses anywhere.

---

## 5. Payload lifetime and ownership (D6)

**`emit` copies the payload STRUCT by value into the buffer. It does not
copy anything the struct points at.**

For POD fields (`u32`, `f32`, `bool`, fixed arrays, enums) that is a complete
copy and there is nothing to think about — mutating your local after the emit
changes nothing.

For a `[]const u8` (or any pointer/slice) field, the copy is the `(ptr, len)`
pair. The **bytes are borrowed**:

```zig
var name_buf: [5]u8 = "first".*;
game.emit(.{ .thing__named = .{ .name = &name_buf } });
@memcpy(&name_buf, "AFTER");
game.dispatchEvents();
// the handler observes "AFTER" — the drain read the CALLER's memory
```

### The rule

> **A borrowed payload field must stay valid from the `emit` call until the
> end of the drain that delivers it — i.e. at least until the next
> `dispatchEvents` returns. A handler that keeps the slice needs it to stay
> valid for as long as it keeps it.**

Safe sources, in rough order of preference:

1. **Program-lifetime** — string literals, `@embedFile` borrows, comptime
   tables, assembler-generated scene/asset names. Always safe.
2. **Game-lifetime** — anything owned by `Game` or a plugin's `State` that
   outlives the frame.
3. **A frame arena that is reset AFTER the drain** — remember the drain is at
   the *top* of the loop iteration (§2), so "reset at end of frame" and "reset
   at start of frame" are not the same thing here.

Unsafe: stack locals in the emitting function, anything freed before the next
drain, and (critically) an arena reset between the emit and the drain.

### The engine's own precedent

`Events.gamepad_connected` stores the device name **inline** as a
`[NAME_CAPACITY:0]u8` buffer plus a length, with a `nameSlice()` accessor,
precisely because the borrowed-slice form would dangle across the drain.
That is the recommended shape for any payload whose string has no natural
owner. `Events.video_finished` uses `[]const u8` and relies on a referent that
outlives the drain.

> 🐛 **The scene-name payloads VIOLATE this rule on the queued-transition
> path.** `tick` hands the OWNED `pending_scene_change` slice to `setScene`,
> which buffers `engine__scene_loading` / `engine__scene_loaded` carrying that
> slice — and then `loop_mixin.zig:196-198` frees it in the same commit block.
> Since all of that happens *after* the frame's drain, both payloads dangle
> until the next iteration. `engine__scene_unloaded` has the same shape:
> `unloadCurrentScene` queues the owned current name and `setScene` frees it
> immediately afterwards. Do not read this section as saying scene events are
> safe — they are the same bug as `state_changed` below, on a different
> string. Tracked in #863.

> 🐛 **`Events.state_changed` currently VIOLATES this rule on one path.**
> `setStateOwned` (`src/game/state_mixin.zig`) dupes the new name, calls
> `setState` — which queues `state_changed` carrying `old_state` pointing at
> the *previous* owned allocation — and then frees that allocation before
> returning. The buffered event's `old_state` dangles until the drain, so the
> runtime/editor-owned state path can expose freed bytes to a flow listener.
>
> This is documented here rather than fixed: this PR pins the contract down and
> changes no behaviour. The fix (retain the old slot until the drain, or copy
> the name into the payload) is a behaviour change and belongs in its own
> change. Tracked in #862.

**Value-copying an event is not deep-copying its data.** That sentence is the
whole of §5.

---

## 6. Receiver lifetime

Receivers are held as **pointers** in the `MergeHooks` tuple (`*R1, *R2, …`)
and installed by `setHooks`. The engine never copies, owns, or frees them.

* Every receiver must outlive the `Game`. In an assembled game they are
  module-scope vars in the generated `main.zig`, so this is automatic.
* `setHooks` must be called with the game at its **final address** —
  `Game.init` returns by value, so wire hooks after the move, never on a
  temporary.
* `setHooks` is also what fires `game_init` / `engine__game_init`
  (`engine__game_init` is buffered, so it needs a drain to land).
* Events emitted before `setHooks` are **buffered, not discarded.** `setHooks`
  neither drains nor clears the buffer, so the next `dispatchEvents` delivers
  them to the newly installed receiver. They are lost only if a drain happens
  while no receiver is installed — which is a narrower condition than "emitted
  early", and the one to actually guard against.

---

## 7. Scene reset and shutdown

### D7 — a scene unload DISCARDS the queue

`unloadCurrentScene` calls `event_buffer.clearRetainingCapacity()` as its
**first** statement, before emitting its own `scene_unloaded`. Everything a
script queued earlier in the frame is dropped, silently.

The rationale is sound (the outgoing scene's entities are about to be
destroyed, so their events reference ids that will not exist) but the
behaviour is worth stating plainly:

> **Any buffered event that has not been drained when a scene unloads is
> lost. Do not use a buffered `emit` to hand state across a scene
> transition.** Use game/plugin state, or `emitSync` if the handler must run
> before the swap.

`setSceneAtomic` reaches the same clear through `unloadCurrentScene`.

### D8 — shutdown flushes exactly once

`Game.deinit`, in order:

1. `emitHook(.{ .game_deinit = {} })` — immediate.
2. `emitEngineEvent("engine__game_deinit", .{})` — buffered.
3. `dispatchEvents()` — **the last drain**. Delivers `engine__game_deinit`
   plus anything still queued.
4. `event_buffer.deinit(allocator)` — the buffer is gone.
5. …the rest of teardown (active scene `deinit_fn`, ECS, assets, …).

So: **a pending event is flushed at shutdown, and whether a shutdown handler's
own emit survives depends on where that handler runs.**

* The native `game_deinit` hook runs at **step 1**, before the final drain, so
  an `emit` from it is included in step 3 and *is* delivered.
* A handler running *during* the final drain — an `engine__game_deinit` event
  handler, say — appends to the fresh buffer the snapshot swap left behind, and
  **that** is what gets dropped: there is no second drain.

The rule is not "shutdown handlers can't emit"; it is "nothing emitted from
inside the final drain is delivered".

> ⚠️ **Hazard.** Step 4 precedes step 5. No engine code path emits after
> step 4, but a scene's `deinit_fn` that reaches back into the game and
> emits would be appending to a torn-down `ArrayList`. Treat "emit during
> `Game.deinit` teardown" as unsupported. (Noted here rather than fixed —
> #857 is descriptive; a fix needs its own issue.)

---

## 8. Failure modes

| Situation | Today's behaviour |
|-----------|-------------------|
| Allocation failure in `emit` | Caught, logged at `err`, **event silently lost** — `emit` returns `void`, so the producer cannot know. Use **`tryEmit`** (#856) when that matters: same enqueue, same drain, but it returns `EmitError!void`. On failure the buffer is unchanged — earlier events intact and ordered, the failed event neither partial nor duplicated — so a retry lands exactly once. It does NOT roll back the producer's own mutation; the documented recovery is a dirty flag reconciled on a later frame. See `rfc/EVENTS-FALLIBLE-ENQUEUE.md`. |
| `emitEngineEvent` for a variant the project's `GameEvents` lacks | Comptime no-op. Not an error, not a warning. |
| Handler declared for an event that does not exist | **Compile error** from `MergeHooks`' validation block ("Handler 'x' … doesn't match any event in …"). |
| `HookDispatcher` (single receiver) with `exhaustive = true` | Compile error when a variant has no handler. Off by default. |
| Buffer never drained | Unbounded growth. No cap, no eviction, no warning. |

---

## 9. Comptime scaling — the branch quota is load-bearing

`MergeHooks.emit` expands `switch (payload) { inline else }` over every event
variant and, inside each arm, an `inline for` over every receiver type. The
comptime cost is the **product** `variants × receivers`, which passes Zig's
default 1000-backwards-branch evaluation limit long before a real game's hook
surface gets interesting.

`labelle-core/src/dispatcher.zig` therefore carries
`@setEvalBranchQuota(100000)` inside `emit` (plus 10 000 in the validation
block and 20 000 in `MergeHookPayloads`). **Removing it breaks any project at
Flying-Platform scale.**

`test/hook_dispatch_scaling_test.zig` pins the representative size the #854
validation used — **64 event variants × 16 distinct receiver types** — and
deliberately sets **no quota of its own**, so the dispatcher's quota is the
only thing making it compile. Measured: with a copy of core whose
`@setEvalBranchQuota(100000)` was deleted, that file (and only that file) fails
with `evaluation exceeded 1000 backwards branches` at
`dispatcher.zig:152`.

If you are reading this because CI failed that way, the fix is in
`MergeHooks.emit`, not in the test file.

---

## 10. Lifecycle map — which mechanism fires what

| Signal | Mechanism | Timing |
|--------|-----------|--------|
| `game_init`, `game_deinit`, `frame_start`, `frame_end`, `fixed_update`, `scene_*`, `state_*`, `pause_changed`, `entity_created`, `entity_destroyed` | native `HookPayload` via `emitHook` | **immediate**, at the emit site |
| `engine__game_init`, `engine__tick`, `engine__post_tick`, `engine__entity_created`, `engine__scene_loaded`, `engine__state_changed`, `engine__pause_changed`, … | `emitEngineEvent` → buffered | **next drain** (one frame later for anything emitted inside `tick`, §2) |
| `engine__surface_lost` / `engine__surface_restored` | `emitEngineEventSync` | **immediate** — the GPU context is torn down the moment the backend call returns, so buffering would deliver them after every handle was dead (#820) |
| `engine__fixed_tick` | `emitEngineEventSync` | **immediate**, inside the fixed slice, so flow-driven fixed systems stay in phase with the `fixed_update` hook (#751) |
| Component `onReady` / `postLoad` | direct comptime call from the scene loader | **immediate**, per entity, as it is assembled — see §11 |
| Whole-scene completion | `scene_load` hook (immediate) + `engine__scene_loaded` (buffered) | after the loader returns and the scene is active |
| Asset readiness | polled, not evented. `assets.pump()` at the top of `tick`; the `setScene` manifest gate spins until `.ready` | no event is emitted per asset |
| `engine__scene_assets_acquire`, `engine__scene_before_reset` | `emitEngineEvent` → buffered → **discarded** | ⚠️ **never delivered.** `setScene` queues the acquire event (`scene_mixin.zig:708`) and then calls `unloadCurrentScene` (`:710`), whose first statement clears the buffer; the atomic path queues `scene_before_reset` (`:876`) before the same clear at `:896`. Their `emitHook` twins DO fire — only the buffered `engine__*` variants are dropped. Tracked in #864 |

> ⚠️ The row above is the one place this table advertises an event that does
> not arrive. It is recorded rather than quietly omitted because a flow author
> reading the generated event list will otherwise write a listener that can
> never run.

---

## 11. Lifecycle caveat: scene loading is not transactional (D10, #805)

`fireOnReadyAll` fires an entity's `onReady`/`postLoad` **the moment that
entity's components are applied** — before later siblings, and before later
body parts of the same reference, get a chance to fail the load.

When entity #2 of a scene fails (an unmatched `@` override target, a legacy
`components` key on a prefab reference, a bad ref), entity #1's hooks have
**already run**. The loader's `errdefer` removes the ECS tree, but it cannot
undo external side effects those hooks caused — a registered listener, an
acquired asset, an entry in a game-side table.

> **There is no implicit "the whole scene loaded or nothing happened"
> guarantee.** Do not write an `onReady` whose side effects would be wrong if
> the load aborted a moment later, unless you also handle the abort.

This is inherent to incremental loading, and
[#805](https://github.com/labelle-toolkit/labelle-engine/issues/805) records
the stance: a stronger guarantee would need a **validate-only pre-pass** (the
tree walker already visits everything), not hook reordering — reordering
`fireOnReadyAll` after prefab-children loading would break the #561
hook-order contract for every scene. Refs #802, #801, #561.

---

## 12. Known gaps

* **No end-to-end assembled headless proof in this repo.** §2's frame shape
  is established from the assembler's `render.zig` `tick_code`, from every
  backend template, and from a checked-in generated `main.zig` — and
  reproduced structurally by D9 — but the engine repo cannot run the
  assembler, so nothing here executes a *generated* loop. That check belongs
  in labelle-assembler or a game repo.
* **Flow-handler priority ordering** is assembler-side and is specified in
  labelle-assembler#723, not here.
* **`emit`'s enqueue failure contract** landed with #856: `tryEmit` is the fallible sibling, documented in the failure-mode table above and in `rfc/EVENTS-FALLIBLE-ENQUEUE.md`.
* **Observability** — there is no way to enumerate listeners or trace a
  dispatch today; see labelle-assembler#724 (static route inspector) and
  labelle-engine#858 (runtime tracing).
