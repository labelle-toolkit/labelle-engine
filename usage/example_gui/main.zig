const std = @import("std");
const labelle = @import("labelle-engine");

// Import GUI view definitions
const Views = labelle.ViewRegistry(.{
    .hud = @import("gui/hud.zon"),
});

// Script callbacks for GUI buttons (currently just logging)
const Scripts = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
};

// Minimal components and prefabs for scene loading
const Components = labelle.ComponentRegistry(struct {
    pub const Position = labelle.Position;
});

const Prefabs = labelle.PrefabRegistry(.{});

const Loader = labelle.SceneLoader(Prefabs, Components, Scripts);

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var game = try labelle.Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "GUI Example",
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 30, .b = 40 },
    });
    game.fixPointers();
    defer game.deinit();

    // Load scene with GUI views
    var scene = try Loader.load(@import("scenes/main.zon"), labelle.SceneContext.init(&game));
    defer scene.deinit();

    if (ci_test) return;

    while (game.isRunning()) {
        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();

        // Render GUI views associated with the scene
        // (loads views from scene's .gui_views field)
        game.gui_rendering.renderSceneGui(&scene, Views, Scripts);

        re.endFrame();
    }
}
