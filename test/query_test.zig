const std = @import("std");

const engine = @import("engine");
const separateComponents = engine.separateComponents;

test "component separation" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const TagPlayer = struct {};
    const TagEnemy = struct {};

    const result = separateComponents(.{ Position, TagPlayer, Velocity, TagEnemy });

    comptime {
        std.debug.assert(result.data.len == 2);
        std.debug.assert(result.tags.len == 2);
        std.debug.assert(result.data[0] == Position);
        std.debug.assert(result.data[1] == Velocity);
        std.debug.assert(result.tags[0] == TagPlayer);
        std.debug.assert(result.tags[1] == TagEnemy);
    }
}
