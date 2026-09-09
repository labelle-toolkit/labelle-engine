//! #856 — fallible event enqueue: `Game.tryEmit`.
//!
//! `Game.emit` appends the event to the frame buffer and, on allocation
//! failure, logs and returns `void`. A producer that uses events to
//! invalidate a cached view or maintain a derived counter therefore
//! cannot tell that its notification was dropped — it cannot retry and
//! it cannot degrade.
//!
//! `tryEmit` is the fallible sibling: same buffer, same end-of-frame
//! drain, but enqueue failure comes back as `error.OutOfMemory`. `emit`
//! is unchanged and is now literally `tryEmit` plus the historical
//! catch-and-log, so both paths share one enqueue.
//!
//! The failure path is driven with `std.testing.FailingAllocator`. Note
//! that `ArrayList.ensureTotalCapacityPrecise` tries `remap` BEFORE
//! `alloc`, so arming `fail_index` alone is not enough — both
//! `fail_index` and `resize_fail_index` have to be armed, and the buffer
//! has to be sitting exactly at capacity so the append actually has to
//! grow.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

// A tiny game-event union in the shape the assembler generates: one
// notification a producer uses to keep a derived view in sync.
const CacheEvents = union(enum) {
    inventory_changed: struct { slot: u32 },
};

// Receiver for the buffered drain. Records what actually got delivered.
const Recorder = struct {
    delivered: usize = 0,
    slots: [32]u32 = [_]u32{0} ** 32,

    pub fn inventory_changed(self: *Recorder, info: anytype) void {
        if (self.delivered < self.slots.len) self.slots[self.delivered] = info.slot;
        self.delivered += 1;
    }
};

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const TestGame = game_mod.GameConfig(
    core.StubRender(core.MockEcsBackend(u32).Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *Recorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    CacheEvents,
);

fn ev(slot: u32) CacheEvents {
    return .{ .inventory_changed = .{ .slot = slot } };
}

/// Park the event buffer at exactly `items.len == capacity`, so the NEXT
/// append is guaranteed to hit the grow path (and therefore the
/// allocator). The capacity is pinned to a small precise value first —
/// ArrayList's own growth curve would otherwise queue dozens of events
/// before the boundary and make the assertions below unreadable.
/// Returns how many events are queued.
const prefill = 4;

fn fillToCapacity(game: *TestGame) !usize {
    try game.event_buffer.ensureTotalCapacityPrecise(game.allocator, prefill);
    while (game.event_buffer.items.len < game.event_buffer.capacity) {
        try game.tryEmit(ev(@intCast(game.event_buffer.items.len)));
    }
    return game.event_buffer.items.len;
}

/// Arm the allocator so the next grow fails on BOTH the in-place remap
/// and the fresh allocation ArrayList falls back to.
fn armOom(failing: *std.testing.FailingAllocator) void {
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
}

fn healOom(failing: *std.testing.FailingAllocator) void {
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
}

// ── The failure path ───────────────────────────────────────────────────

test "tryEmit reports enqueue failure to the producer (#856)" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var recorder = Recorder{};
    var game = TestGame.init(failing.allocator());
    defer game.deinit();
    game.setHooks(&recorder);

    const queued = try fillToCapacity(&game);
    try testing.expect(queued > 0);

    armOom(&failing);

    // THE point of this issue: the producer sees the loss.
    try testing.expectError(error.OutOfMemory, game.tryEmit(ev(999)));

    healOom(&failing);
}

test "a failed tryEmit leaves the queue intact — no partial, no duplicate (#856)" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var recorder = Recorder{};
    var game = TestGame.init(failing.allocator());
    defer game.deinit();
    game.setHooks(&recorder);

    const queued = try fillToCapacity(&game);

    armOom(&failing);
    try testing.expectError(error.OutOfMemory, game.tryEmit(ev(999)));
    // The buffer did not move: the rejected event was queued neither
    // partially nor at all.
    try testing.expectEqual(queued, game.event_buffer.items.len);
    healOom(&failing);

    // The drain delivers exactly the events that were accepted, in emit
    // order, and never the rejected one.
    game.dispatchEvents();
    try testing.expectEqual(queued, recorder.delivered);
    for (0..queued) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), recorder.slots[i]);
    }
}

test "a producer can retry after a failed tryEmit and the event lands exactly once (#856)" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var recorder = Recorder{};
    var game = TestGame.init(failing.allocator());
    defer game.deinit();
    game.setHooks(&recorder);

    const queued = try fillToCapacity(&game);

    // Model the documented recovery pattern: the mutation already
    // happened, so on enqueue failure the producer raises a dirty flag
    // instead of rolling anything back.
    var view_dirty = false;
    armOom(&failing);
    game.tryEmit(ev(999)) catch {
        view_dirty = true;
    };
    try testing.expect(view_dirty);
    healOom(&failing);

    // Later frame: reconcile.
    try game.tryEmit(ev(999));
    view_dirty = false;

    game.dispatchEvents();
    try testing.expectEqual(queued + 1, recorder.delivered);
    // Exactly one delivery of the retried event, and it is last.
    try testing.expectEqual(@as(u32, 999), recorder.slots[queued]);
    var count_999: usize = 0;
    for (recorder.slots[0 .. queued + 1]) |s| {
        if (s == 999) count_999 += 1;
    }
    try testing.expectEqual(@as(usize, 1), count_999);
}

// ── Back-compat: the infallible call site is unchanged ─────────────────

test "emit stays infallible and still swallows enqueue failure (#856 back-compat)" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var recorder = Recorder{};
    var game = TestGame.init(failing.allocator());
    defer game.deinit();
    game.setHooks(&recorder);

    const queued = try fillToCapacity(&game);

    armOom(&failing);
    // Compiles as a bare statement — no `try`, no `catch`, no discard.
    // That is the whole back-compat guarantee: every existing
    // `game.emit(...)` call site keeps its shape and its behaviour.
    game.emit(ev(999));
    // Swallowed: the queue is untouched and the caller learned nothing.
    try testing.expectEqual(queued, game.event_buffer.items.len);
    healOom(&failing);

    game.dispatchEvents();
    try testing.expectEqual(queued, recorder.delivered);
}

test "emit and tryEmit share one queue and preserve emit order (#856)" {
    var recorder = Recorder{};
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.emit(ev(1));
    try game.tryEmit(ev(2));
    game.emit(ev(3));
    try game.tryEmit(ev(4));

    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 4), recorder.delivered);
    try testing.expectEqual(@as(u32, 1), recorder.slots[0]);
    try testing.expectEqual(@as(u32, 2), recorder.slots[1]);
    try testing.expectEqual(@as(u32, 3), recorder.slots[2]);
    try testing.expectEqual(@as(u32, 4), recorder.slots[3]);
}

test "the happy path still means 'queued', not 'delivered' (#856)" {
    var recorder = Recorder{};
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    try game.tryEmit(ev(7));
    // Success returned, but no listener has run yet — delivery is the
    // end-of-frame drain's job.
    try testing.expectEqual(@as(usize, 0), recorder.delivered);

    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 1), recorder.delivered);
    try testing.expectEqual(@as(u32, 7), recorder.slots[0]);
}

// ── Games with no declared events ──────────────────────────────────────

test "tryEmit is a no-op success when the game declares no events (#856)" {
    // `engine.Game` is the `GameWith(void)` shape: `GameEvents == void`,
    // no buffer, no listeners. `tryEmit` must fold away and return
    // success — "nothing was dropped", not "an event is pending" — so a
    // producer written with `try` keeps compiling in an event-less build.
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    try game.tryEmit({});
    game.emit({});
    game.dispatchEvents();
}

test "engine.EmitError is the enqueue error set (#856)" {
    // Producers spell the type out in their own signatures; keep it
    // pinned to the allocator error set.
    try testing.expectEqual(std.mem.Allocator.Error, engine.EmitError);
    try testing.expectEqual(engine.EmitError, TestGame.EmitError);
}
