//! Buffered event payloads must outlive the drain that delivers them
//! (#862, #863).
//!
//! `HOOK-DELIVERY-CONTRACT.md` §5: an event struct is copied by value and
//! any slice inside it is BORROWED, so the referent has to outlive the
//! drain. Two engine paths broke that by freeing the referent in the same
//! call that buffered the event:
//!
//!   * #862 — `setStateOwned` freed the PREVIOUS state name right after
//!     `setState` buffered `engine__state_changed` borrowing it.
//!   * #863 — the loop's scene-transition commit freed
//!     `pending_scene_change`, and `unloadCurrentScene`'s caller freed
//!     `current_scene_name`, while `engine__scene_*` payloads borrowed
//!     them.
//!
//! The window is a FULL FRAME, not a few instructions: the generated loop
//! runs `dispatchEvents()` before `tick(dt)`, so the free happens an
//! entire iteration before the listener reads the payload.
//!
//! ## Why these tests need a poisoning allocator
//!
//! Neither bug crashes. Freed-then-read bytes usually survive intact, so
//! a listener under `testing.allocator` or a GPA reads the correct string
//! and the test passes WITH THE BUG PRESENT. `PoisonAllocator` scribbles
//! 0xDE over every freed block, which is what turns "use-after-free" into
//! an observable difference. Every assertion below is written against the
//! poisoned allocator for that reason — under a plain allocator these
//! tests prove nothing, which is precisely the trap the issues call out.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

const Entity = core.MockEcsBackend(u32).Entity;

/// Scribbles 0xDE over every freed block before handing it back, so a
/// read-after-free is visible instead of accidentally correct.
const PoisonAllocator = struct {
    inner: std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(buf, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(buf, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        @memset(buf, 0xDE);
        self.inner.rawFree(buf, alignment, ra);
    }
    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
};

/// The engine event the owned state path emits, in the shape the
/// assembler folds into `GameEvents`.
const GameEventsUnion = union(enum) {
    engine__state_changed: struct { old_state: []const u8, new_state: []const u8 },
};

/// Records what `old_state` LOOKED LIKE at delivery time. Copies into a
/// fixed buffer, because the whole question is whether the bytes are
/// still valid at this instant.
const Recorder = struct {
    seen: usize = 0,
    len: usize = 0,
    buf: [64]u8 = undefined,
    /// True if any delivered `old_state` byte was the poison pattern.
    saw_poison: bool = false,

    pub fn engine__state_changed(self: *Recorder, payload: anytype) void {
        self.seen += 1;
        const old = payload.old_state;
        for (old) |c| {
            if (c == 0xDE) self.saw_poison = true;
        }
        self.len = @min(old.len, self.buf.len);
        @memcpy(self.buf[0..self.len], old[0..self.len]);
    }

    fn lastOld(self: *const Recorder) []const u8 {
        return self.buf[0..self.len];
    }
};

const EmptyComponents = struct {};
const AllHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    GameEventsUnion,
});
const AllHooks = engine.MergeHooks(AllHookPayloads, .{*Recorder});

const Game = game_mod.GameConfig(
    core.StubRender(Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *AllHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    GameEventsUnion,
);

pub const OWNED_STATE_PAYLOAD = struct {
    test "a state_changed listener reads LIVE bytes after setStateOwned + drain (#862)" {
        // The reproduction. Pre-fix, `setStateOwned` freed the previous
        // owned slot immediately, so by the time the buffered event was
        // drained `old_state` pointed at poisoned memory.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: Recorder = .{};
        var hooks: AllHooks = .{ .receivers = .{&rec} };
        var game = Game.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);

        try game.setStateOwned("first_state");
        game.dispatchEvents();
        rec.seen = 0;
        rec.saw_poison = false;

        // The transition under test: "first_state" is the OLD name, and
        // its backing allocation is the one that used to be freed here.
        try game.setStateOwned("second_state");
        // Nothing delivered yet — the event is buffered, exactly as in the
        // generated loop where the free happened a whole frame early.
        try testing.expectEqual(@as(usize, 0), rec.seen);

        game.dispatchEvents();

        try testing.expectEqual(@as(usize, 1), rec.seen);
        try testing.expect(!rec.saw_poison);
        try testing.expectEqualStrings("first_state", rec.lastOld());
    }

    test "repeated transitions before a drain keep EVERY old name alive (#862)" {
        // One retained slot is not enough: three transitions in one frame
        // buffer three events, each borrowing a different old name, and
        // all three must survive until the single drain that delivers
        // them. A fix that kept only the most recent slot would poison the
        // earlier two.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: Recorder = .{};
        var hooks: AllHooks = .{ .receivers = .{&rec} };
        var game = Game.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);

        try game.setStateOwned("alpha");
        game.dispatchEvents();
        rec.seen = 0;
        rec.saw_poison = false;

        try game.setStateOwned("bravo");
        try game.setStateOwned("charlie");
        try game.setStateOwned("delta");
        try testing.expectEqual(@as(usize, 0), rec.seen);

        game.dispatchEvents();

        // alpha->bravo, bravo->charlie, charlie->delta.
        try testing.expectEqual(@as(usize, 3), rec.seen);
        try testing.expect(!rec.saw_poison);
        // The LAST delivered old_state is `charlie`; the earlier two were
        // checked for poison as they arrived.
        try testing.expectEqualStrings("charlie", rec.lastOld());
    }

    test "the retention list does not grow without bound across drains (#862)" {
        // The deferred free must actually happen. If retention leaked, the
        // testing allocator's leak check fails this test — which is the
        // assertion, since a fix that never frees is also wrong.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: Recorder = .{};
        var hooks: AllHooks = .{ .receivers = .{&rec} };
        var game = Game.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);

        var i: usize = 0;
        while (i < 32) : (i += 1) {
            var buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "state_{d}", .{i});
            try game.setStateOwned(name);
            game.dispatchEvents();
        }
        try testing.expect(!rec.saw_poison);
    }

    test "deinit reclaims anything still retained (#862)" {
        // A transition with NO following drain: the slot is parked for a
        // drain that never comes. `deinit`'s final flush plus its list
        // cleanup must free it, or `testing.allocator` reports a leak.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: Recorder = .{};
        var hooks: AllHooks = .{ .receivers = .{&rec} };
        var game = Game.init(allocator);
        game.setHooks(&hooks);

        try game.setStateOwned("only_state");
        try game.setStateOwned("replaced_before_any_drain");
        // No dispatchEvents() — straight to teardown.
        game.deinit();
    }
};

/// A receiver that DRAINS from inside a handler, to cover the nested case.
const NestedDrainer = struct {
    /// Injected by `setHooks`. Used instead of a `*NestedGame` field
    /// because the receiver is a member of the tuple that defines
    /// `NestedGame` — naming the type here is a comptime dependency loop.
    ctx: engine.HookContext = .{},
    /// Set by the test to arm the nested drain.
    armed: bool = false,
    seen: usize = 0,
    saw_poison: bool = false,
    /// Set once, so the nested drain happens on the first delivery only
    /// and the test cannot recurse forever.
    nested_done: bool = false,

    pub fn engine__state_changed(self: *NestedDrainer, payload: anytype) void {
        self.seen += 1;
        for (payload.old_state) |c| {
            if (c == 0xDE) self.saw_poison = true;
        }
        if (!self.nested_done and self.armed) {
            self.nested_done = true;
            {
                const g = self.ctx.gameAs(NestedGame);
                // A handler that transitions AND drains, inside a running
                // drain. The inner drain must free only what was retained
                // in its own window — freeing the outer window's slices
                // would poison the payload this very handler is holding.
                g.setStateOwned("from_inside_handler") catch {};
                g.dispatchEvents();
                // Still readable after the nested drain returned.
                for (payload.old_state) |c| {
                    if (c == 0xDE) self.saw_poison = true;
                }
            }
        }
    }
};

const NestedHooks = engine.MergeHooks(AllHookPayloads, .{*NestedDrainer});
const NestedGame = game_mod.GameConfig(
    core.StubRender(Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *NestedHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    GameEventsUnion,
);

pub const NESTED_DRAIN = struct {
    test "a nested drain does not free the outer drain's borrowed payloads (#862)" {
        // The subtle half. Retention is swapped per-drain rather than
        // freed in place, so an inner `dispatchEvents` reclaims exactly
        // the slices retained since the outer one swapped. Freeing in
        // place instead would pull the rug from under the handler that
        // triggered the nesting — it is still holding `payload.old_state`
        // across the inner call.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: NestedDrainer = .{};
        var hooks: NestedHooks = .{ .receivers = .{&rec} };
        var game = NestedGame.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);
        rec.armed = true;

        try game.setStateOwned("outer_first");
        game.dispatchEvents();
        rec.seen = 0;
        rec.saw_poison = false;
        rec.nested_done = false;

        try game.setStateOwned("outer_second");
        game.dispatchEvents();

        try testing.expect(rec.seen >= 1);
        try testing.expect(!rec.saw_poison);
    }
};


// ── #863: scene-name payloads ──────────────────────────────────────────

const SceneEventsUnion = union(enum) {
    engine__scene_loading: struct { name: []const u8 },
    engine__scene_loaded: struct { name: []const u8 },
    engine__scene_unloaded: struct { name: []const u8 },
};

/// Reads every scene-name payload at DELIVERY time and reports whether any
/// of them had been poisoned by then.
const SceneRecorder = struct {
    unloaded: usize = 0,
    loading: usize = 0,
    loaded: usize = 0,
    saw_poison: bool = false,
    last_unloaded_len: usize = 0,
    last_unloaded: [64]u8 = undefined,

    fn check(self: *SceneRecorder, name: []const u8) void {
        for (name) |c| {
            if (c == 0xDE) self.saw_poison = true;
        }
    }

    pub fn engine__scene_unloaded(self: *SceneRecorder, payload: anytype) void {
        self.unloaded += 1;
        self.check(payload.name);
        self.last_unloaded_len = @min(payload.name.len, self.last_unloaded.len);
        @memcpy(self.last_unloaded[0..self.last_unloaded_len], payload.name[0..self.last_unloaded_len]);
    }
    pub fn engine__scene_loading(self: *SceneRecorder, payload: anytype) void {
        self.loading += 1;
        self.check(payload.name);
    }
    pub fn engine__scene_loaded(self: *SceneRecorder, payload: anytype) void {
        self.loaded += 1;
        self.check(payload.name);
    }

    fn lastUnloaded(self: *const SceneRecorder) []const u8 {
        return self.last_unloaded[0..self.last_unloaded_len];
    }
};

const SceneHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    SceneEventsUnion,
});
const SceneHooks = engine.MergeHooks(SceneHookPayloads, .{*SceneRecorder});
const SceneGame = game_mod.GameConfig(
    core.StubRender(Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *SceneHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    SceneEventsUnion,
);

fn emptyLoader(_: *SceneGame) anyerror!void {}

pub const SCENE_NAME_PAYLOADS = struct {
    test "scene_unloaded's name is LIVE when the drain delivers it (#863)" {
        // `unloadCurrentScene` buffers `engine__scene_unloaded` borrowing
        // `current_scene_name`, and its caller freed that allocation
        // immediately afterwards — so the listener read freed bytes a full
        // frame later.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: SceneRecorder = .{};
        var hooks: SceneHooks = .{ .receivers = .{&rec} };
        var game = SceneGame.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        game.dispatchEvents();
        rec = .{};

        // The swap: "first_scene" is torn down, and the allocation its
        // name lives in is the one that used to be freed here.
        try game.setScene("second_scene");
        try testing.expectEqual(@as(usize, 0), rec.unloaded);

        game.dispatchEvents();

        try testing.expectEqual(@as(usize, 1), rec.unloaded);
        try testing.expect(!rec.saw_poison);
        try testing.expectEqualStrings("first_scene", rec.lastUnloaded());
    }

    test "a QUEUED scene transition keeps its name alive across the drain (#863)" {
        // The loop path. `tick` hands the owned `pending_scene_change`
        // slice to `setScene`, which buffers `scene_loading`/`scene_loaded`
        // borrowing it, and the commit block then freed it — all before
        // the next drain.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: SceneRecorder = .{};
        var hooks: SceneHooks = .{ .receivers = .{&rec} };
        var game = SceneGame.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        game.dispatchEvents();
        rec = .{};

        // Queue, then let the tick commit it — the shape the generated
        // loop produces.
        game.queueSceneChange("second_scene");
        game.tick(0.016);
        try testing.expectEqual(@as(usize, 0), rec.loaded);

        game.dispatchEvents();

        try testing.expect(rec.loading >= 1);
        try testing.expect(rec.loaded >= 1);
        try testing.expect(!rec.saw_poison);
    }

    test "repeated scene swaps before one drain keep every name alive (#863)" {
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: SceneRecorder = .{};
        var hooks: SceneHooks = .{ .receivers = .{&rec} };
        var game = SceneGame.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);
        game.registerSceneSimple("a_scene", emptyLoader);
        game.registerSceneSimple("b_scene", emptyLoader);
        game.registerSceneSimple("c_scene", emptyLoader);

        try game.setScene("a_scene");
        game.dispatchEvents();
        rec = .{};

        try game.setScene("b_scene");
        try game.setScene("c_scene");
        game.dispatchEvents();

        try testing.expect(!rec.saw_poison);
        // Only ONE unload is delivered, not two: `unloadCurrentScene`
        // starts by clearing the event buffer, so the b_scene swap wipes
        // the a_scene swap's buffered events before they are ever drained.
        // That is existing, deliberate behaviour (events from a torn-down
        // scene must not leak into the next one) and not what this test is
        // about — the point is that whatever DOES arrive is readable.
        //
        // It also means a retained slice can outlive the drain that would
        // have delivered its event. That is the safe direction: it is
        // freed one drain later than strictly necessary, never earlier.
        try testing.expectEqual(@as(usize, 1), rec.unloaded);
    }
};

test {
    testing.refAllDecls(@This());
    _ = OWNED_STATE_PAYLOAD;
    _ = NESTED_DRAIN;
    _ = SCENE_NAME_PAYLOADS;
    _ = RETENTION_ALLOCATION_FAILURE;
}

// ── Allocation failure at the retention reserve (#867 review) ──────────

pub const RETENTION_ALLOCATION_FAILURE = struct {
    test "setStateOwned aborts CLEANLY when the retention node cannot be allocated (#862)" {
        // The correction the review forced. An earlier revision retained
        // AFTER emitting and, if the retention allocation failed, freed the
        // slice — reinstating the exact use-after-free the mechanism
        // exists to prevent, with a log line in front of it. Logging does
        // not make a UAF acceptable.
        //
        // Reserving BEFORE the emit moves the only failure to a point
        // where nothing is queued yet, so the whole call can abort with
        // the game untouched. This proves that: the transition fails, no
        // event is queued, no state changes, and nothing leaks or dangles.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        var failing = std.testing.FailingAllocator.init(poison.allocator(), .{});
        const allocator = failing.allocator();

        var rec: Recorder = .{};
        var hooks: AllHooks = .{ .receivers = .{&rec} };
        var game = Game.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);

        try game.setStateOwned("before_failure");
        game.dispatchEvents();
        rec = .{};

        // Let exactly ONE more allocation through — `setStateOwned`'s dupe
        // of the new name — then fail the next, which is the retention
        // node inside `reserveRetention`.
        failing.fail_index = failing.alloc_index + 1;

        const result = game.setStateOwned("never_applied");
        try testing.expectError(error.OutOfMemory, result);

        // Stop failing so teardown and the follow-up transition can run.
        failing.fail_index = std.math.maxInt(usize);

        // The game is EXACTLY as it was: the state did not change...
        try testing.expectEqualStrings("before_failure", game.getState());
        // ...and nothing was queued, so the drain has nothing to deliver.
        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 0), rec.seen);

        // And the mechanism still works afterwards — the failure left no
        // half-state behind.
        try game.setStateOwned("after_failure");
        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 1), rec.seen);
        try testing.expect(!rec.saw_poison);
        try testing.expectEqualStrings("before_failure", rec.lastOld());
    }

    test "a queued scene transition DEFERS rather than dangling when reservation fails (#863)" {
        // `tick` cannot propagate an error, so the loop suppresses the
        // whole transition instead: nothing is emitted, and
        // `pending_scene_change` keeps ownership of the name so a later
        // frame can retry. The failure must not leave a queued payload
        // without a live referent, and must not drop the request.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        var failing = std.testing.FailingAllocator.init(poison.allocator(), .{});
        const allocator = failing.allocator();

        var rec: SceneRecorder = .{};
        var hooks: SceneHooks = .{ .receivers = .{&rec} };
        var game = SceneGame.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        game.dispatchEvents();
        rec = .{};

        game.queueSceneChange("second_scene");
        // Fail the very next allocation — the loop's retention reserve,
        // which happens before the swap emits anything.
        failing.fail_index = failing.alloc_index;
        game.tick(0.016);
        failing.fail_index = std.math.maxInt(usize);

        // Suppressed, not half-done: no scene events were buffered...
        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 0), rec.loading);
        try testing.expectEqual(@as(usize, 0), rec.loaded);
        try testing.expectEqual(@as(usize, 0), rec.unloaded);
        try testing.expect(!rec.saw_poison);
        // ...the scene did not change...
        try testing.expectEqualStrings("first_scene", game.current_scene_name.?);
        // ...and the request is still queued, so a later frame retries it
        // rather than dropping the transition forever.
        try testing.expect(game.pending_scene_change != null);

        // The retry succeeds and its payload is live.
        game.tick(0.016);
        game.dispatchEvents();
        try testing.expect(rec.loaded >= 1);
        try testing.expect(!rec.saw_poison);
    }

    test "deinit is clean when a reservation was made but never used (#862)" {
        // A reserved-but-unused node must not leak. `setState`
        // short-circuits when the name is unchanged, so no event is
        // emitted and no slice is retained — but the reservation happened.
        var poison = PoisonAllocator{ .inner = testing.allocator };
        const allocator = poison.allocator();

        var rec: Recorder = .{};
        var hooks: AllHooks = .{ .receivers = .{&rec} };
        var game = Game.init(allocator);
        game.setHooks(&hooks);

        try game.setStateOwned("same_name");
        // Same name: `setState`'s eql probe short-circuits, so this
        // reserves and never retains.
        try game.setStateOwned("same_name");
        try game.setStateOwned("same_name");

        // `testing.allocator` fails the test if any node leaked.
        game.deinit();
    }
};
