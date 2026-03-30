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
    };
}
