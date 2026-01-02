// ============================================================================
// Physics Validation Example - main.zig
// ============================================================================
// Demonstrates physics gravity using prefabs and a validation script
// that checks entities have moved after 2 seconds.
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const ProjectConfig = engine.ProjectConfig;

// Import prefabs
const falling_box_prefab = @import("prefabs/falling_box.zon");

// Import components
const gravity_body_comp = @import("components/gravity_body.zig");
pub const GravityBody = gravity_body_comp.GravityBody;

// Import scripts
const gravity_validator_script = @import("scripts/gravity_validator.zig");

const main_module = @This();

pub const Prefabs = engine.PrefabRegistry(.{
    .falling_box = falling_box_prefab,
});

pub const Components = engine.ComponentRegistry(struct {
    pub const GravityBody = main_module.GravityBody;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const gravity_validator = gravity_validator_script;
});

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

pub const initial_scene = @import("scenes/main.zon");

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const project = try ProjectConfig.load(allocator, "project.labelle");
    defer project.deinit(allocator);

    // Convert title to sentinel-terminated string for window creation
    const title = try allocator.dupeZ(u8, project.window.title);
    defer allocator.free(title);

    var game = try Game.init(allocator, .{
        .window = .{
            .width = project.window.width,
            .height = project.window.height,
            .title = title,
            .target_fps = project.window.target_fps,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 40, .g = 45, .b = 55 },
    });
    game.fixPointers();
    defer game.deinit();

    // Apply camera configuration from project
    if (project.camera.x != null or project.camera.y != null) {
        game.setCameraPosition(project.camera.x orelse 0, project.camera.y orelse 0);
    }
    if (project.camera.zoom != 1.0) {
        game.setCameraZoom(project.camera.zoom);
    }

    const ctx = engine.SceneContext.init(&game);
    var scene = try Loader.load(initial_scene, ctx);
    defer scene.deinit();

    // For CI test, just validate and exit
    if (ci_test) {
        std.debug.print("CI_TEST mode: running validation\n", .{});
        // Run a few update cycles to let physics settle
        var elapsed: f32 = 0;
        while (elapsed < 3.0) {
            const dt: f32 = 1.0 / 60.0;
            scene.update(dt);
            elapsed += dt;
        }
        return;
    }

    while (game.isRunning()) {
        const dt = game.getDeltaTime();
        scene.update(dt);
        game.getPipeline().sync(game.getRegistry());

        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();
        re.endFrame();
    }
}
