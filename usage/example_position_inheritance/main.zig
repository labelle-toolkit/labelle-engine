const std = @import("std");
const engine = @import("labelle-engine");

const hierarchy_test_script = @import("scripts/hierarchy_test.zig");

const Prefabs = engine.PrefabRegistry(.{
    .parent_circle = @import("prefabs/parent_circle.zon"),
    .square = @import("prefabs/square.zon"),
});
const Components = engine.ComponentRegistry(struct {
    pub const Position = engine.Position;
    pub const Shape = engine.Shape;
});
const Scripts = engine.ScriptRegistry(struct {
    pub const hierarchy_test = hierarchy_test_script;
});
const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

pub fn main() !void {
    var game = try engine.Game.init(std.heap.page_allocator, .{
        .window = .{
            .title = "Parent-Child Binding Demo",
            .width = 800,
            .height = 600,
        },
    });
    defer game.deinit();
    game.fixPointers();

    var scene = try Loader.load(
        @import("scenes/hierarchy_demo.zon"),
        engine.SceneContext.init(&game),
    );
    defer scene.deinit();

    const re = game.getRetainedEngine();

    while (game.isRunning()) {
        scene.update(game.getDeltaTime());
        game.getPipeline().sync(game.getRegistry());

        re.beginFrame();
        re.render();
        re.endFrame();
    }
}
