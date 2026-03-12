/// Input mixin — keyboard, mouse, and touch forwarding.
const core = @import("labelle-core");
const Position = core.Position;

/// Returns the input forwarding mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Input = Game.Input;

    return struct {
        pub fn isKeyDown(_: *Game, key: u32) bool {
            return Input.isKeyDown(key);
        }

        pub fn isKeyPressed(_: *Game, key: u32) bool {
            return Input.isKeyPressed(key);
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
    };
}
