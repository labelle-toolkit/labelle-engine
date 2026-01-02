// ============================================================================
// Physics Demo - main.zig
// ============================================================================
// Demonstrates physics integration with Box2D using prefabs, scenes, and scripts.
// Left click: spawn box, Right click: spawn circle, R: reset scene
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const ProjectConfig = engine.ProjectConfig;

// Import prefabs
const dynamic_box_prefab = @import("prefabs/dynamic_box.zon");
const dynamic_circle_prefab = @import("prefabs/dynamic_circle.zon");

// Import components
const physics_body_comp = @import("components/physics_body.zig");
pub const PhysicsBody = physics_body_comp.PhysicsBody;

// Import scripts
const physics_demo_script = @import("scripts/physics_demo.zig");

const main_module = @This();

pub const Prefabs = engine.PrefabRegistry(.{
    .dynamic_box = dynamic_box_prefab,
    .dynamic_circle = dynamic_circle_prefab,
});

pub const Components = engine.ComponentRegistry(struct {
    pub const PhysicsBody = main_module.PhysicsBody;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const physics_demo = physics_demo_script;
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

    // For CI test, run a few frames and exit
    if (ci_test) {
        std.debug.print("CI_TEST mode: running physics simulation\n", .{});
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
