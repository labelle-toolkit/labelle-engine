const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const TweenSystem = engine.TweenSystem;
const TweenHandle = engine.TweenHandle;
const tweenTick = engine.tweenTick;
const AlwaysAlive = engine.TweenAlwaysAlive;

const dt60: f32 = 1.0 / 60.0;

// Zig has no closures — bindings are (fn ptr, *anyopaque ctx). These are
// the concrete contexts the tests bind to.
const Recorder = struct {
    last: f32 = 0,
    count: u32 = 0,
    fn applyFn(ctx: *anyopaque, v: f32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.last = v;
        self.count += 1;
    }
};

const Counter = struct {
    n: u32 = 0,
    fn cb(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.n += 1;
    }
};

fn asCtx(p: anytype) *anyopaque {
    return @ptrCast(p);
}

// ── Builder offset model ──────────────────────────────────

test "Tween builder: sequential offsets, and join parallels the previous step (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var rec = Recorder{};
    const ctx = asCtx(&rec);

    // Append: property(0.5) → interval(0.2) → property(0.3)
    // offsets 0.0 / 0.5 / 0.7, total = 0.7 + 0.3 = 1.0.
    const b = sys.create()
        .property(ctx, Recorder.applyFn, 0, 1, 0.5)
        .interval(0.2)
        .property(ctx, Recorder.applyFn, 0, 1, 0.3);
    const t = sys.get(b.handle).?;
    try testing.expectEqual(@as(u8, 3), t.step_count);
    try testing.expectApproxEqAbs(@as(f32, 0.0), t.steps[0].start_offset, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.steps[1].start_offset, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), t.steps[2].start_offset, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), t.total_duration, 1e-6);

    // With .join() before the last step, that step starts at the START of
    // the previous one (the interval, offset 0.5) — parallel, not after.
    // total = max(0.5, 0.7, 0.5+0.3) = 0.8.
    const b2 = sys.create()
        .property(ctx, Recorder.applyFn, 0, 1, 0.5)
        .interval(0.2)
        .join()
        .property(ctx, Recorder.applyFn, 0, 1, 0.3);
    const t2 = sys.get(b2.handle).?;
    try testing.expectApproxEqAbs(@as(f32, 0.0), t2.steps[0].start_offset, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), t2.steps[1].start_offset, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), t2.steps[2].start_offset, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), t2.total_duration, 1e-6);
}

// ── Interpolation + exact endpoint ────────────────────────

test "Tween: interpolates monotonically and lands exactly on `to` (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var rec = Recorder{};
    _ = sys.create().property(asCtx(&rec), Recorder.applyFn, 0, 100, 0.35).ease(.quad, .out);

    var prev: f32 = -1;
    var ticks: u32 = 0;
    while (sys.aliveCount() > 0 and ticks < 100) : (ticks += 1) {
        tweenTick(&sys, dt60, AlwaysAlive{});
        try testing.expect(rec.last >= prev - 1e-4); // non-decreasing
        try testing.expect(!std.math.isNan(rec.last));
        prev = rec.last;
    }
    try testing.expectEqual(@as(f32, 100.0), rec.last); // exact, not 99.7%
    try testing.expectEqual(@as(usize, 0), sys.aliveCount()); // retired on completion
}

// ── Callbacks ─────────────────────────────────────────────

test "Tween: callback fires exactly once even when dt skips its offset (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var cnt = Counter{};
    // callback sits at offset 0.5 (after the interval); one big dt jumps past it.
    _ = sys.create().interval(0.5).callback(asCtx(&cnt), Counter.cb);
    tweenTick(&sys, 2.0, AlwaysAlive{});
    try testing.expectEqual(@as(u32, 1), cnt.n);
    try testing.expectEqual(@as(usize, 0), sys.aliveCount());
}

test "Tween: dt=0 never double-fires a callback and is NaN-free (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var cnt = Counter{};
    var rec = Recorder{};
    _ = sys.create()
        .callback(asCtx(&cnt), Counter.cb)
        .join()
        .property(asCtx(&rec), Recorder.applyFn, 0, 10, 1.0);

    tweenTick(&sys, 0.0, AlwaysAlive{});
    tweenTick(&sys, 0.0, AlwaysAlive{});
    tweenTick(&sys, 0.0, AlwaysAlive{});
    try testing.expectEqual(@as(u32, 1), cnt.n); // fired once, not thrice
    try testing.expectEqual(@as(f32, 0.0), rec.last); // held at `from` (no time passed)
    try testing.expect(!std.math.isNan(rec.last));
    try testing.expectEqual(@as(usize, 1), sys.aliveCount()); // still running
}

// ── Loops ─────────────────────────────────────────────────

test "Tween: finite loops fire per-iteration; infinite never retires (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();

    // 3 loops of [callback @0, interval 0.1] → the callback fires 3×.
    var cnt = Counter{};
    _ = sys.create().callback(asCtx(&cnt), Counter.cb).interval(0.1).loops(3);
    var ticks: u32 = 0;
    while (sys.aliveCount() > 0 and ticks < 1000) : (ticks += 1) {
        tweenTick(&sys, dt60, AlwaysAlive{});
    }
    try testing.expectEqual(@as(u32, 3), cnt.n);

    // Infinite property loop stays alive after 1000 ticks.
    var rec = Recorder{};
    _ = sys.create().property(asCtx(&rec), Recorder.applyFn, 0, 1, 0.1).loops(0);
    var k: u32 = 0;
    while (k < 1000) : (k += 1) tweenTick(&sys, dt60, AlwaysAlive{});
    try testing.expectEqual(@as(usize, 1), sys.aliveCount());
}

// ── Entity binding (despawn safety) ───────────────────────

const MockBackend = struct {
    dead: bool = false,
    pub fn tweenEntityAlive(self: MockBackend, _: u64) bool {
        return !self.dead;
    }
};

test "Tween: entity-bound tween dies the frame its entity despawns (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var rec = Recorder{};
    _ = sys.create().property(asCtx(&rec), Recorder.applyFn, 0, 100, 10.0).bindEntity(42);

    var be = MockBackend{};
    tweenTick(&sys, 0.1, be); // entity alive → applies
    try testing.expect(rec.count >= 1);
    const count_before = rec.count;

    be.dead = true; // entity destroyed
    tweenTick(&sys, 0.1, be); // bound entity gone → killed, no apply
    try testing.expectEqual(count_before, rec.count);
    try testing.expectEqual(@as(usize, 0), sys.aliveCount());

    tweenTick(&sys, 0.1, be); // and stays dead
    try testing.expectEqual(count_before, rec.count);
}

// ── Handle generation safety ──────────────────────────────

test "Tween: a stale handle after slot reuse is a no-op (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var rec = Recorder{};

    const h1 = sys.create().property(asCtx(&rec), Recorder.applyFn, 0, 1, 1.0).handle;
    sys.kill(h1);
    try testing.expect(sys.get(h1) == null);

    // Slot 0 is reused with a bumped generation.
    const h2 = sys.create().property(asCtx(&rec), Recorder.applyFn, 0, 1, 1.0).handle;
    try testing.expectEqual(h1.index, h2.index);
    try testing.expect(h1.generation != h2.generation);

    // Killing through the stale handle must not touch the live tween.
    sys.kill(h1);
    try testing.expect(sys.get(h2) != null);
    try testing.expectEqual(@as(usize, 1), sys.aliveCount());
}

// ── Zero-allocation after preallocation ───────────────────

test "Tween: create is allocation-free after ensureCapacity (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureCapacity(1000);
    const cap_before = sys.tweens.capacity;
    try testing.expect(cap_before >= 1000);

    var rec = Recorder{};
    var k: usize = 0;
    while (k < 1000) : (k += 1) {
        _ = sys.create().property(asCtx(&rec), Recorder.applyFn, 0, 1, 1.0);
    }
    try testing.expectEqual(@as(usize, 1000), sys.aliveCount());
    // Unchanged capacity ⇒ no reallocation ⇒ create() allocated nothing.
    try testing.expectEqual(cap_before, sys.tweens.capacity);
}

// ── Reentrancy: mutate the system from inside a callback ───

const Spawner = struct {
    sys: *TweenSystem,
    rec: *Recorder,
    spawned: bool = false,
    fn cb(ctx: *anyopaque) void {
        const self: *Spawner = @ptrCast(@alignCast(ctx));
        if (!self.spawned) {
            self.spawned = true;
            // Appending here may realloc the dense array — the tick must
            // hold no Tween pointer across this call.
            _ = self.sys.create().property(@ptrCast(self.rec), Recorder.applyFn, 0, 5, 0.5);
        }
    }
};

test "Tween: creating a tween inside a callback is safe (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var rec = Recorder{};
    var sp = Spawner{ .sys = &sys, .rec = &rec };
    _ = sys.create().callback(asCtx(&sp), Spawner.cb).interval(0.1);

    tweenTick(&sys, dt60, AlwaysAlive{});
    try testing.expect(sp.spawned);

    var ticks: u32 = 0;
    while (sys.aliveCount() > 0 and ticks < 1000) : (ticks += 1) {
        tweenTick(&sys, dt60, AlwaysAlive{});
    }
    try testing.expectEqual(@as(f32, 5.0), rec.last); // the spawned tween ran to its `to`
}

const SelfKiller = struct {
    sys: *TweenSystem,
    handle: TweenHandle = undefined,
    fn cb(ctx: *anyopaque) void {
        const self: *SelfKiller = @ptrCast(@alignCast(ctx));
        self.sys.kill(self.handle);
    }
};

test "Tween: killing self inside a callback finalizes cleanly (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var sk = SelfKiller{ .sys = &sys };
    const b = sys.create().callback(asCtx(&sk), SelfKiller.cb).interval(1.0);
    sk.handle = b.handle;

    tweenTick(&sys, dt60, AlwaysAlive{});
    try testing.expect(sys.get(b.handle) == null); // dead, freed once
    try testing.expectEqual(@as(usize, 0), sys.aliveCount());

    tweenTick(&sys, dt60, AlwaysAlive{}); // must not touch the freed slot
    try testing.expectEqual(@as(usize, 0), sys.aliveCount());
}

const KillAndRespawn = struct {
    sys: *TweenSystem,
    rec: *Recorder,
    handle: TweenHandle = undefined,
    new_handle: ?TweenHandle = null,
    fn cb(ctx: *anyopaque) void {
        const self: *KillAndRespawn = @ptrCast(@alignCast(ctx));
        // Kill our own tween, then immediately create a new one — the
        // freed slot is REUSED for it (same index, bumped generation).
        self.sys.kill(self.handle);
        self.new_handle = self.sys.create()
            .property(@ptrCast(self.rec), Recorder.applyFn, 0, 7, 0.5).handle;
    }
};

test "Tween: slot reuse inside a callback does not corrupt the new tween (#669)" {
    var sys = TweenSystem.init(testing.allocator);
    defer sys.deinit();
    var rec = Recorder{};
    var kr = KillAndRespawn{ .sys = &sys, .rec = &rec };
    const b = sys.create().callback(asCtx(&kr), KillAndRespawn.cb).interval(1.0);
    kr.handle = b.handle;

    tweenTick(&sys, dt60, AlwaysAlive{});
    // The new tween took the SAME slot with a bumped generation — the
    // tick must not have clobbered its fired bits or finalized it.
    const nh = kr.new_handle.?;
    try testing.expectEqual(b.handle.index, nh.index);
    try testing.expect(b.handle.generation != nh.generation);
    try testing.expect(sys.get(nh) != null); // alive, untouched
    try testing.expectEqual(@as(usize, 1), sys.aliveCount());

    // And it plays to completion with an exact endpoint.
    var ticks: u32 = 0;
    while (sys.aliveCount() > 0 and ticks < 100) : (ticks += 1) {
        tweenTick(&sys, dt60, AlwaysAlive{});
    }
    try testing.expectEqual(@as(f32, 7.0), rec.last);
}
