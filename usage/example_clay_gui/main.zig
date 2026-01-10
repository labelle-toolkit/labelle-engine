// ============================================================================
// Clay GUI Backend Example
// ============================================================================
// Demonstrates the Clay high-performance declarative UI layout engine
// integrated with labelle-engine.
// ============================================================================

const std = @import("std");
const labelle = @import("labelle-engine");

// Import GUI view definitions
const Views = labelle.ViewRegistry(.{
    .demo = @import("gui/demo.zon"),
});

// Script callbacks for GUI buttons (currently just logging)
const Scripts = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
};

// Minimal components for scene loading
const Components = labelle.ComponentRegistry(struct {
    pub const Position = labelle.Position;
    pub const Sprite = labelle.Sprite;
    pub const Shape = labelle.Shape;
    pub const Text = labelle.Text;
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
            .width = 1280,
            .height = 800,
            .title = "Clay GUI Backend Demo",
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 25, .g = 28, .b = 35 },
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
        game.renderSceneGui(&scene, Views, Scripts);

        re.endFrame();
    }
}
