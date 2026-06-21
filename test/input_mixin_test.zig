//! Tests for the input ACCESSOR methods surfaced on the game handle
//! (labelle-gui#208). These wrap the unified `InputInterface` so flow
//! reporter nodes can poll key-release and mouse-button state directly:
//!
//!   isKeyReleased / isMouseButtonDown
//!   isMouseButtonPressed / isMouseButtonReleased
//!
//! Each delegates to the matching (optional) `InputInterface` method,
//! which falls back to `false` when the backend omits it. The tests
//! drive two stubs: a FULL one that reports state, and a MINIMAL one
//! that defines only the required `isKeyDown`/`isKeyPressed` to exercise
//! the graceful `false` fallback path.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;
const KeyboardKey = engine.KeyboardKey;
const MouseButton = engine.MouseButton;
const GamepadButton = engine.GamepadButton;
const GamepadAxis = engine.GamepadAxis;

// ── Full controllable input stub ───────────────────────────────────────
//
// State is process-global because the interface dispatches to *type*
// decls (static fns), not an instance — mirrors the real backends.
// Reset between tests via `FullInput.reset()`.
const FullInput = struct {
    var released_key: ?u32 = null;
    var down_button: ?u32 = null;
    var pressed_button: ?u32 = null;
    var released_button: ?u32 = null;
    var gamepad_available_id: ?u32 = null;
    var gamepad_down: ?struct { id: u32, button: u32 } = null;
    var gamepad_pressed: ?struct { id: u32, button: u32 } = null;
    var gamepad_axis: ?struct { id: u32, axis: u32, value: f32 } = null;

    fn reset() void {
        released_key = null;
        down_button = null;
        pressed_button = null;
        released_button = null;
        gamepad_available_id = null;
        gamepad_down = null;
        gamepad_pressed = null;
        gamepad_axis = null;
    }

    // Required by InputInterface.
    pub fn isKeyDown(_: u32) bool {
        return false;
    }
    pub fn isKeyPressed(_: u32) bool {
        return false;
    }

    // Optional wrappers the new accessors surface.
    pub fn isKeyReleased(key: u32) bool {
        return released_key != null and released_key.? == key;
    }
    pub fn isMouseButtonDown(button: u32) bool {
        return down_button != null and down_button.? == button;
    }
    pub fn isMouseButtonPressed(button: u32) bool {
        return pressed_button != null and pressed_button.? == button;
    }
    pub fn isMouseButtonReleased(button: u32) bool {
        return released_button != null and released_button.? == button;
    }

    // Gamepad wrappers the new accessors surface.
    pub fn isGamepadAvailable(id: u32) bool {
        return gamepad_available_id != null and gamepad_available_id.? == id;
    }
    pub fn isGamepadButtonDown(id: u32, button: u32) bool {
        return gamepad_down != null and gamepad_down.?.id == id and gamepad_down.?.button == button;
    }
    pub fn isGamepadButtonPressed(id: u32, button: u32) bool {
        return gamepad_pressed != null and gamepad_pressed.?.id == id and gamepad_pressed.?.button == button;
    }
    pub fn getGamepadAxisValue(id: u32, axis: u32) f32 {
        if (gamepad_axis) |a| {
            if (a.id == id and a.axis == axis) return a.value;
        }
        return 0;
    }
};

// ── Minimal stub (only the required methods) ───────────────────────────
//
// Omits all the optional methods so the InputInterface `@hasDecl` guards
// take the graceful `false` fallback path.
const MinimalInput = struct {
    pub fn isKeyDown(_: u32) bool {
        return false;
    }
    pub fn isKeyPressed(_: u32) bool {
        return false;
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

fn GameWith(comptime Input: type) type {
    return game_mod.GameConfig(
        core.StubRender(core.MockEcsBackend(u32).Entity),
        core.MockEcsBackend(u32),
        Input,
        engine.StubAudio,
        engine.StubVideo,
        engine.StubGui,
        void,
        core.StubLogSink,
        EmptyComponents,
        &.{},
        void,
    );
}

const FullGame = GameWith(FullInput);
const MinimalGame = GameWith(MinimalInput);

// ── Full backend reflects reported state ───────────────────────────────

test "isKeyReleased reflects a released key, false otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.released_key = @intFromEnum(KeyboardKey.space);
    try testing.expect(game.isKeyReleased(.space));
    try testing.expect(!game.isKeyReleased(.a));
}

test "isMouseButtonDown reflects a held button, false otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.down_button = @intFromEnum(MouseButton.left);
    try testing.expect(game.isMouseButtonDown(.left));
    try testing.expect(!game.isMouseButtonDown(.right));
}

test "isMouseButtonPressed reflects a press-edge, false otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.pressed_button = @intFromEnum(MouseButton.right);
    try testing.expect(game.isMouseButtonPressed(.right));
    try testing.expect(!game.isMouseButtonPressed(.left));
}

test "isMouseButtonReleased reflects a release-edge, false otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.released_button = @intFromEnum(MouseButton.middle);
    try testing.expect(game.isMouseButtonReleased(.middle));
    try testing.expect(!game.isMouseButtonReleased(.left));
}

// ── Gamepad accessors reflect reported state ────────────────────────────

test "isGamepadAvailable reflects a connected pad, false otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.gamepad_available_id = 0;
    try testing.expect(game.isGamepadAvailable(0));
    try testing.expect(!game.isGamepadAvailable(1));
}

test "isGamepadButtonDown reflects a held face button, false otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.gamepad_down = .{ .id = 0, .button = @intCast(@intFromEnum(GamepadButton.right_face_down)) };
    try testing.expect(game.isGamepadButtonDown(0, .right_face_down));
    try testing.expect(!game.isGamepadButtonDown(0, .right_face_up));
    try testing.expect(!game.isGamepadButtonDown(1, .right_face_down));
}

test "isGamepadButtonPressed reflects a press-edge, false otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.gamepad_pressed = .{ .id = 0, .button = @intCast(@intFromEnum(GamepadButton.left_trigger_1)) };
    try testing.expect(game.isGamepadButtonPressed(0, .left_trigger_1));
    try testing.expect(!game.isGamepadButtonPressed(0, .right_trigger_1));
}

test "getGamepadAxisValue reflects a reported axis, 0 otherwise" {
    FullInput.reset();
    var game = FullGame.init(testing.allocator);
    defer game.deinit();

    FullInput.gamepad_axis = .{ .id = 0, .axis = @intCast(@intFromEnum(GamepadAxis.left_x)), .value = 0.75 };
    try testing.expectApproxEqAbs(@as(f32, 0.75), game.getGamepadAxisValue(0, .left_x), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), game.getGamepadAxisValue(0, .left_y), 0.0001);
}

// ── Minimal backend → graceful false fallback ──────────────────────────

test "accessors return false when the backend omits the optional methods" {
    var game = MinimalGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(!game.isKeyReleased(.space));
    try testing.expect(!game.isMouseButtonDown(.left));
    try testing.expect(!game.isMouseButtonPressed(.left));
    try testing.expect(!game.isMouseButtonReleased(.left));
    try testing.expect(!game.isGamepadAvailable(0));
    try testing.expect(!game.isGamepadButtonDown(0, .right_face_down));
    try testing.expect(!game.isGamepadButtonPressed(0, .right_face_down));
    try testing.expectApproxEqAbs(@as(f32, 0.0), game.getGamepadAxisValue(0, .left_x), 0.0001);
}
