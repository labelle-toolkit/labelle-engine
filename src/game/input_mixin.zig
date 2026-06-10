/// Input mixin — keyboard, mouse, and touch forwarding.
const core = @import("labelle-core");
const Position = core.Position;
const input_types = @import("../input_types.zig");
const KeyboardKey = input_types.KeyboardKey;
const MouseButton = input_types.MouseButton;
const GamepadButton = input_types.GamepadButton;
const GamepadAxis = input_types.GamepadAxis;

/// Returns the input forwarding mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Input = Game.Input;

    return struct {
        pub fn isKeyDown(_: *Game, key: KeyboardKey) bool {
            return Input.isKeyDown(@intCast(@intFromEnum(key)));
        }

        pub fn isKeyPressed(_: *Game, key: KeyboardKey) bool {
            return Input.isKeyPressed(@intCast(@intFromEnum(key)));
        }

        /// True on the frame `key` transitions from down to up.
        /// Returns false if the backend doesn't report key-release edges.
        pub fn isKeyReleased(_: *Game, key: KeyboardKey) bool {
            return Input.isKeyReleased(@intCast(@intFromEnum(key)));
        }

        pub fn getMouseX(_: *Game) f32 {
            return Input.getMouseX();
        }

        pub fn getMouseY(_: *Game) f32 {
            return Input.getMouseY();
        }

        pub fn getMouse(_: *Game) Position {
            return .{ .x = Input.getMouseX(), .y = Input.getMouseY() };
        }

        pub fn getMouseWheelMove(_: *Game) f32 {
            return Input.getMouseWheelMove();
        }

        /// True while `button` is held down this frame.
        /// Returns false if the backend doesn't report mouse-button state.
        pub fn isMouseButtonDown(_: *Game, button: MouseButton) bool {
            return Input.isMouseButtonDown(@intCast(@intFromEnum(button)));
        }

        /// True on the frame `button` transitions from up to down.
        /// Returns false if the backend doesn't report mouse-button edges.
        pub fn isMouseButtonPressed(_: *Game, button: MouseButton) bool {
            return Input.isMouseButtonPressed(@intCast(@intFromEnum(button)));
        }

        /// True on the frame `button` transitions from down to up.
        /// Returns false if the backend doesn't report mouse-button edges.
        pub fn isMouseButtonReleased(_: *Game, button: MouseButton) bool {
            return Input.isMouseButtonReleased(@intCast(@intFromEnum(button)));
        }

        // ── Gamepad ──────────────────────────────────────────────

        /// True when gamepad `id` is connected and usable this frame.
        /// Returns false if the backend doesn't report gamepad state.
        pub fn isGamepadAvailable(_: *Game, id: u32) bool {
            return Input.isGamepadAvailable(id);
        }

        /// True while `button` on gamepad `id` is held down this frame.
        /// Returns false if the backend doesn't report gamepad state.
        pub fn isGamepadButtonDown(_: *Game, id: u32, button: GamepadButton) bool {
            return Input.isGamepadButtonDown(id, @intCast(@intFromEnum(button)));
        }

        /// True on the frame `button` on gamepad `id` transitions from up to down.
        /// Returns false if the backend doesn't report gamepad button edges.
        pub fn isGamepadButtonPressed(_: *Game, id: u32, button: GamepadButton) bool {
            return Input.isGamepadButtonPressed(id, @intCast(@intFromEnum(button)));
        }

        /// Current value of `axis` on gamepad `id`. Sticks report -1..1,
        /// triggers report -1 (released) to 1 (fully pressed) on raylib.
        /// Returns 0 if the backend doesn't report gamepad axes.
        pub fn getGamepadAxisValue(_: *Game, id: u32, axis: GamepadAxis) f32 {
            return Input.getGamepadAxisValue(id, @intCast(@intFromEnum(axis)));
        }

        // ── Touch ────────────────────────────────────────────────

        /// Number of currently-active touches reported by the backend.
        /// 0 on platforms without touch input. Up to MAX_TOUCHES.
        pub fn getTouchCount(_: *Game) u32 {
            return Input.getTouchCount();
        }

        /// X position (physical framebuffer pixels) of touch `index`.
        /// Returns 0 if `index >= getTouchCount()`.
        pub fn getTouchX(_: *Game, index: u32) f32 {
            return Input.getTouchX(index);
        }

        /// Y position (physical framebuffer pixels) of touch `index`.
        /// Returns 0 if `index >= getTouchCount()`.
        pub fn getTouchY(_: *Game, index: u32) f32 {
            return Input.getTouchY(index);
        }

        /// Stable per-touch identifier from the OS — useful when matching
        /// touches across frames (e.g. for gesture recognition that needs
        /// to know which finger is which).
        /// Returns 0 if `index >= getTouchCount()`.
        pub fn getTouchId(_: *Game, index: u32) u64 {
            return Input.getTouchId(index);
        }
    };
}
