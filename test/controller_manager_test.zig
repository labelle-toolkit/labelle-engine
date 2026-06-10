//! Tests for the `ControllerManager` — game-facing player↔controller
//! mapping (labelle-engine#611).
//!
//! Two layers:
//!   1. UNIT — drive `engine.ControllerManager` directly (no `Game`):
//!      unassigned pool, assignment/query API, debounced-lost, guid resume,
//!      raylib heuristic resume, opt-in policy helpers.
//!   2. INTEGRATION — through `Game.tick`, with a `TestInput` backend that
//!      injects `core.GamepadEvent`s (same pattern as
//!      `input_events_test.zig`): the engine drains them, feeds the
//!      manager, and re-emits player-level engine events; the opt-in
//!      auto-pause is exercised end to end.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

const Manager = engine.DefaultControllerManager;
const ManagerEvent = engine.ControllerManagerEvent;

// ── helpers ─────────────────────────────────────────────────────────────

fn connectedGuid(slot: u32, name: []const u8, guid: [16]u8) core.GamepadEvent {
    var ev = core.GamepadEvent.connected(slot, name);
    ev.guid = guid;
    return ev;
}

const G1: [16]u8 = .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
const G2: [16]u8 = .{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 };

/// Drain the manager and count events by tag.
const Counts = struct {
    available: usize = 0,
    removed: usize = 0,
    joined: usize = 0,
    lost: usize = 0,
    restored: usize = 0,
    last_joined_player: u32 = 0,
    last_joined_controller: u32 = 0,
    last_lost_player: u32 = 0,
    last_restored_player: u32 = 0,
    last_restored_controller: u32 = 0,
    last_available_controller: u32 = 0,
};

fn drain(m: *Manager) Counts {
    var buf: [Manager.event_capacity]ManagerEvent = undefined;
    const n = m.drainEvents(&buf);
    var c = Counts{};
    for (buf[0..n]) |ev| switch (ev) {
        .controller_available => |x| {
            c.available += 1;
            c.last_available_controller = x.controller_id;
        },
        .controller_removed => c.removed += 1,
        .player_joined => |x| {
            c.joined += 1;
            c.last_joined_player = x.player;
            c.last_joined_controller = x.controller_id;
        },
        .player_controller_lost => |x| {
            c.lost += 1;
            c.last_lost_player = x.player;
        },
        .player_controller_restored => |x| {
            c.restored += 1;
            c.last_restored_player = x.player;
            c.last_restored_controller = x.controller_id;
        },
    };
    return c;
}

// ── Unassigned pool ──────────────────────────────────────────────────────

test "a connect lands in the unassigned pool and fires controller_available" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(0, "Pad A"));

    const c = drain(&m);
    try testing.expectEqual(@as(usize, 1), c.available);
    try testing.expectEqual(@as(u32, 0), c.last_available_controller);
    try testing.expectEqual(@as(usize, 1), m.availableCount());
    try testing.expect(m.isAvailable(0));
    // Unassigned → no player.
    try testing.expectEqual(engine.NO_PLAYER, m.playerFor(0));
}

test "unplugging a pooled (unassigned) controller fires controller_removed" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(0, "Pad A"));
    _ = drain(&m);

    m.onDisconnected(0);
    const c = drain(&m);
    try testing.expectEqual(@as(usize, 1), c.removed);
    try testing.expectEqual(@as(usize, 0), m.availableCount());
}

test "availableControllers snapshots the pool" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(0, "A"));
    m.onConnected(core.GamepadEvent.connected(5, "B"));
    _ = drain(&m);

    var snap: [4]engine.ControllerInfo = undefined;
    const n = m.availableControllers(&snap);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("A", snap[0].nameSlice());
    try testing.expectEqual(@as(u32, 5), snap[1].controller_id);
}

// ── Assignment API ─────────────────────────────────────────────────────────

test "assign binds a pooled controller to a player and fires player_joined" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(2, "Pad"));
    _ = drain(&m);

    try m.assign(2, 0);
    const c = drain(&m);
    try testing.expectEqual(@as(usize, 1), c.joined);
    try testing.expectEqual(@as(u32, 0), c.last_joined_player);
    try testing.expectEqual(@as(u32, 2), c.last_joined_controller);

    // Bidirectional query + pool removal.
    try testing.expectEqual(@as(u32, 0), m.playerFor(2));
    try testing.expectEqual(@as(u32, 2), m.controllerFor(0));
    try testing.expect(!m.isAvailable(2));
    try testing.expect(m.isPlayerActive(0));
}

test "assigning an unavailable controller errors" {
    var m = Manager.init(.{});
    try testing.expectError(error.ControllerNotAvailable, m.assign(9, 0));
}

test "assigning to an out-of-range player errors" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(0, "P"));
    _ = drain(&m);
    try testing.expectError(error.PlayerOutOfRange, m.assign(0, 999));
}

test "unassign releases the controller back to the pool" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(1, "P"));
    _ = drain(&m);
    try m.assign(1, 0);
    _ = drain(&m);

    m.unassign(0);
    const c = drain(&m);
    // Released controller re-enters the pool with a fresh availability.
    try testing.expectEqual(@as(usize, 1), c.available);
    try testing.expect(m.isAvailable(1));
    try testing.expect(!m.isPlayerActive(0));
    try testing.expectEqual(engine.NO_PLAYER, m.playerFor(1));
}

// ── Debounced-lost (engine-owned, the headline TV feature) ─────────────────

test "a transient drop within the debounce window does NOT fire lost" {
    var m = Manager.init(.{ .debounce_lost_seconds = 0.2 });
    m.onConnected(connectedGuid(0, "Pad", G1));
    _ = drain(&m);
    try m.assign(0, 0);
    _ = drain(&m);

    // Drop at t=0, reconnect at t=0.1 (inside the 0.2s window).
    m.advance(0.0);
    m.onDisconnected(0);
    m.advance(0.1);
    m.onConnected(connectedGuid(0, "Pad", G1)); // same guid

    const c = drain(&m);
    // No lost (debounce never expired); a restored fires so a prompt can
    // clear, but crucially NEVER the {lost, restored} churn pair.
    try testing.expectEqual(@as(usize, 0), c.lost);
    try testing.expectEqual(@as(usize, 1), c.restored);
    try testing.expectEqual(@as(u32, 0), m.controllerFor(0)); // rebound
    try testing.expect(!m.isPlayerWaiting(0));
}

test "a drop past the debounce window fires player_controller_lost" {
    var m = Manager.init(.{ .debounce_lost_seconds = 0.2 });
    m.onConnected(connectedGuid(0, "Pad", G1));
    _ = drain(&m);
    try m.assign(0, 0);
    _ = drain(&m);

    m.advance(0.0);
    m.onDisconnected(0);
    // Clock crosses the deadline with no reconnect.
    m.advance(0.5);

    const c = drain(&m);
    try testing.expectEqual(@as(usize, 1), c.lost);
    try testing.expectEqual(@as(u32, 0), c.last_lost_player);
    try testing.expect(m.isPlayerWaiting(0));
    try testing.expectEqual(engine.NO_CONTROLLER, m.controllerFor(0));
}

test "debounce disabled (0s) reports lost immediately on disconnect" {
    var m = Manager.init(.{ .debounce_lost_seconds = 0 });
    m.onConnected(connectedGuid(0, "Pad", G1));
    _ = drain(&m);
    try m.assign(0, 0);
    _ = drain(&m);

    m.advance(0.0);
    m.onDisconnected(0);
    const c = drain(&m);
    try testing.expectEqual(@as(usize, 1), c.lost);
}

// ── Identity-based resume (guid) ──────────────────────────────────────────

test "a same-guid replug after a real loss restores the SAME player" {
    var m = Manager.init(.{ .debounce_lost_seconds = 0.2 });
    m.onConnected(connectedGuid(3, "Pad", G1));
    _ = drain(&m);
    try m.assign(3, 1); // player 1
    _ = drain(&m);

    m.advance(0.0);
    m.onDisconnected(3);
    m.advance(1.0); // truly lost
    try testing.expectEqual(@as(usize, 1), drain(&m).lost);

    // Replug on a DIFFERENT slot (Linux returns a new js* index) but same guid.
    m.onConnected(connectedGuid(9, "Pad", G1));
    const c = drain(&m);
    try testing.expectEqual(@as(usize, 1), c.restored);
    try testing.expectEqual(@as(u32, 1), c.last_restored_player);
    try testing.expectEqual(@as(u32, 9), c.last_restored_controller);
    // Player 1 now backed by the new slot; no new pool entry.
    try testing.expectEqual(@as(u32, 9), m.controllerFor(1));
    try testing.expectEqual(@as(u32, 1), m.playerFor(9));
    try testing.expectEqual(@as(usize, 0), m.availableCount());
}

test "a different-guid controller after a loss does NOT hijack the player; it pools" {
    var m = Manager.init(.{ .debounce_lost_seconds = 0.2 });
    m.onConnected(connectedGuid(0, "Pad1", G1));
    _ = drain(&m);
    try m.assign(0, 0);
    _ = drain(&m);

    m.advance(0.0);
    m.onDisconnected(0);
    m.advance(1.0);
    _ = drain(&m);

    // A genuinely different device (G2) connects — guid match fails, so it
    // must NOT steal player 0; it joins the pool instead.
    m.onConnected(connectedGuid(7, "Pad2", G2));
    const c = drain(&m);
    try testing.expectEqual(@as(usize, 0), c.restored);
    try testing.expectEqual(@as(usize, 1), c.available);
    try testing.expect(m.isPlayerWaiting(0)); // still waiting
}

// ── raylib heuristic resume (no stable key) ───────────────────────────────

test "with no guid, the next controller resumes the most-recently-vacated player" {
    var m = Manager.init(.{ .debounce_lost_seconds = 0.2 });
    // Two players, neither with a guid (raylib).
    m.onConnected(core.GamepadEvent.connected(0, "P0"));
    m.onConnected(core.GamepadEvent.connected(1, "P1"));
    _ = drain(&m);
    try m.assign(0, 0);
    try m.assign(1, 1);
    _ = drain(&m);

    // Player 0 vacates first (t=0), player 1 vacates later (t=0.1).
    m.advance(0.0);
    m.onDisconnected(0);
    m.advance(0.1);
    m.onDisconnected(1);
    m.advance(1.0); // both lost
    _ = drain(&m);

    // Next no-guid controller resumes the MOST-recently-vacated → player 1.
    m.onConnected(core.GamepadEvent.connected(4, "new"));
    const c = drain(&m);
    try testing.expectEqual(@as(usize, 1), c.restored);
    try testing.expectEqual(@as(u32, 1), c.last_restored_player);
    try testing.expectEqual(@as(u32, 4), m.controllerFor(1));
    // Player 0 still waiting.
    try testing.expect(m.isPlayerWaiting(0));
}

// ── Opt-in policy helpers ──────────────────────────────────────────────────

test "autoBindFreeSlots binds every pooled controller to a free player" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(0, "A"));
    m.onConnected(core.GamepadEvent.connected(1, "B"));
    _ = drain(&m);

    const n = m.autoBindFreeSlots();
    try testing.expectEqual(@as(usize, 2), n);
    const c = drain(&m);
    try testing.expectEqual(@as(usize, 2), c.joined);
    try testing.expectEqual(@as(u32, 0), m.playerFor(0));
    try testing.expectEqual(@as(u32, 1), m.playerFor(1));
    try testing.expectEqual(@as(usize, 0), m.availableCount());
}

test "joinOnButton binds one pooled controller to the next free slot" {
    var m = Manager.init(.{});
    m.onConnected(core.GamepadEvent.connected(0, "A"));
    m.onConnected(core.GamepadEvent.connected(1, "B"));
    _ = drain(&m);

    // Player 0 already taken by A.
    try m.assign(0, 0);
    _ = drain(&m);

    const joined = m.joinOnButton(1);
    try testing.expect(joined != null);
    try testing.expectEqual(@as(u32, 1), joined.?); // next free slot
    try testing.expectEqual(@as(u32, 1), m.playerFor(1));
    try testing.expectEqual(@as(?u32, null), m.joinOnButton(99)); // not available
}

// ── INTEGRATION through Game.tick ──────────────────────────────────────────

const TestInput = struct {
    var pending: [16]core.GamepadEvent = undefined;
    var pending_len: usize = 0;

    fn reset() void {
        pending_len = 0;
    }
    fn queue(ev: core.GamepadEvent) void {
        pending[pending_len] = ev;
        pending_len += 1;
    }

    pub fn isKeyDown(_: u32) bool {
        return false;
    }
    pub fn isKeyPressed(_: u32) bool {
        return false;
    }
    pub fn pollGamepadEvents(out: []core.GamepadEvent) usize {
        const n = @min(out.len, pending_len);
        for (0..n) |i| out[i] = pending[i];
        pending_len = 0;
        return n;
    }
};

// GameEvents carrying the player-level controller variants → the engine
// instantiates a ControllerManager and drives it.
const ControllerGameEvents = union(enum) {
    engine__controller_available: engine.Events.controller_available,
    engine__controller_removed: engine.Events.controller_removed,
    engine__player_joined: engine.Events.player_joined,
    engine__player_controller_lost: engine.Events.player_controller_lost,
    engine__player_controller_restored: engine.Events.player_controller_restored,
};

const Recorder = struct {
    available: usize = 0,
    joined: usize = 0,
    lost: usize = 0,
    restored: usize = 0,
    last_available_controller: u32 = 0,
    last_joined_player: u32 = 0,

    pub fn engine__controller_available(self: *Recorder, info: anytype) void {
        self.available += 1;
        self.last_available_controller = info.controller_id;
    }
    pub fn engine__controller_removed(_: *Recorder, _: anytype) void {}
    pub fn engine__player_joined(self: *Recorder, info: anytype) void {
        self.joined += 1;
        self.last_joined_player = info.player;
    }
    pub fn engine__player_controller_lost(self: *Recorder, _: anytype) void {
        self.lost += 1;
    }
    pub fn engine__player_controller_restored(self: *Recorder, _: anytype) void {
        self.restored += 1;
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

const ControllerGame = game_mod.GameConfig(
    core.StubRender(core.MockEcsBackend(u32).Entity),
    core.MockEcsBackend(u32),
    TestInput,
    engine.StubAudio,
    engine.StubGui,
    *Recorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    ControllerGameEvents,
);

fn newGame(rec: *Recorder) ControllerGame {
    var game = ControllerGame.init(testing.allocator);
    game.setHooks(rec);
    game.dispatchEvents();
    rec.* = .{};
    return game;
}

test "tick drains a connect into engine controller_available" {
    TestInput.reset();
    var rec = Recorder{};
    var game = newGame(&rec);
    defer game.deinit();

    TestInput.queue(core.GamepadEvent.connected(0, "Pad"));
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), rec.available);
    try testing.expectEqual(@as(u32, 0), rec.last_available_controller);
    // The unassigned pool is reachable through the game handle.
    try testing.expectEqual(@as(usize, 1), game.controllerManager().availableCount());
}

test "assignController through the game emits player_joined" {
    TestInput.reset();
    var rec = Recorder{};
    var game = newGame(&rec);
    defer game.deinit();

    TestInput.queue(core.GamepadEvent.connected(0, "Pad"));
    game.tick(0.016);
    game.dispatchEvents();
    rec = .{};

    try game.assignController(0, 0);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), rec.joined);
    try testing.expectEqual(@as(u32, 0), rec.last_joined_player);
    try testing.expectEqual(@as(u32, 0), game.playerForController(0));
    try testing.expectEqual(@as(u32, 0), game.controllerForPlayer(0));
}

test "opt-in auto-pause: real loss pauses, same-guid replug resumes" {
    TestInput.reset();
    var rec = Recorder{};
    var game = newGame(&rec);
    defer game.deinit();
    game.controllerManager().config.debounce_lost_seconds = 0.2;
    game.setAutoPauseOnControllerLost(true);

    // Connect + assign player 0.
    TestInput.queue(connectedGuid(0, "Pad", G1));
    game.tick(0.016);
    game.dispatchEvents();
    try game.assignController(0, 0);
    game.dispatchEvents();
    try testing.expect(!game.isPaused());

    // Disconnect, then tick past the debounce window → lost → auto-pause.
    TestInput.queue(core.GamepadEvent.disconnected(0));
    game.tick(0.016); // feeds the disconnect; clock advances ~0.016s
    // Within the window, no lost yet → still running.
    try testing.expect(!game.isPaused());
    try testing.expectEqual(@as(usize, 0), rec.lost);

    // Advance the gameplay clock past 0.2s → lost fires → auto-pause kicks in.
    var i: usize = 0;
    while (i < 20) : (i += 1) game.tick(0.016);
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 1), rec.lost);
    try testing.expect(game.isPaused());

    // A same-guid replug, seen even WHILE PAUSED (gamepad drain runs in the
    // always-run block), restores the binding and lifts the auto-pause.
    TestInput.queue(connectedGuid(0, "Pad", G1));
    game.tick(0.016);
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 1), rec.restored);
    try testing.expect(!game.isPaused());
}
