//! `engine__scene_assets_acquire` and `engine__scene_before_reset` must
//! reach REAL subscribers (#864).
//!
//! Both were buffered and then discarded: `unloadCurrentScene` opened
//! with `event_buffer.clearRetainingCapacity()`, and both were queued a
//! few lines in front of it. So nothing subscribed could ever see them.
//!
//! ## Why these tests use a SCRIPT subscriber, not just hook receivers
//!
//! My first fix made both `emitEngineEventSync`, and its tests asserted
//! delivery to a `MergeHooks` listener. That passed while the bug the
//! ticket describes was still live: sync dispatches straight to the hook
//! tuple and never touches `event_buffer`, so flow `OnEvent`s and
//! language-plugin subscriptions — which read the buffer at their own
//! drain points — still got nothing. The tests proved the mechanism I had
//! changed rather than the consumer that was broken (#868 review).
//!
//! So these drive `script_contract`, a REAL buffer-reading subscriber:
//! subscribe, drain to activate, transition, drain again, poll. If the
//! events do not survive to a drain, the poll comes back empty.
//!
//! ## Script polling semantics, which shape the tests
//!
//! `labelle_event_subscribe` parks a name in a PENDING set;
//! `drainEvents` filters the frame's buffer against the ACTIVE set and
//! absorbs the pending set at the END. A subscription therefore takes
//! effect for events emitted after the current tick's drain — so every
//! test below drains ONCE to activate before the transition it measures.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const contract = engine.script_contract;

const core = engine.core;
const game_mod = engine.game_mod;

const Entity = core.MockEcsBackend(u32).Entity;

/// The two engine events under test, in the shape the assembler folds
/// into `GameEvents`.
const LifecycleEvents = union(enum) {
    engine__scene_assets_acquire: struct { name: []const u8 },
    engine__scene_before_reset: struct { name: []const u8 },
};

var hook_seq: usize = 0;

/// Stands in for a plugin controller that does pre-teardown cleanup on the
/// immediate `scene_assets_acquire` / `scene_before_reset` hooks and emits
/// a game event while doing it — carrying entity ids from the OUTGOING
/// world, which the reset is about to invalidate.
const CleanupEmitter = struct {
    game: ?*anyopaque = null,
    emitted: usize = 0,

    pub fn scene_assets_acquire(self: *CleanupEmitter, _: anytype) void {
        self.emit();
    }
    pub fn scene_before_reset(self: *CleanupEmitter, _: anytype) void {
        self.emit();
    }

    fn emit(self: *CleanupEmitter) void {
        const ptr = self.game orelse return;
        const g: *Game = @ptrCast(@alignCast(ptr));
        self.emitted += 1;
        // A payload naming the outgoing world. If this survives teardown a
        // subscriber reads ids that no longer exist.
        g.emit(.{ .engine__scene_assets_acquire = .{ .name = "from_outgoing_cleanup_hook" } });
    }
};

const Listener = struct {
    acquires: usize = 0,
    resets: usize = 0,
    /// Monotonic stamps, so ORDER is asserted rather than inferred from
    /// counts (#868 review: the previous version counted only).
    acquire_at: usize = 0,
    reset_at: usize = 0,
    /// Set by the flow-timing test so the handler can observe which scene
    /// is active AT DELIVERY.
    game: ?*anyopaque = null,
    scene_at_reset_len: usize = 0,
    scene_at_reset_buf: [64]u8 = undefined,
    last_acquire_len: usize = 0,
    last_acquire: [64]u8 = undefined,
    last_reset_len: usize = 0,
    last_reset: [64]u8 = undefined,

    pub fn engine__scene_assets_acquire(self: *Listener, payload: anytype) void {
        self.acquires += 1;
        hook_seq += 1;
        self.acquire_at = hook_seq;
        self.last_acquire_len = @min(payload.name.len, self.last_acquire.len);
        @memcpy(self.last_acquire[0..self.last_acquire_len], payload.name[0..self.last_acquire_len]);
    }
    pub fn engine__scene_before_reset(self: *Listener, payload: anytype) void {
        self.resets += 1;
        hook_seq += 1;
        self.reset_at = hook_seq;
        if (self.game) |ptr| {
            const g: *Game = @ptrCast(@alignCast(ptr));
            if (g.current_scene_name) |cur| {
                self.scene_at_reset_len = @min(cur.len, self.scene_at_reset_buf.len);
                @memcpy(self.scene_at_reset_buf[0..self.scene_at_reset_len], cur[0..self.scene_at_reset_len]);
            }
        }
        self.last_reset_len = @min(payload.name.len, self.last_reset.len);
        @memcpy(self.last_reset[0..self.last_reset_len], payload.name[0..self.last_reset_len]);
    }

    fn lastAcquire(self: *const Listener) []const u8 {
        return self.last_acquire[0..self.last_acquire_len];
    }
    fn lastReset(self: *const Listener) []const u8 {
        return self.last_reset[0..self.last_reset_len];
    }

    /// Which scene was ACTIVE when `before_reset` was delivered.
    fn scene_at_reset(self: *const Listener) []const u8 {
        return self.scene_at_reset_buf[0..self.scene_at_reset_len];
    }
};

/// A real `ComponentRegistry`, not a bare struct: `script_contract`
/// reflects over `.names` to route component calls, so the bare
/// placeholder these tests started with does not satisfy it.
const Marker = struct { on: bool = false };
const EmptyComponents = engine.ComponentRegistry(.{ .Marker = Marker });
const AllHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    LifecycleEvents,
});
/// Both receivers share ONE tuple because `Game` is parameterised on its
/// hooks type — a second tuple would be a second `Game`. Tests that do not
/// exercise the cleanup path leave its `game` null, so it emits nothing.
const AllHooks = engine.MergeHooks(AllHookPayloads, .{ *Listener, *CleanupEmitter });

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
    LifecycleEvents,
);

fn emptyLoader(_: *Game) anyerror!void {}

fn subscribe(name: []const u8) void {
    contract.labelle_event_subscribe(name.ptr, name.len);
}

fn poll(buf: []u8) []const u8 {
    const n = contract.labelle_event_poll(buf.ptr, buf.len);
    return buf[0..n];
}

/// Drain every pending event a subscriber can see, in order.
fn pollAll(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var buf: [512]u8 = undefined;
    while (true) {
        const got = poll(&buf);
        if (got.len == 0) return;
        try out.append(allocator, try allocator.dupe(u8, got));
    }
}

fn indexOfName(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |line, i| {
        if (std.mem.startsWith(u8, line, name)) return i;
    }
    return null;
}

fn countName(list: []const []const u8, name: []const u8) usize {
    var n: usize = 0;
    for (list) |line| {
        if (std.mem.startsWith(u8, line, name)) n += 1;
    }
    return n;
}

pub const SCENE_LIFECYCLE_EVENTS = struct {
    test "a SCRIPT subscriber receives both lifecycle events (#864)" {
        // The regression that matters. A buffer-reading subscriber is the
        // consumer the ticket is about, and the one my first fix missed.
        const allocator = testing.allocator;
        var game = Game.init(allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var cleanup_off: CleanupEmitter = .{};
        var hooks: AllHooks = .{ .receivers = .{ &listener, &cleanup_off } };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        contract.bind(&game);
        defer contract.unbind();
        subscribe("engine__scene_assets_acquire");
        subscribe("engine__scene_before_reset");
        // Subscriptions activate at the END of a drain, so this one arms
        // them without delivering anything.
        contract.drainEvents(&game);

        try game.setScene("first_scene");
        try game.setSceneAtomic("second_scene");

        contract.drainEvents(&game);

        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |l| allocator.free(l);
            lines.deinit(allocator);
        }
        try pollAll(allocator, &lines);

        const acq = indexOfName(lines.items, "engine__scene_assets_acquire");
        const rst = indexOfName(lines.items, "engine__scene_before_reset");
        try testing.expect(acq != null);
        try testing.expect(rst != null);

        // ORDER, not merely presence: `before_reset` announces the teardown
        // of the OUTGOING scene and must arrive after the acquire that
        // opened this transition. Counting alone would pass on a reordering
        // that made the pair meaningless.
        try testing.expect(acq.? < rst.?);

        // No DUPLICATE delivery — the clear moved, it did not vanish, and a
        // second copy would mean the buffer is being replayed.
        try testing.expectEqual(@as(usize, 1), countName(lines.items, "engine__scene_before_reset"));
    }

    test "a script subscriber gets NOTHING from the outgoing scene's own events (#864)" {
        // The clear still does its job: events the outgoing scene queued
        // are dropped, because its entities are about to be destroyed and
        // the ids in those payloads would be dead. Moving the clear must
        // not have turned that off.
        const allocator = testing.allocator;
        var game = Game.init(allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var cleanup_off: CleanupEmitter = .{};
        var hooks: AllHooks = .{ .receivers = .{ &listener, &cleanup_off } };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        contract.bind(&game);
        defer contract.unbind();
        subscribe("engine__scene_assets_acquire");
        contract.drainEvents(&game);

        try game.setScene("first_scene");
        contract.drainEvents(&game);
        var warm: std.ArrayList([]const u8) = .empty;
        defer {
            for (warm.items) |l| allocator.free(l);
            warm.deinit(allocator);
        }
        try pollAll(allocator, &warm);

        // Queue an event as the outgoing scene, then transition.
        game.emit(.{ .engine__scene_assets_acquire = .{ .name = "stale_from_outgoing" } });
        try game.setScene("second_scene");
        contract.drainEvents(&game);

        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |l| allocator.free(l);
            lines.deinit(allocator);
        }
        try pollAll(allocator, &lines);

        for (lines.items) |line| {
            try testing.expect(std.mem.indexOf(u8, line, "stale_from_outgoing") == null);
        }
        // …while the transition's OWN announcement still arrives.
        try testing.expect(indexOfName(lines.items, "engine__scene_assets_acquire") != null);
    }

    test "hook receivers still get both, in order, exactly once (#864)" {
        // The half that already worked, kept honest: `emitHook` dispatches
        // immediately and must not have regressed, must not double-fire,
        // and must keep acquire-before-reset ordering.
        var game = Game.init(testing.allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var cleanup_off: CleanupEmitter = .{};
        var hooks: AllHooks = .{ .receivers = .{ &listener, &cleanup_off } };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        listener = .{};

        try game.setSceneAtomic("second_scene");
        // BUFFERED, so nothing has been delivered yet — the fix restores
        // the ordinary drain timing rather than dispatching at the emit.
        try testing.expectEqual(@as(usize, 0), listener.acquires);

        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 1), listener.acquires);
        try testing.expectEqual(@as(usize, 1), listener.resets);
        try testing.expect(listener.acquire_at < listener.reset_at);
        try testing.expectEqualStrings("second_scene", listener.lastAcquire());
        try testing.expectEqualStrings("first_scene", listener.lastReset());

        // A drain afterwards must not deliver the hook twins a second time.
        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 1), listener.acquires);
        try testing.expectEqual(@as(usize, 1), listener.resets);
    }

    test "events emitted BY the cleanup hooks are discarded; announcements survive once (#868)" {
        // The regression for a hazard I introduced. Moving the clear ahead
        // of the immediate lifecycle hooks let THEIR emissions survive the
        // teardown — payloads full of entity ids the reset invalidates,
        // delivered a frame later as if they were live. The clear now sits
        // after the last lifecycle hook and before the announcements, so
        // both properties hold at once.
        const allocator = testing.allocator;
        var game = Game.init(allocator);
        defer game.deinit();
        var cleanup: CleanupEmitter = .{ .game = &game };
        var quiet: Listener = .{};
        var hooks: AllHooks = .{ .receivers = .{ &quiet, &cleanup } };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        contract.bind(&game);
        defer contract.unbind();
        subscribe("engine__scene_assets_acquire");
        subscribe("engine__scene_before_reset");
        contract.drainEvents(&game);

        try game.setScene("first_scene");
        contract.drainEvents(&game);
        var warm: std.ArrayList([]const u8) = .empty;
        defer {
            for (warm.items) |l| allocator.free(l);
            warm.deinit(allocator);
        }
        try pollAll(allocator, &warm);

        try game.setSceneAtomic("second_scene");
        // The cleanup hooks really did run and really did emit — otherwise
        // this test would prove nothing about discarding their output.
        try testing.expect(cleanup.emitted > 0);

        contract.drainEvents(&game);
        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |l| allocator.free(l);
            lines.deinit(allocator);
        }
        try pollAll(allocator, &lines);

        // The hooks' own emission is GONE…
        for (lines.items) |line| {
            try testing.expect(std.mem.indexOf(u8, line, "from_outgoing_cleanup_hook") == null);
        }
        // …while both announcements arrive, EXACTLY ONCE each.
        try testing.expectEqual(@as(usize, 1), countName(lines.items, "engine__scene_assets_acquire"));
        try testing.expectEqual(@as(usize, 1), countName(lines.items, "engine__scene_before_reset"));
        // …in the order that describes the transition.
        try testing.expect(indexOfName(lines.items, "engine__scene_assets_acquire").? <
            indexOfName(lines.items, "engine__scene_before_reset").?);
    }

    test "a FLOW-shaped receiver sees before_reset only AFTER the teardown (#864)" {
        // What a generated flow listener actually is: labelle-assembler
        // lowers an `OnEvent` flow to a `pub const FlowEventHandler` and
        // appends `*FlowEventHandler` to the `GameHooks` receiver tuple
        // (flow_scanner.zig:318-322). So a flow consumes engine events
        // through `MergeHooks` — the same dispatch this `Listener` stands
        // in for — NOT by reading the buffer the way a language plugin
        // does.
        //
        // Which fixes the TIMING, and the timing is the point here. A
        // BUFFERED event reaches the tuple at the drain, and the drain
        // happens after the swap has completed. So a flow listening for
        // `engine__scene_before_reset` is told that a reset HAPPENED; it
        // cannot use the outgoing world, because that world is gone by
        // then. Pre-teardown cleanup is the `emitHook` twin's job.
        //
        // Asserted by observing the game state AT DELIVERY, not by
        // reasoning about it.
        var game = Game.init(testing.allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var cleanup_off: CleanupEmitter = .{};
        var hooks: AllHooks = .{ .receivers = .{ &listener, &cleanup_off } };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        game.dispatchEvents();
        listener = .{};
        listener.game = &game;

        try game.setSceneAtomic("second_scene");
        // Nothing yet — buffered.
        try testing.expectEqual(@as(usize, 0), listener.resets);

        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 1), listener.resets);
        // It names the scene that WAS torn down…
        try testing.expectEqualStrings("first_scene", listener.lastReset());
        // …but by the time it arrives, that scene is already gone and the
        // incoming one is active. A handler here cannot touch the outgoing
        // ECS, and the contract says so rather than letting someone find
        // out the hard way.
        try testing.expectEqualStrings("second_scene", listener.scene_at_reset());
    }

    test "before_reset does NOT fire on a first load, which has nothing to tear down (#864)" {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var cleanup_off: CleanupEmitter = .{};
        var hooks: AllHooks = .{ .receivers = .{ &listener, &cleanup_off } };
        game.setHooks(&hooks);
        game.registerSceneSimple("only_scene", emptyLoader);

        try game.setSceneAtomic("only_scene");
        game.dispatchEvents();

        try testing.expectEqual(@as(usize, 0), listener.resets);
        // The acquire DOES fire — it is about the incoming scene.
        try testing.expectEqual(@as(usize, 1), listener.acquires);
        try testing.expectEqualStrings("only_scene", listener.lastAcquire());
    }
};

test {
    testing.refAllDecls(@This());
    _ = SCENE_LIFECYCLE_EVENTS;
}
