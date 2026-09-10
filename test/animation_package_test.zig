const std = @import("std");
const animation = @import("animation");
const engine = @import("engine");

test "shared JSONC definition drives two independent existing SpriteAnimation players" {
    var definition = try animation.Definition.parse(std.testing.allocator,
        \\{"version":1,"clips":{"walk":{"frames_pattern":"walk_{frame:04}.png","from":1,"to":3}}}
    );
    defer definition.deinit();
    const frames = definition.find("walk").?.frames;
    var first = engine.SpriteAnimation{ .frames = frames, .fps = 4, .mode = .loop };
    var second = engine.SpriteAnimation{ .frames = frames, .fps = 4, .mode = .loop };
    _ = first.advance(0.25);
    try std.testing.expectEqualStrings("walk_0002.png", first.currentSprite().?);
    try std.testing.expectEqualStrings("walk_0001.png", second.currentSprite().?);
    _ = second.advance(0.5);
    try std.testing.expectEqualStrings("walk_0003.png", second.currentSprite().?);
    _ = first.advance(0.5);
    try std.testing.expectEqualStrings("walk_0001.png", first.currentSprite().?);
}
