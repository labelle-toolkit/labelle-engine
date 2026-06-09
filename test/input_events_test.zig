//! Tests for the engine-hosted INPUT EVENTS (labelle-gui#208, Option B).
//!
//! `Game.tick` scans the unified `InputInterface` and emits six engine
//! events into the buffered event path:
//!
//!   engine__key_pressed / engine__key_released
//!   engine__mouse_button_pressed / engine__mouse_button_released
//!   engine__gamepad_connected / engine__gamepad_disconnected
//!
//! Each scan loop is comptime-gated on `@hasField(GameEvents, tag)`, so
//! an event-less game (`GameEvents = void`) compiles fine and emits
//! nothing — the scans fold away entirely.
//!
//! The tests below drive a CONTROLLABLE input stub (settable per-key /
//! per-button / per-gamepad state) and a recorder hook, ticking the
//! game and draining `dispatchEvents` to observe what fired.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

// ── Controllable input stub ────────────────────────────────────────────
//
// Satisfies the `InputInterface(Impl)` contract (`isKeyDown` +
// `isKeyPressed` are required; the rest are optional and we provide the
// ones the scan uses). State is process-global because the interface
// dispatches to *type* decls (static fns), not an instance — mirrors how
// the real backends wrap a global window/input context. Reset between
// tests via `TestInput.reset()`.
const TestInput = struct {
    var pressed_key: ?u32 = null;
    var released_key: ?u32 = null;
    var pressed_button: ?u32 = null;
    var released_button: ?u32 = null;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var gamepad_available: [4]bool = .{ false, false, false, false };

    fn reset() void {
        pressed_key = null;
        released_key = null;
        pressed_button = null;
        released_button = null;
        mouse_x = 0;
        mouse_y = 0;
        gamepad_available = .{ false, false, false, false };
    }

    // Required by InputInterface.
    pub fn isKeyDown(_: u32) bool {
        return false;
    }
    pub fn isKeyPressed(key: u32) bool {
        return pressed_key != null and pressed_key.? == key;
    }

    // Optional wrappers the scan relies on.
    pub fn isKeyReleased(key: u32) bool {
        return released_key != null and released_key.? == key;
    }
    pub fn getMouseX() f32 {
        return mouse_x;
    }
    pub fn getMouseY() f32 {
        return mouse_y;
    }
    pub fn isMouseButtonPressed(button: u32) bool {
        return pressed_button != null and pressed_button.? == button;
    }
    pub fn isMouseButtonReleased(button: u32) bool {
        return released_button != null and released_button.? == button;
    }
    pub fn isGamepadAvailable(gamepad: u32) bool {
        if (gamepad >= gamepad_available.len) return false;
        return gamepad_available[gamepad];
    }
};

// ── GameEvents union with the six input variants ───────────────────────
const InputGameEvents = union(enum) {
    engine__key_pressed: engine.Events.key_pressed,
    engine__key_released: engine.Events.key_released,
    engine__mouse_button_pressed: engine.Events.mouse_button_pressed,
    engine__mouse_button_released: engine.Events.mouse_button_released,
    engine__gamepad_connected: engine.Events.gamepad_connected,
    engine__gamepad_disconnected: engine.Events.gamepad_disconnected,
};

// ── Recorder hook ──────────────────────────────────────────────────────
const InputRecorder = struct {
    key_pressed_count: usize = 0,
    key_released_count: usize = 0,
    mouse_pressed_count: usize = 0,
    mouse_released_count: usize = 0,
    gamepad_connected_count: usize = 0,
    gamepad_disconnected_count: usize = 0,

    last_key: u32 = 0,
    last_released_key: u32 = 0,
    last_button: u32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_gamepad_connected: u32 = 0,
    last_gamepad_disconnected: u32 = 0,

    pub fn engine__key_pressed(self: *InputRecorder, info: anytype) void {
        self.key_pressed_count += 1;
        self.last_key = info.key;
    }
    pub fn engine__key_released(self: *InputRecorder, info: anytype) void {
        self.key_released_count += 1;
        self.last_released_key = info.key;
    }
    pub fn engine__mouse_button_pressed(self: *InputRecorder, info: anytype) void {
        self.mouse_pressed_count += 1;
        self.last_button = info.button;
        self.last_x = info.x;
        self.last_y = info.y;
    }
    pub fn engine__mouse_button_released(self: *InputRecorder, info: anytype) void {
        self.mouse_released_count += 1;
        self.last_button = info.button;
        self.last_x = info.x;
        self.last_y = info.y;
    }
    pub fn engine__gamepad_connected(self: *InputRecorder, info: anytype) void {
        self.gamepad_connected_count += 1;
        self.last_gamepad_connected = info.id;
    }
    pub fn engine__gamepad_disconnected(self: *InputRecorder, info: anytype) void {
        self.gamepad_disconnected_count += 1;
        self.last_gamepad_disconnected = info.id;
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

const InputGame = game_mod.GameConfig(
    core.StubRender(core.MockEcsBackend(u32).Entity),
    core.MockEcsBackend(u32),
    TestInput,
    engine.StubAudio,
    engine.StubGui,
    *InputRecorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    InputGameEvents,
);

// raylib-compatible key/button codes (see src/input_types.zig).
const KEY_SPACE: u32 = 32;
const KEY_A: u32 = 65;
const MOUSE_LEFT: u32 = 0;
const MOUSE_RIGHT: u32 = 1;

fn newGame(recorder: *InputRecorder) InputGame {
    var game = InputGame.init(testing.allocator);
    game.setHooks(recorder);
    // Drain the buffered `game_init` (not a variant of this union, so it
    // never buffers anyway) — keep the buffer clean for the assertions.
    game.dispatchEvents();
    recorder.* = .{};
    return game;
}

// ── Keyboard ───────────────────────────────────────────────────────────

test "key down-edge emits key_pressed with the right code" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.pressed_key = KEY_SPACE;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.key_pressed_count);
    try testing.expectEqual(KEY_SPACE, recorder.last_key);
    try testing.expectEqual(@as(usize, 0), recorder.key_released_count);
}

test "key up-edge emits key_released with the right code" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.released_key = KEY_A;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.key_released_count);
    try testing.expectEqual(KEY_A, recorder.last_released_key);
    try testing.expectEqual(@as(usize, 0), recorder.key_pressed_count);
}

test "key_null sentinel is never emitted" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    // Force the scan to report key 0 (key_null) as pressed/released.
    TestInput.pressed_key = 0;
    TestInput.released_key = 0;
    game.tick(0.016);
    game.dispatchEvents();

    // key_null (code 0) is skipped at comptime, so nothing fires.
    try testing.expectEqual(@as(usize, 0), recorder.key_pressed_count);
    try testing.expectEqual(@as(usize, 0), recorder.key_released_count);
}

// ── Mouse ──────────────────────────────────────────────────────────────

test "mouse button down-edge emits with cursor x/y" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.pressed_button = MOUSE_LEFT;
    TestInput.mouse_x = 123.5;
    TestInput.mouse_y = 47.0;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.mouse_pressed_count);
    try testing.expectEqual(MOUSE_LEFT, recorder.last_button);
    try testing.expectApproxEqAbs(@as(f32, 123.5), recorder.last_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 47.0), recorder.last_y, 0.001);
}

test "mouse button up-edge emits mouse_button_released with x/y" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.released_button = MOUSE_RIGHT;
    TestInput.mouse_x = 5.0;
    TestInput.mouse_y = 9.0;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.mouse_released_count);
    try testing.expectEqual(MOUSE_RIGHT, recorder.last_button);
    try testing.expectApproxEqAbs(@as(f32, 5.0), recorder.last_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 9.0), recorder.last_y, 0.001);
}

// ── Gamepad ────────────────────────────────────────────────────────────

test "gamepad false->true emits gamepad_connected once, not while held" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    // First tick with slot 0 available: connect edge.
    TestInput.gamepad_available[0] = true;
    game.tick(0.016);
    // Still available next tick: NO repeat.
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.gamepad_connected_count);
    try testing.expectEqual(@as(u32, 0), recorder.last_gamepad_connected);
    try testing.expectEqual(@as(usize, 0), recorder.gamepad_disconnected_count);
}

test "gamepad true->false emits gamepad_disconnected" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.gamepad_available[1] = true;
    game.tick(0.016); // connect edge for slot 1
    TestInput.gamepad_available[1] = false;
    game.tick(0.016); // disconnect edge for slot 1
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.gamepad_connected_count);
    try testing.expectEqual(@as(usize, 1), recorder.gamepad_disconnected_count);
    try testing.expectEqual(@as(u32, 1), recorder.last_gamepad_disconnected);
}

// ── Zero-cost / comptime-gate safety ───────────────────────────────────

// A game whose `GameEvents` lacks the input variants (here `void`) must
// compile and emit nothing — the scan folds away. Exercises the same
// `engine.Game` (GameEvents = void) used everywhere in the unit suite.
test "GameEvents = void emits no input events and compiles" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    // Ticking with input state present must not crash or attempt any
    // emission — the comptime gate eliminated every scan loop.
    game.tick(0.016);
    game.tick(0.016);
    // No assertion: passing == compiles + runs with the scans gated out.
}
