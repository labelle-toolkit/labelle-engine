//! Tests for the engine's `pub const Events` block (RFC-FLOW-VOCABULARY
//! phase 6, #578).
//!
//! The engine fires lifecycle hooks two ways:
//!
//!   1. The closed `EngineHookPayload` union — the existing
//!      `HookDispatcher`-driven path. Unchanged by #578.
//!   2. The buffered event path (`Game.emit` / `Game.dispatchEvents`)
//!      with qualified `engine__<event>` variants, gated by
//!      `emitEngineEvent`'s comptime `@hasField` check.
//!
//! The assembler folds `engine.Events` into `PluginEvents` at codegen
//! time. The tests below build a synthetic `GameEvents` union with the
//! same `engine__*` variants and check that the engine's lifecycle
//! code fires through both paths.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

// Synthetic `GameEvents` mirroring what the assembler emits for a
// project with no plugins / no game events. The variant set matches
// `engine.Events` decl-for-decl so `emitEngineEvent`'s
// `@hasField(GameEvents, "engine__<tag>")` resolves true.
const EngineEvents = union(enum) {
    engine__game_init: engine.Events.game_init,
    engine__game_deinit: engine.Events.game_deinit,
    engine__tick: engine.Events.tick,
    engine__post_tick: engine.Events.post_tick,
    engine__entity_created: engine.Events.entity_created,
    engine__entity_destroyed: engine.Events.entity_destroyed,
    engine__scene_loading: engine.Events.scene_loading,
    engine__scene_loaded: engine.Events.scene_loaded,
    engine__scene_unloaded: engine.Events.scene_unloaded,
    engine__scene_before_reset: engine.Events.scene_before_reset,
    engine__scene_assets_acquire: engine.Events.scene_assets_acquire,
    engine__scene_assets_release: engine.Events.scene_assets_release,
    engine__state_changed: engine.Events.state_changed,
    engine__pause_changed: engine.Events.pause_changed,
};

// Recorder hook — implements one method per `engine__*` variant so
// `MergeHooks.emit` dispatches buffered events back into our counters.
const EventRecorder = struct {
    game_init_count: usize = 0,
    game_deinit_count: usize = 0,
    tick_count: usize = 0,
    post_tick_count: usize = 0,
    entity_created_count: usize = 0,
    entity_destroyed_count: usize = 0,
    scene_loading_count: usize = 0,
    scene_loaded_count: usize = 0,
    scene_unloaded_count: usize = 0,
    pause_changed_count: usize = 0,
    state_changed_count: usize = 0,
    last_tick_dt: f32 = 0,
    last_entity: u32 = 0,
    last_paused: bool = false,
    last_state: []const u8 = "",

    pub fn engine__game_init(self: *EventRecorder, _: anytype) void {
        self.game_init_count += 1;
    }
    pub fn engine__game_deinit(self: *EventRecorder, _: anytype) void {
        self.game_deinit_count += 1;
    }
    pub fn engine__tick(self: *EventRecorder, info: anytype) void {
        self.tick_count += 1;
        self.last_tick_dt = info.dt;
    }
    pub fn engine__post_tick(self: *EventRecorder, _: anytype) void {
        self.post_tick_count += 1;
    }
    pub fn engine__entity_created(self: *EventRecorder, info: anytype) void {
        self.entity_created_count += 1;
        self.last_entity = info.entity;
    }
    pub fn engine__entity_destroyed(self: *EventRecorder, _: anytype) void {
        self.entity_destroyed_count += 1;
    }
    pub fn engine__pause_changed(self: *EventRecorder, info: anytype) void {
        self.pause_changed_count += 1;
        self.last_paused = info.paused;
    }
    pub fn engine__state_changed(self: *EventRecorder, info: anytype) void {
        self.state_changed_count += 1;
        self.last_state = info.new_state;
    }
};

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool { return false; }
    pub fn names() []const []const u8 { return &.{}; }
};

// `GameWith`-style game that wires `EngineEvents` into the
// `GameConfig`'s last slot. Mirrors the assembler-generated
// instantiation a real project lands on.
const TestGame = game_mod.GameConfig(
    core.StubRender(core.MockEcsBackend(u32).Entity),
    core.MockEcsBackend(u32),
    @import("engine").StubInput,
    @import("engine").StubAudio,
    @import("engine").StubVideo,
    @import("engine").StubGui,
    *EventRecorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    EngineEvents,
);

// ── Decl-level guard ───────────────────────────────────────────────────

test "engine.Events declares the expected variant set" {
    // Front-stop test: a future drop of one of these variants surfaces
    // as a compile error here, not silently as a missing event in the
    // generated `PluginEvents` union. Keep this list in lockstep with
    // `engine.Events` in `src/root.zig`.
    _ = engine.Events.game_init;
    _ = engine.Events.game_deinit;
    _ = engine.Events.tick;
    _ = engine.Events.post_tick;
    _ = engine.Events.entity_created;
    _ = engine.Events.entity_destroyed;
    _ = engine.Events.scene_loading;
    _ = engine.Events.scene_loaded;
    _ = engine.Events.scene_unloaded;
    _ = engine.Events.scene_before_reset;
    _ = engine.Events.scene_assets_acquire;
    _ = engine.Events.scene_assets_release;
    _ = engine.Events.state_changed;
    _ = engine.Events.pause_changed;
    // Input events (labelle-gui#208).
    _ = engine.Events.key_pressed;
    _ = engine.Events.key_released;
    _ = engine.Events.mouse_button_pressed;
    _ = engine.Events.mouse_button_released;
    _ = engine.Events.gamepad_connected;
    _ = engine.Events.gamepad_disconnected;
}

// ── Buffered-emit tests ────────────────────────────────────────────────

test "game_init fires through Game.emit when GameEvents has the variant" {
    var recorder = EventRecorder{};
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    // `setHooks` is where `game_init` fires (see game.zig:431-432).
    // The dual-emit through `emitEngineEvent` puts the event in
    // `event_buffer`; drain it to dispatch.
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 1), recorder.game_init_count);
}

test "tick + post_tick fire each frame" {
    var recorder = EventRecorder{};
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.tick(0.016);
    game.tick(0.020);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 2), recorder.tick_count);
    try testing.expectEqual(@as(usize, 2), recorder.post_tick_count);
    try testing.expectApproxEqAbs(@as(f32, 0.020), recorder.last_tick_dt, 0.001);
}

test "entity_created / entity_destroyed fire on ECS lifecycle" {
    var recorder = EventRecorder{};
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    const e = game.createEntity();
    game.destroyEntity(e);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.entity_created_count);
    try testing.expectEqual(@as(usize, 1), recorder.entity_destroyed_count);
    // u32 widening: the test backend's Entity is u32, so the
    // widened payload matches the ECS-assigned id verbatim.
    try testing.expectEqual(@as(u32, @intCast(e)), recorder.last_entity);
}

test "pause_changed fires on transition only" {
    var recorder = EventRecorder{};
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.setPaused(true);
    game.setPaused(true); // idempotent — no second fire
    game.setPaused(false);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 2), recorder.pause_changed_count);
    try testing.expect(!recorder.last_paused);
}

test "state_changed fires on post-transition edge" {
    var recorder = EventRecorder{};
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.setState("playing");
    game.setState("playing"); // no-op
    game.setState("paused");
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 2), recorder.state_changed_count);
    try testing.expectEqualStrings("paused", recorder.last_state);
}

// ── No-op safety test ─────────────────────────────────────────────────

test "engine lifecycle emits compile fine with GameEvents = void" {
    // The unit-test default game (`GameWith(void)`) has `GameEvents =
    // void` — the engine's `emitEngineEvent` must fold to a no-op so
    // every lifecycle path stays valid. This is the back-compat
    // guarantee for hand-authored test games that don't wire the
    // assembler-merged `GameEvents`.
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.tick(0.016);
    game.destroyEntity(e);
    game.setPaused(true);
    game.setState("foo");
    // No assertion — the test passes if compilation + execution don't
    // crash. The closed-union `HookPayload` path still fires under
    // the hood; the buffered `engine__*` path folds away.
}
