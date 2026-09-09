//! `engine__scene_assets_acquire` and `engine__scene_before_reset` must
//! actually reach a listener (#864).
//!
//! Both were BUFFERED and then discarded: `unloadCurrentScene` opens with
//! `event_buffer.clearRetainingCapacity()`, and both events were queued a
//! few lines before it. So a flow — or any listener on the `engine__*`
//! name — could never fire, with no error and no warning.
//!
//! The asymmetry is what made it invisible. Both are dual-emits (#578):
//! the `emitHook` half dispatches IMMEDIATELY and always worked, so the
//! feature behaved correctly from native code and silently did nothing
//! from a flow. A test on the hook half would have passed throughout.
//!
//! These tests therefore listen on the `engine__*` variants specifically,
//! and drive the REAL `setScene` / `setSceneAtomic` paths. The existing
//! contract suite pins `unloadCurrentScene`'s buffer-clearing in
//! isolation, which is exactly why it did not catch this: the clear is
//! correct, and the bug is that something was queued in front of it.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

const Entity = core.MockEcsBackend(u32).Entity;

/// The two engine events under test, in the shape the assembler folds
/// into `GameEvents`.
const LifecycleEvents = union(enum) {
    engine__scene_assets_acquire: struct { name: []const u8 },
    engine__scene_before_reset: struct { name: []const u8 },
};

const Listener = struct {
    acquires: usize = 0,
    resets: usize = 0,
    last_acquire_len: usize = 0,
    last_acquire: [64]u8 = undefined,
    last_reset_len: usize = 0,
    last_reset: [64]u8 = undefined,

    pub fn engine__scene_assets_acquire(self: *Listener, payload: anytype) void {
        self.acquires += 1;
        self.last_acquire_len = @min(payload.name.len, self.last_acquire.len);
        @memcpy(self.last_acquire[0..self.last_acquire_len], payload.name[0..self.last_acquire_len]);
    }
    pub fn engine__scene_before_reset(self: *Listener, payload: anytype) void {
        self.resets += 1;
        self.last_reset_len = @min(payload.name.len, self.last_reset.len);
        @memcpy(self.last_reset[0..self.last_reset_len], payload.name[0..self.last_reset_len]);
    }

    fn lastAcquire(self: *const Listener) []const u8 {
        return self.last_acquire[0..self.last_acquire_len];
    }
    fn lastReset(self: *const Listener) []const u8 {
        return self.last_reset[0..self.last_reset_len];
    }
};

const EmptyComponents = struct {};
const AllHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    LifecycleEvents,
});
const AllHooks = engine.MergeHooks(AllHookPayloads, .{*Listener});

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

pub const SCENE_LIFECYCLE_EVENTS = struct {
    test "engine__scene_assets_acquire reaches a listener through the real setScene (#864)" {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var hooks: AllHooks = .{ .receivers = .{&listener} };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        listener = .{};

        try game.setScene("second_scene");

        // Synchronous: observable WITHOUT a drain. That is the fix — the
        // buffered form never survived to any drain at all.
        try testing.expectEqual(@as(usize, 1), listener.acquires);
        try testing.expectEqualStrings("second_scene", listener.lastAcquire());

        // And a drain does not double-deliver it.
        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 1), listener.acquires);
    }

    test "engine__scene_before_reset reaches a listener through setSceneAtomic (#864)" {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var hooks: AllHooks = .{ .receivers = .{&listener} };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        listener = .{};

        try game.setSceneAtomic("second_scene");

        try testing.expectEqual(@as(usize, 1), listener.resets);
        // Names the OUTGOING scene — the one about to be torn down. An
        // event named for what it precedes has to describe the world that
        // still exists.
        try testing.expectEqualStrings("first_scene", listener.lastReset());

        game.dispatchEvents();
        try testing.expectEqual(@as(usize, 1), listener.resets);
    }

    test "before_reset does NOT fire on a first load, which has nothing to tear down (#864)" {
        // Guards the fix against over-firing: making these synchronous
        // must not start announcing a reset that is not happening.
        var game = Game.init(testing.allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var hooks: AllHooks = .{ .receivers = .{&listener} };
        game.setHooks(&hooks);
        game.registerSceneSimple("only_scene", emptyLoader);

        try game.setSceneAtomic("only_scene");

        try testing.expectEqual(@as(usize, 0), listener.resets);
        // The acquire DOES fire on a first load — it is about the incoming
        // scene, not the outgoing one.
        try testing.expectEqual(@as(usize, 1), listener.acquires);
        try testing.expectEqualStrings("only_scene", listener.lastAcquire());
    }

    test "the atomic path fires acquire AND before_reset, in that order (#864)" {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        var listener: Listener = .{};
        var hooks: AllHooks = .{ .receivers = .{&listener} };
        game.setHooks(&hooks);
        game.registerSceneSimple("first_scene", emptyLoader);
        game.registerSceneSimple("second_scene", emptyLoader);

        try game.setScene("first_scene");
        listener = .{};

        try game.setSceneAtomic("second_scene");
        try testing.expectEqual(@as(usize, 1), listener.acquires);
        try testing.expectEqual(@as(usize, 1), listener.resets);
        // Both landed, naming the scene each is about.
        try testing.expectEqualStrings("second_scene", listener.lastAcquire());
        try testing.expectEqualStrings("first_scene", listener.lastReset());
    }
};

test {
    testing.refAllDecls(@This());
    _ = SCENE_LIFECYCLE_EVENTS;
}
