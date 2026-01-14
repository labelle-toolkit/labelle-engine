// ============================================================================
// Mobile Physics Test - main.zig
// ============================================================================
// CI test project for verifying mobile builds with physics enabled.
// Runs a simple physics simulation with bouncing balls.
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const ProjectConfig = engine.ProjectConfig;

// Import physics module for components
const physics = @import("labelle-physics");

// Import prefabs
const bouncing_ball_prefab = @import("prefabs/bouncing_ball.zon");

// Physics components (exported from physics module)
pub const RigidBody = physics.RigidBody;
pub const Collider = physics.Collider;

// Import scripts
const physics_sim_script = @import("scripts/physics_sim.zig");

const main_module = @This();

pub const Prefabs = engine.PrefabRegistry(.{
    .bouncing_ball = bouncing_ball_prefab,
});

pub const Components = engine.ComponentRegistry(struct {
    // Engine built-in components
    pub const Position = engine.Position;
    pub const Shape = engine.Shape;
    // Physics components
    pub const RigidBody = main_module.RigidBody;
    pub const Collider = main_module.Collider;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const physics_sim = physics_sim_script;
});

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

pub const initial_scene = @import("scenes/main.zon");

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var game = try Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Mobile Physics Test",
            .target_fps = 60,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 40, .g = 45, .b = 55 },
    });
    game.fixPointers();
    defer game.deinit();

    // Set camera position
    game.setCameraPosition(400, 300);

    const ctx = engine.SceneContext.init(&game);
    var scene = try Loader.load(initial_scene, ctx);
    defer scene.deinit();

    // For CI test, run physics for a few seconds and exit
    if (ci_test) {
        std.log.info("CI_TEST mode: running physics simulation for 3 seconds", .{});
        var elapsed: f32 = 0;
        const max_time: f32 = 3.0;
        const dt: f32 = 1.0 / 60.0;

        while (elapsed < max_time) {
            scene.update(dt);
            game.getPipeline().sync(game.getRegistry());
            elapsed += dt;
        }

        std.log.info("CI_TEST: Physics simulation completed successfully", .{});
        return;
    }

    // Normal game loop
    while (game.isRunning()) {
        const dt = game.getDeltaTime();

        game.getInput().beginFrame();
        game.updateGestures(dt);
        game.getAudio().update();

        scene.update(dt);
        game.getPipeline().sync(game.getRegistry());

        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();
        re.endFrame();
    }
}
