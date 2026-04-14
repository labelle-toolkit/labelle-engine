/// Input mixin — keyboard, mouse, and touch forwarding.
const core = @import("labelle-core");
const Position = core.Position;
const input_types = @import("../input_types.zig");
const KeyboardKey = input_types.KeyboardKey;

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
        pub fn getTouchId(_: *Game, index: u32) u64 {
            return Input.getTouchId(index);
        }
    };
}
