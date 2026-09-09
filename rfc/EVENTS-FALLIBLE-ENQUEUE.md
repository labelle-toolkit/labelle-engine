# Fallible event enqueue — `Game.tryEmit`

*labelle-engine#856, child of the hooks epic #854.*

## The problem

`Game.emit` appends the event to the frame's event buffer and, when that
buffer cannot grow, logs the allocation failure and returns `void`:

```zig
pub fn emit(self: *Game, event: GameEvents) void {
    if (has_events) {
        self.event_buffer.append(self.allocator, event) catch |err| {
            self.log.err("Failed to emit game event: {s}", .{@errorName(err)});
        };
    }
}
```

That is fine for a fire-and-forget notification. It is not fine for a
producer that uses the event to keep something *derived* in sync — an
invalidated cache, a UI panel rebuilt on change, a counter maintained by
a listener. Such a producer has no way to know its notification was
dropped, so it cannot retry and cannot degrade: the model moves on and
the derived state silently drifts.

## The API

```zig
/// Infallible — unchanged. Logs and swallows enqueue failure.
pub fn emit(self: *Game, event: GameEvents) void

/// Fallible sibling. Same buffer, same drain; enqueue failure is returned.
pub fn tryEmit(self: *Game, event: GameEvents) EmitError!void

pub const EmitError = std.mem.Allocator.Error; // error{OutOfMemory}
```

Reachable as `Game.tryEmit` / `Game.EmitError`, and the error set is also
re-exported as `engine.EmitError` so a producer can spell it out in its
own signature without naming a concrete `Game` instantiation:

```zig
fn addItem(self: *Inventory, game: *Game, slot: u32) engine.EmitError!void
```

`emit` is now literally `tryEmit` plus the historical catch-and-log, so
there is exactly one enqueue path and the two can never drift.

## Guarantees

**Success means *queued*.** A successful `tryEmit` means the event
entered the frame buffer, and nothing more. It does **not** mean a
listener ran, that the event was persisted, or that anything
acknowledged it. Delivery still happens at the end-of-frame
`dispatchEvents` drain — or at the *next* drain for an event emitted
from inside a handler, exactly as with `emit`.

**Failure leaves the queue untouched.** On `error.OutOfMemory` the
buffer is byte-for-byte what it was: every previously queued event is
intact and in emit order, and the rejected event is queued neither
partially nor twice. A retry once memory is available enqueues it
exactly once.

**Failure does not roll anything back.** Enqueue reporting is not a
transaction. The engine cannot un-deduct the gold the producer spent
before it emitted. See the recovery pattern below.

**Ordering is unchanged.** `emit` and `tryEmit` push onto the same
buffer, so interleaving them preserves emit order across both.

**No new cost on the normal path.** `tryEmit` is the same single
`ArrayList.append`; nothing extra is allocated and no comptime work is
added per call site. The dispatcher's `@setEvalBranchQuota(100000)` is
untouched.

### Games with no declared events

When a project declares no game events — `GameEvents == void`, the
`GameWith(Hooks)` shape unit tests build — there is no queue to append
to and no listener to lose. The whole body folds away at comptime and
`tryEmit` **returns success**. Success there means "nothing was
dropped", not "an event is pending". It is never an error, so a producer
written against a game *with* events keeps compiling, and keeps passing,
when linked into an event-less build.

The same holds for a game that declares events but wires no hooks
(`has_hooks == false`): the event is still queued and the drain simply
finds no receiver. Enqueue success is about the queue, not the audience.

## Recovery pattern: cache invalidation

The producer's mutation has already happened by the time the enqueue
fails, so the correct response is *not* to undo it. Record that the
derived state is stale and reconcile on a later frame:

```zig
const Inventory = struct {
    slots: [64]u32 = [_]u32{0} ** 64,
    /// Set when a change notification could not be queued. While this is
    /// true the inventory panel is known to be behind the model.
    view_dirty: bool = false,

    fn addItem(self: *Inventory, game: *Game, slot: u32) void {
        self.slots[slot] += 1; // model mutation — already committed
        game.tryEmit(.{ .inventory_changed = .{ .slot = slot } }) catch {
            // The notification is lost. Do NOT roll the mutation back:
            // the model is correct, only the derived view is stale.
            self.view_dirty = true;
        };
    }

    /// Cheap per-frame reconciliation. If the resync still cannot be
    /// queued, stay dirty and try again next frame.
    fn update(self: *Inventory, game: *Game) void {
        if (!self.view_dirty) return;
        game.tryEmit(.{ .inventory_resync = .{} }) catch return;
        self.view_dirty = false;
    }
};
```

Two rules fall out of this:

1. **Reconcile from the model, not from the missed event.** The
   `inventory_resync` handler should rebuild the panel from `slots`,
   because an unknown number of `inventory_changed` events may have been
   lost, not just the one that failed.
2. **A producer that cannot degrade should not depend on the event.** If
   correctness rests entirely on the notification landing, keep the
   dirty flag as the source of truth and treat the event as an
   optimisation.

## Migration

**None.** `emit` keeps its signature, its call shape and its behaviour,
so every existing `game.emit(...)` statement across the engine, the
plugins and the games compiles and behaves exactly as before. `tryEmit`
is purely additive; adopt it per call site, where a lost notification
actually matters.

## Alternatives considered

- **Make `emit` return `!void`.** The honest end state, and rejected:
  `emit` is called from hundreds of sites across the engine, the plugins
  and every game. Changing it is a toolkit-wide migration, not a
  default — and #854 mandates preserving existing behaviour by default.
  If it is ever wanted, it belongs in a separately reviewed migration
  with a deprecation window, not in this issue.
- **Make `emit` return `bool`.** No cheaper: Zig forbids discarding a
  non-`void` return, so every existing statement-form call site would
  still have to change. Same migration cost, less information.
- **A sticky `game.lastEmitError()` flag.** Avoids touching the
  signature, but the error cannot be attributed to a specific emit, two
  producers racing on the same frame clobber each other's report, and it
  adds mutable state to `Game` that someone has to remember to clear.
- **`ensureEventCapacity(n)` only.** Useful as a companion — reserving
  up front makes failure less likely — but it does not tell the producer
  that *this* event was lost, which is the actual gap. It can be added
  later without changing anything here.

## Tests

`test/events_fallible_emit_test.zig` (wired into `build.zig`'s
`test_files`):

- the failure path is driven with `std.testing.FailingAllocator` and the
  producer observes `error.OutOfMemory`;
- a failed enqueue leaves the queue intact, delivers no partial event,
  and a retry lands exactly once;
- `game.emit(...)` still compiles as a bare statement and still swallows
  the same failure;
- `emit` and `tryEmit` interleave in emit order;
- success means queued, not delivered;
- `tryEmit` is a no-op success on a `GameEvents == void` game.

Note for anyone extending these: `ArrayList.ensureTotalCapacityPrecise`
attempts `remap` **before** `alloc`, so arming `FailingAllocator`'s
`fail_index` alone is not enough — `resize_fail_index` has to be armed
too, and the buffer has to be sitting exactly at capacity so the append
really has to grow.
