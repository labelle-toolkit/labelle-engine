# Hook & Event Tracing

**Status:** reference. Describes `labelle-engine` opt-in hook tracing as
shipped by
[#858](https://github.com/labelle-toolkit/labelle-engine/issues/858),
child of [#854](https://github.com/labelle-toolkit/labelle-engine/issues/854).
Zig 0.16.0.

Companion documents:

| Document | Answers |
|---|---|
| `HOOK-DELIVERY-CONTRACT.md` (#857) | *When* does my handler run, in what order, how long is the payload valid? |
| [labelle-assembler `docs/design/hook-handler-ordering.md`](https://github.com/labelle-toolkit/labelle-assembler/blob/main/docs/design/hook-handler-ordering.md) (#723) | What is a receiver's **id**, and what decides dispatch order? |
| labelle-assembler#724 | Static route inspection — who *could* receive an event. |
| **this file** (#858) | What actually happened at runtime. |

---

## 1. What tracing answers

Static routes tell you an event has three listeners. They cannot tell you:

* whether the emission was **queued at all** — or whether the enqueue
  failed and `emit` swallowed it;
* which **drain**, on which **frame**, delivered it;
* which **handlers ran**, in the order they ran;
* for a consumable event, **which receiver stopped propagation**;
* whether an event reached **nobody**.

Those five are what a record set answers, and they are the acceptance
criteria of #858.

---

## 2. Turning it on

One declaration on the **compilation root** — the assembler-generated
`main.zig`, or a hand-written executable root. Same shape `std_options`
uses:

```zig
// .labelle/<target>/main.zig
pub const labelle_hook_trace = true;
```

or, with options:

```zig
pub const labelle_hook_trace: engine.HookTraceOptions = .{
    .ring_capacity = 512,     // records retained (default 128)
    .payload_capacity = 48,   // per-record payload budget (default 0 = off)
};
```

Anything else is a compile error naming the two accepted types.

> ### `zig test` cannot turn tracing on
>
> Under `zig test` the compilation root is **Zig's test runner**, not the
> test file — the same constraint #855 hit for `HookContext.game()`. A
> unit test therefore always sees `engine.hookTraceEnabled == false`.
> That is why the ON-path tests in this repo are **executables**
> (`test/hook_trace_root_exe.zig`, `test/hook_trace_scaling_exe.zig`),
> wired into `zig build test` and failing the step on a non-zero exit.

### Runtime controls

In a traced build the tracer lives on the game as `game.hook_tracer`:

```zig
game.hook_tracer.active = false;               // pause recording
game.hook_tracer.events.include = &.{"combat__*"};
game.hook_tracer.receivers.exclude = &.{"scripts/flows/*"};
game.hook_tracer.overflow = .drop_newest;      // keep the OLDEST window
game.hook_tracer.capture_payloads = true;      // needs payload_capacity > 0
game.hook_tracer.sink = .{ .ctx = &my_state, .onRecord = myWriter };
```

In an untraced build `game.hook_tracer` is `void`; those lines do not
compile, which is the intended outcome — the trace call sites are
comptime-gated, so there is nothing to toggle.

---

## 3. The record

```zig
pub const Record = struct {
    seq: u64,                 // monotonic; a gap = records evicted by the bound
    frame: u64,               // Game.frame_number
    drain: u64,               // which dispatchEvents drain
    phase: Phase,
    source: Source,
    event: []const u8,        // variant name (@tagName)
    receiver: []const u8,     // assembler#723 id, "" when not receiver-scoped
    receiver_type: []const u8,// the raw Zig @typeName
<<<<<<< HEAD
    receiver_id_kind: IdKind, // .table | .declared | .derived
=======
    receiver_id_kind: IdKind, // .declared | .derived
>>>>>>> origin/main
    index: u16,               // position in the dispatch tuple
    count: u32,               // phase-dependent, see below
    consumable: bool,
    err: []const u8,          // @errorName on enqueue_failed
    payload_len: u16, payload_buf: [payload_capacity]u8,
};
```

### Phases

| Phase | Meaning | `count` |
|---|---|---|
| `enqueue` | The event entered the frame buffer. | queue depth after |
| `enqueue_failed` | It did **not**. `err` says why; `emit` swallowed it, `tryEmit` returned it. | queue depth at the loss |
| `drain_begin` | A `dispatchEvents` drain started. | snapshot size |
| `dispatch_begin` | One event began fan-out. | — |
| `deliver` | One receiver's handler is **about to run**. | — |
| `consumed` | That handler returned `true` on a consumable event; nothing later ran. | — |
| `dispatch_end` | Fan-out finished. | handlers that ran |
| `drain_end` | The drain finished. | events delivered |

`deliver` is recorded **before** the handler runs, so anything the
handler itself emits appears *after* it — which is what makes a
handler-emitted event legible.

A `dispatch_begin`/`dispatch_end` pair with `count == 0` and no `deliver`
between them is an event that reached nobody. It is recorded rather than
omitted, because "no handler declared it" and "hooks were never wired"
otherwise look identical from the game's side.

### Sources

| Source | Path |
|---|---|
| `emit` | `Game.emit` — buffered, infallible |
| `try_emit` | `Game.tryEmit` — buffered, fallible (#856) |
| `emit_sync` | `Game.emitSync` — immediate, bypasses the buffer *and* the script-contract inbox |
| `emit_hook` | `Game.emitHook` — the engine's closed `HookPayload` |
| `drain` | delivery from inside `Game.dispatchEvents` |

`emit`/`try_emit` are the only sources on an `enqueue*` record;
`drain`/`emit_sync`/`emit_hook` are the only ones on a dispatch record.
That pairing is what distinguishes queued delivery from immediate
delivery at a glance.

---

## 4. Output

Both renderers are on `Record` (one record) and on `Tracer` (the whole
retained window plus a summary line).

### Text

```
000032 f0 d2 enqueue        emit       t__chain_src count=1
000033 f0 d3 drain_begin    drain       count=1
000034 f0 d3 dispatch_begin drain      t__chain_src
000035 f0 d3 deliver        drain      t__chain_src #0 hooks/animation_hooks
000036 f0 d3 enqueue        emit       t__chain_dst count=1
000037 f0 d3 dispatch_end   drain      t__chain_src count=1
000038 f0 d3 drain_end      drain       count=1
-- hook trace: 7/64 retained, 39 recorded, 0 dropped, 0 dropped(reentrant), 3 drains
```

Read top to bottom: `t__chain_src` was queued on drain 2's watch and
delivered by drain **3**; its handler queued `t__chain_dst` *while drain
3 was running* (record 36, stamped `d3`), so that one waits for drain 4 —
`HOOK-DELIVERY-CONTRACT.md` §4 as a trace. `7/64 retained, 39 recorded`
is the window: 32 earlier records were cleared by the harness, not lost.

`f<n>` is the frame, `d<n>` the drain, `#<n>` the tuple index. A `~`
after a receiver id means the id was **derived** rather than declared
(§6). Field *order* is the contract; exact spacing is not.

### JSON Lines

`writeJsonLines` emits one object per record and a final
`{"summary":…}` object:

```json
{"seq":35,"frame":0,"drain":3,"phase":"deliver","source":"drain","event":"t__chain_src","receiver":"hooks/animation_hooks","receiver_type":"hook_trace_root_exe.AnimationHooks","receiver_id_kind":"declared","index":0}
{"seq":36,"frame":0,"drain":3,"phase":"enqueue","source":"emit","event":"t__chain_dst","count":1}
{"summary":{"retained":7,"capacity":64,"recorded":39,"dropped":0,"dropped_reentrant":0,"drains":3}}
```

JSONL, not one array: it is append-only, streamable, and every complete
line still parses if the trace is cut off mid-run. Keys are stable and
new keys may be **added**, so a consumer must ignore unknown ones. Keys
that do not apply to a phase are **omitted**, never null. Strings are
escaped with `std.json.Stringify.encodeJsonString`.

---

## 5. Cost

### Off

`tools/hook_trace_cost.sh` compiles `test/hook_trace_cost_probe.zig` — a
headless game touching `emit`, `tryEmit`, `emitSync`, `emitHook`,
`dispatchEvents`, a notification event and a consumable one, declaring
no `labelle_hook_trace` — against `origin/main` and against this branch,
unpacked to the **same filesystem path**, and compares the results.

> **SHA-256 is not the metric.** `zig build-exe` on macOS is not
> byte-reproducible: the same tree built twice already yields two
> different hashes (LC_UUID). The script demonstrates that first, then
> uses Mach-O section sizes, which *are* stable run to run.

Measured (macOS arm64, Zig 0.16.0, `-OReleaseFast -fstrip`, engine v2.18.0
vs `origin/main` 6fb3429):

| | `__text` | `__const` | file |
|---|---|---|---|
| `origin/main` | 115688 | 6472 | 205976 |
| this branch | 115652 | 6408 | 205976 |
| `origin/main` **+ one bare `hook_tracer: void = {}` field and nothing else** | 115652 | 6408 | 205976 |

Read the third row: the entire delta is reproduced by adding a single
**zero-sized field** to `Game`, with no tracing code anywhere. Per
function (390 emitted, 390 emitted — no function added or removed), only
two changed size: the `lifecycle_mixin` mixin body (−12 bytes) and
`_start.main` (−24). `events_mixin` — the file that carries every trace
call site — is **byte-identical**.

So: an untraced build emits no tracing code, allocates nothing, and
carries no tracer state. `Game.HookTracer` is literally `void`, the same
technique `Game` already uses for `hooks` and `event_buffer` in a
hook-less or event-less build.

### On

Same 64-variant × 16-receiver shape as #854's validation, the **same
source file** compiled twice — the untraced half is
`test/hook_trace_scaling_exe.zig` with its `labelle_hook_trace` line
removed, every tracer assertion in it already behind
`if (comptime engine.hookTraceEnabled)`.

Interleaved runs, warm global cache (the first compile pays for the
shared std/core artifacts and would otherwise swamp the difference),
macOS arm64:

| | compile (real) | `__text` |
|---|---|---|
| tracing OFF (`core.MergeHooks.emit`) | 6.21 – 6.30 s | 253 464 |
| tracing ON (engine traced walk) | 6.82 – 6.87 s | 292 836 |

≈ **+0.6 s (+10.6 %) compile time** and **+39 372 bytes (+15.5 %) of
machine code** at that scale — paid only by a build that opted in.

> These are **ReleaseFast**, matching the step-1 size probe. An earlier
> revision of `tools/hook_trace_cost.sh` omitted `-O` here, so this A/B
> built in Debug and the table reported 1.61 → 1.79 s and +12.9 % `__text`
> — a mode nobody ships, and not comparable with the rest of the document
> (#858 review). Both halves are now built the same way.

### The branch quota — measured, and a footgun

`core.MergeHooks.emit` carries `@setEvalBranchQuota(100000)` and
`test/hook_dispatch_scaling_test.zig` proves it is load-bearing: remove
it and 64 × 16 fails with `evaluation exceeded 1000 backwards branches`.
The obvious worry was that a traced walk, paying the same
`variants × receivers` product with more work per iteration, would blow
that budget further.

**It does not, because the walk is a separate function.**
`hook_trace_dispatch.dispatch` holds the `switch (payload) { inline else }`
over variants; the `inline for` over receivers lives in `walkMerged`,
which Zig instantiates once **per variant**. Each instantiation is its
own analysis unit with its own budget, so the cost is O(variants) per
unit rather than the product. Measured: `test/hook_trace_scaling_exe.zig`
compiles at 64 × 16 with **`@setEvalBranchQuota` deleted entirely** —
the default 1000 is enough.

Marking `walkMerged` (or `walkSingle`) `inline` folds it back into the
switch and reproduces `evaluation exceeded 1000 backwards branches` at
exactly that scale. Verified. **Do not inline them.**

The file keeps `@setEvalBranchQuota(100000)` as headroom for hook
surfaces well past #854's validation size. Unlike core's, it is not
currently load-bearing — which the comment in the source says, so nobody
mistakes it for a proven floor.

---

## 6. Identity — and exactly how close it gets

labelle-assembler#723 §2.2 defines a receiver's **id** as its source path
relative to the generated target root, minus `.zig`:

| Group | Id |
|---|---|
| game-root hook | `hooks/animation_hooks` |
| pack hook | `packs/citizens/hooks/needs_hooks` |
| flow handler | `scripts/flows/hit_counter` |

<<<<<<< HEAD
The engine sees a **type**, not a path. It resolves the id in three ways,
and every record says which one applied (`receiver_id_kind`). Strongest
first: `.table`, then `.declared`, then `.derived`.

### `.table` — by construction (labelle-assembler#727)

A generated `main.zig` publishes

```zig
pub const hook_receiver_ids = [_][]const u8{ "hooks/animation_hooks", … };
```

index-aligned with the `GameHooks` tuple. Because `MergeHooks.emit` walks
receivers by tuple POSITION, the id for the receiver at slot `i` is
`hook_receiver_ids[i]` — the very string labelle-assembler#724's route
inspector prints. Runtime trace ids and static inspection ids are then the
same string *by construction*, not by two derivations agreeing.

The table wins over a `labelle_receiver_id` decl. Both come from #723's
`Receiver.id` and normally agree, but only the table is aligned with the
dispatch order a reader is following.

A table whose length disagrees with the hook tuple is a **compile error**,
not a silent fallback: a shifted table would label every record with the
wrong receiver, which is the failure it exists to prevent.

Absence is normal — a hand-written game, a unit-test root, or output from
an assembler predating #727 — and falls back to the two kinds below.

> **Consumers:** `.table` is a value in the JSONL `receiver_id_kind` field
> alongside `.declared` and `.derived`. A reader that enumerates the set
> must accept it.
=======
The engine sees a **type**, not a path. It resolves the id in two ways,
and every record says which one applied (`receiver_id_kind`).
>>>>>>> origin/main

### `.declared` — exact

A receiver that carries

```zig
pub const labelle_receiver_id = "packs/citizens/hooks/needs_hooks";
```

is labelled with that string verbatim. This is #723's id, not an
approximation. A `pub const` string is invisible to `MergeHooks`' handler
validation (which only rejects two-parameter `pub fn`s whose name is not
an event), so declaring it is always safe.

### `.derived` — a good derivation, not a contract

With no such decl the engine derives the id from `@typeName`. Zig names a
file-scope type by its **module-relative path** with `/` replaced by `.`,
plus the declaration name:

```
hooks/animation_hooks.zig            → hooks.animation_hooks.AnimationHooks
packs/citizens/hooks/needs_hooks.zig → packs.citizens.hooks.needs_hooks.NeedsHooks
```

and the generated `main.zig` **is** the module root, which is precisely
the "generated target root" #723 measures from. Dropping the final
`.Name` and mapping `.` back to `/` therefore reproduces the id for every
assembler-generated layout. `test/hook_trace_root_exe.zig` pins this
against a receiver in a real subdirectory.

Where the derivation is wrong:

1. **A receiver declared in the root file itself** derives the *root
   file's* stem (`main`), not a per-receiver id — so two such receivers
   collide. Generated hooks never live in `main.zig`, but the harness
   asserts this case rather than hiding it.
2. **A type nested inside another type** loses a level.
3. **A directory containing a `.`** is mapped to a `/` that is not there.
4. `@typeName`'s format is **not a documented Zig contract**. A future
   compiler may change it.

Every record therefore also carries the raw `receiver_type`, so a trace
is never ambiguous even when the id is derived.

<<<<<<< HEAD
### The assembler side — done (labelle-assembler#727)

`codegen/blocks/hooks.zig` computes the exact id (`Receiver.id`, #723) for
every receiver in `buildReceiverPlan`, and now emits them as the
index-aligned `hook_receiver_ids` table described above.

A per-receiver `pub const labelle_receiver_id` was the obvious shape and
is NOT what shipped: the assembler does not generate hook receiver files.
`<target>/hooks` is a symlink to the user's own directory and pack hooks
belong to the pack author, so emitting a decl into them would be a codemod
over source the assembler does not own. The table lives in the generated
`main.zig`, which it does own.

So the epic's "runtime tracing and static inspection use the same stable
event/handler identity" now holds **by construction** for
assembler-generated hooks, not by derivation. It still holds exactly for
any receiver that declares `engine.hook_receiver_id_decl` by hand, and
falls back to the derivation only where neither exists.

Turning tracing on in a generated project is `.hooks.trace` in
`project.labelle` (absent = off).
=======
### What an assembler change would buy

> **Open item for labelle-assembler.** `codegen/blocks/hooks.zig` already
> computes the exact id (`Receiver.id`, #723) for every receiver in
> `buildReceiverPlan`. Emitting one line per receiver —
>
> ```zig
> pub const labelle_receiver_id = "packs/citizens/hooks/needs_hooks";
> ```
>
> — into each generated hook file (or a generated wrapper) would move
> every trace record from `.derived` to `.declared`, at which point
> runtime trace ids and #724's static inspector ids are the *same string
> by construction* rather than by a derivation that happens to agree.
> The engine side is already done: the decl name is
> `engine.hook_receiver_id_decl`, and a receiver that carries it wins
> over the derivation with no other change.
>
> Until that lands, the epic's "runtime tracing and static inspection use
> the same stable event/handler identity" holds **by derivation, not by
> construction**, for assembler-generated hooks — and holds exactly for
> any receiver that declares the decl by hand.
>>>>>>> origin/main

Event identity has no such gap: an event's trace name is `@tagName` of
the merged payload variant, which is the same final event name the
assembler emits and the inspector prints.

---

## 7. Guarantees

* **The tracer never emits an event.** It writes to its own ring and to
  an optional sink. Ordering, re-entrancy and handler results are
  identical with tracing on and off — `test/hook_trace_root_exe.zig`
  drives the same payloads through the traced walk and through
  `core.MergeHooks.emit` directly and requires the same handler order.
* **It never allocates.** The ring is a fixed inline array; every stored
  string is a comptime literal (`@tagName`, `@typeName`, a declared id)
  or an `@errorName`, all program-lifetime.
* **Failure reporting does not recurse.** An enqueue failure is recorded
  by writing a struct into the ring — no allocation, no event, safe under
  the very OOM that caused it. A sink that pushes back into the tracer is
  detected and its nested record is counted in `dropped_reentrant`
  instead of recursing.
* **Filtering never changes dispatch.** A filtered-out `deliver` record
  does not stop the handler running, and `dispatch_end`'s `count` still
  reports every handler that ran.
* **The bound is explicit.** `overwrite_oldest` (default) keeps the
  newest window; `drop_newest` keeps the oldest. Either way the loss is
  counted in `dropped` and printed in every summary line, and `seq` keeps
  running so a gap in the retained records is visible.
* **Payload values are out by default.** Capture needs `payload_capacity
  > 0` at comptime **and** `capture_payloads = true` at runtime, and even
  then only scalar fields (ints, floats, bools, enums) are rendered.
  Slices and pointers are never dereferenced — the delivery contract
  makes them *borrowed* (§5 there), and reading one out of a ring buffer
  minutes later would be reading memory its owner has reused.

## 8. Limits

* **No cross-frame trace persistence.** The ring is in-process and dies
  with the game. Streaming to a file or socket is what `Tracer.Sink` is
  for; the engine ships no sink of its own.
* **Not thread-safe.** One tracer per `Game`, written from whichever
  thread emits. The engine's own emit paths are single-threaded.
* **`walkMerged` mirrors core's dispatch loop by hand.** If
  `labelle-core`'s `MergeHooks.emit` changes its order, its `@hasDecl`
  gate or its consumable break, this file must change with it. The parity
  check in `test/hook_trace_root_exe.zig` turns a divergence into a
  failing build rather than a lying trace, but it cannot prevent one.
* **No headless *assembled* proof in this repo.** Same gap
  `HOOK-DELIVERY-CONTRACT.md` §12 records: the engine repo cannot run the
  assembler, so nothing here traces a *generated* loop. The harnesses
  reproduce the generated shape by hand.

---

## 9. Files

| File | Role |
|---|---|
| `src/hook_trace.zig` | Options, `Record`, `Phase`/`Source`/`IdKind`, `Filter`, `Tracer`, `ReceiverId`, renderers |
| `src/game/hook_trace_dispatch.zig` | The traced receiver walk (mirror of core's) |
| `src/game/events_mixin.zig` | Trace call sites: enqueue, drain, dispatch |
| `test/hook_trace_root_exe.zig` | The ON harness — 15 checks incl. dispatch parity |
| `test/hook_trace_scaling_exe.zig` | 64 × 16 with tracing ON; the comptime budget |
| `test/hook_trace_off_test.zig` | The OFF proof (its root is the test runner) |
| `test/hook_trace_cost_probe.zig` + `tools/hook_trace_cost.sh` | The cost measurement |
