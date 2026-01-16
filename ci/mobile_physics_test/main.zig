// ============================================================================
// Mobile Physics Test - CI Test Project
// ============================================================================
// This is a test project for verifying mobile builds with physics.
// NOT auto-generated - customized for CI testing.
// ============================================================================

const std = @import("std");
pub const engine = @import("labelle-engine");
const physics = @import("labelle-physics");
const ProjectConfig = engine.ProjectConfig;

pub const GameId = u64;
const bouncing_ball_prefab = @import("prefabs/bouncing_ball.zon");
const physics_sim_script = @import("scripts/physics_sim.zig");
const main_module = @This();
pub const Prefabs = engine.PrefabRegistry(.{
    .bouncing_ball = bouncing_ball_prefab,
});
pub const Components = engine.ComponentRegistry(struct {
    // Engine built-in components
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
    // Physics components (from labelle-physics)
    pub const RigidBody = physics.RigidBody;
    pub const Collider = physics.Collider;
    pub const Velocity = physics.Velocity;
});
pub const Scripts = engine.ScriptRegistry(struct {
    pub const physics_sim = physics_sim_script;
});
const Game = engine.Game;

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
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    game.fixPointers(); // Fix internal pointers after struct is in final location
    defer game.deinit();

    // Load atlases from project config
    for (project.resources.atlases) |atlas| {
        try game.loadAtlas(atlas.name, atlas.json, atlas.texture);
    }

    // Apply camera configuration from project
    if (project.camera.x != null or project.camera.y != null) {
        game.setCameraPosition(project.camera.x orelse 0, project.camera.y orelse 0);
    }
    if (project.camera.zoom != 1.0) {
        game.setCameraZoom(project.camera.zoom);
    }

    const ctx = engine.SceneContext.init(&game);

    // Emit scene_before_load hook for initial scene (mirrors Game.setScene behavior)
    Game.HookDispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = allocator } });

    var scene = try Loader.load(initial_scene, ctx);
    defer scene.deinit();

    // Emit scene_load hook for initial scene (mirrors Game.setScene behavior)
    Game.HookDispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

    defer {
        // Only emit scene_unload for initial scene if no scene change occurred.
        // If game.setScene() was called, Game.deinit() handles the unload hook
        // for the current scene, so we shouldn't double-emit for initial_scene.
        if (game.getCurrentSceneName() == null) {
            Game.HookDispatcher.emit(.{ .scene_unload = .{ .name = initial_scene.name } });
        }
    }

    if (ci_test) {
        // CI mode: Run physics simulation for a few frames to verify it works
        std.log.info("Running physics simulation in CI mode...", .{});

        // Initialize scripts (normally happens on first update)
        scene.initScripts();

        // Verify physics was initialized successfully
        if (!physics_sim_script.isInitialized()) {
            std.log.err("Physics failed to initialize!", .{});
            return error.PhysicsInitFailed;
        }

        // Run 60 frames (~1 second at 60fps) of physics simulation
        const ci_frames: usize = 60;
        const fixed_dt: f32 = 1.0 / 60.0;

        for (0..ci_frames) |frame| {
            scene.update(fixed_dt);
            game.getPipeline().sync(game.getRegistry());

            if (frame % 20 == 0) {
                std.log.info("CI frame {d}/{d}", .{ frame + 1, ci_frames });
            }
        }

        std.log.info("Physics simulation completed successfully ({d} frames)", .{ci_frames});
        return;
    }

    while (game.isRunning()) {
        const dt = game.getDeltaTime();
        scene.update(dt);
        game.getPipeline().sync(game.getRegistry());

        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();
        game.processPendingScreenshot();
        re.endFrame();
    }
}
