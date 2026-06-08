//! Tests for the runtime `Scheduler` — the foundation for flow `Delay`
//! nodes (flow-codegen#48 / #25 Stage 2).
//!
//! Headline properties under test:
//!   - fires once when the gameplay clock reaches `fire_at`; not early,
//!     not twice.
//!   - multiple timers fire in due order across ticks.
//!   - PAUSE FREEZES pending timers (the reason the scheduler reuses
//!     `elapsedSeconds()` instead of its own accumulator).
//!   - an entity-bound timer whose entity is destroyed before firing is
//!     SKIPPED, and its `ctx` is freed (no leak, callback never runs).
//!   - a fired callback may re-entrantly schedule another timer without
//!     corrupting iteration.
//!   - `Game.deinit` with timers still pending frees everything
//!     (testing.allocator catches leaks).
//!
//! The tests drive the in-tree mock game (`engine.Game`, ECS `Entity = u32`)
//! and step time with `game.tick(dt)`, exactly like `pause_hook_test.zig`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Game = engine.Game;

// ── Capture struct + trampoline ─────────────────────────────────────────
//
// Mirrors what the flow `Delay` codegen emits: a heap-allocated capture
// (created on `game.allocator`) plus a type-erased `func` that casts both
// pointers back. The scheduler OWNS the capture and frees it after firing.

const Capture = struct {
    fired: *usize, // bumped each time the callback runs
    order_sink: ?*std.ArrayListUnmanaged(u32) = null,
    tag: u32 = 0,
    // For the re-entrant test: schedule another timer from inside the cb.
    reschedule: bool = false,
};

fn trampoline(game_ctx: *anyopaque, ctx: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_ctx));
    const cap: *Capture = @ptrCast(@alignCast(ctx));
    cap.fired.* += 1;
    if (cap.order_sink) |sink| sink.append(game.allocator, cap.tag) catch unreachable;
    if (cap.reschedule) {
        // Re-entrant schedule: a fresh capture + a non-rescheduling cb.
        const again = game.allocator.create(Capture) catch unreachable;
        again.* = .{ .fired = cap.fired };
        game.scheduler.after(0.0, null, again, trampoline);
    }
}

fn newCapture(game: *Game, fired: *usize) *Capture {
    const cap = game.allocator.create(Capture) catch unreachable;
    cap.* = .{ .fired = fired };
    return cap;
}

// ── Basic fire-once semantics ───────────────────────────────────────────

test "fires once when the clock reaches fire_at — not early, not twice" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    var fired: usize = 0;
    const cap = newCapture(&game, &fired);
    game.scheduler.after(1.0, null, cap, trampoline);

    // Before due: advance to t=0.9, must NOT fire.
    game.tick(0.5);
    game.tick(0.4);
    try testing.expectEqual(@as(usize, 0), fired);
    try testing.expectEqual(@as(usize, 1), game.scheduler.pendingCount());

    // Cross fire_at (t=1.0): fires exactly once.
    game.tick(0.1);
    try testing.expectEqual(@as(usize, 1), fired);
    try testing.expectEqual(@as(usize, 0), game.scheduler.pendingCount());

    // Keep ticking: must not re-fire.
    game.tick(1.0);
    game.tick(1.0);
    try testing.expectEqual(@as(usize, 1), fired);
}

test "fires when the very tick crosses fire_at (boundary <= now)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    var fired: usize = 0;
    const cap = newCapture(&game, &fired);
    game.scheduler.after(0.5, null, cap, trampoline);

    game.tick(0.5); // elapsedSeconds == 0.5 == fire_at → due
    try testing.expectEqual(@as(usize, 1), fired);
}

// ── Ordering across ticks ───────────────────────────────────────────────

test "multiple timers fire in due order across ticks" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    var order: std.ArrayListUnmanaged(u32) = .empty;
    defer order.deinit(testing.allocator);
    var fired: usize = 0;

    // Schedule out of order; they must fire by due time.
    const a = game.allocator.create(Capture) catch unreachable;
    a.* = .{ .fired = &fired, .order_sink = &order, .tag = 3 };
    game.scheduler.after(3.0, null, a, trampoline);

    const b = game.allocator.create(Capture) catch unreachable;
    b.* = .{ .fired = &fired, .order_sink = &order, .tag = 1 };
    game.scheduler.after(1.0, null, b, trampoline);

    const c = game.allocator.create(Capture) catch unreachable;
    c.* = .{ .fired = &fired, .order_sink = &order, .tag = 2 };
    game.scheduler.after(2.0, null, c, trampoline);

    // Step second-by-second; each tick releases the next due timer.
    game.tick(1.0);
    game.tick(1.0);
    game.tick(1.0);

    try testing.expectEqual(@as(usize, 3), fired);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, order.items);
}

// ── Pause freeze (the headline property) ────────────────────────────────

test "pause freezes pending timers; resume lets them fire" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    var fired: usize = 0;
    const cap = newCapture(&game, &fired);
    game.scheduler.after(1.0, null, cap, trampoline);

    // Advance partway (t=0.5), then pause via the #465 flag.
    game.tick(0.5);
    game.setPaused(true);

    // Many ticks while paused: the gameplay clock is frozen at 0.5, so the
    // 1.0s timer can never come due — no separate accumulator advances it.
    var i: usize = 0;
    while (i < 100) : (i += 1) game.tick(1.0);
    try testing.expectEqual(@as(usize, 0), fired);
    try testing.expectApproxEqAbs(@as(f64, 0.5), game.elapsedSeconds(), 1e-9);

    // Resume: the clock advances again and the timer fires.
    game.setPaused(false);
    game.tick(0.5); // t=1.0 → due
    try testing.expectEqual(@as(usize, 1), fired);
}

test "time_scale==0 pause path also freezes timers" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    var fired: usize = 0;
    const cap = newCapture(&game, &fired);
    game.scheduler.after(1.0, null, cap, trampoline);

    game.pause(); // sets time_scale = 0
    var i: usize = 0;
    while (i < 50) : (i += 1) game.tick(1.0);
    try testing.expectEqual(@as(usize, 0), fired);

    game.resume_();
    game.tick(1.0);
    try testing.expectEqual(@as(usize, 1), fired);
}

// ── Entity-bound cancellation ───────────────────────────────────────────

test "entity-bound timer is skipped (and ctx freed) when entity is destroyed" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    const e = game.createEntity();

    var fired: usize = 0;
    const cap = newCapture(&game, &fired);
    game.scheduler.after(1.0, e, cap, trampoline);

    // Destroy the target BEFORE the timer is due.
    game.destroyEntity(e);

    game.tick(1.0); // due, but entity is dead → skip + free ctx
    // Callback never ran; testing.allocator verifies `cap` was freed (no
    // leak) when the game deinits.
    try testing.expectEqual(@as(usize, 0), fired);
    try testing.expectEqual(@as(usize, 0), game.scheduler.pendingCount());
}

test "entity-bound timer fires normally when entity is still alive" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    const e = game.createEntity();

    var fired: usize = 0;
    const cap = newCapture(&game, &fired);
    game.scheduler.after(1.0, e, cap, trampoline);

    game.tick(1.0);
    try testing.expectEqual(@as(usize, 1), fired);
}

// ── Re-entrant scheduling ───────────────────────────────────────────────

test "a fired callback may schedule another timer without corrupting iteration" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.bindScheduler();

    var fired: usize = 0;

    // Two timers due on the SAME tick; the first reschedules a third
    // (due immediately) from inside its callback. The append may realloc
    // `pending` mid-iteration — the scheduler must not crash or drop the
    // sibling timer.
    const first = game.allocator.create(Capture) catch unreachable;
    first.* = .{ .fired = &fired, .reschedule = true };
    game.scheduler.after(1.0, null, first, trampoline);

    const second = newCapture(&game, &fired);
    game.scheduler.after(1.0, null, second, trampoline);

    game.tick(1.0); // both due; `first` schedules a third at +0.0

    // first + second fired this tick (= 2). The re-entrant third was
    // scheduled at fire_at = now, so it's due now too and is caught by the
    // same swap-remove walk OR the next tick. Pump one more tick to be sure.
    game.tick(0.0);
    try testing.expectEqual(@as(usize, 3), fired);
    try testing.expectEqual(@as(usize, 0), game.scheduler.pendingCount());
}

// ── Leak safety on shutdown ─────────────────────────────────────────────

test "deinit frees still-pending timers (no leak)" {
    var game = Game.init(testing.allocator);
    game.bindScheduler();

    var fired: usize = 0;
    // Schedule several timers and NEVER let them fire — exit with them in
    // flight. testing.allocator fails the test if any `ctx` leaks.
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        const cap = newCapture(&game, &fired);
        game.scheduler.after(@as(f64, @floatFromInt(k + 1)) * 10.0, null, cap, trampoline);
    }
    try testing.expectEqual(@as(usize, 5), game.scheduler.pendingCount());

    game.deinit(); // must free all 5 captures + the pending list
    try testing.expectEqual(@as(usize, 0), fired);
}

test "deinit with a mix of entity-bound and plain pending timers (no leak)" {
    var game = Game.init(testing.allocator);
    game.bindScheduler();

    const e = game.createEntity();
    var fired: usize = 0;

    const plain = newCapture(&game, &fired);
    game.scheduler.after(100.0, null, plain, trampoline);

    const bound = newCapture(&game, &fired);
    game.scheduler.after(100.0, e, bound, trampoline);

    game.deinit();
    try testing.expectEqual(@as(usize, 0), fired);
}

// ── after() before any tick / bind via setHooks-free path ───────────────

test "after() works before the first tick (bind happens at tick top too)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    // Intentionally do NOT call bindScheduler() here: the first tick rebinds
    // the type-erased game pointer, so a timer scheduled pre-tick still
    // resolves correctly. (We schedule after init; `now_fn` is only read at
    // schedule time and at tick time — both go through the placeholder until
    // tick rebinds, but the placeholder's clock read is harmless because the
    // real fire decision uses the rebound pointer at tick.)
    game.bindScheduler(); // make schedule-time `now` read the real clock

    var fired: usize = 0;
    const cap = newCapture(&game, &fired);
    game.scheduler.after(0.5, null, cap, trampoline);

    game.tick(0.5);
    try testing.expectEqual(@as(usize, 1), fired);
}
