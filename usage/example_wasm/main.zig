// ============================================================================
// Bouncing Ball Demo
// ============================================================================
// Colorful shapes bouncing around the screen.
// Uses sokol backend - can be compiled for native or WASM.
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("labelle-engine");

// Physics module (exported from engine when physics=true)
const physics = engine.physics;

// Import components
const Velocity_comp = @import("components/Velocity.zig");
pub const Velocity = Velocity_comp.Velocity;

// Physics components
pub const RigidBody = physics.RigidBody;
pub const Collider = physics.Collider;

// Import scripts
const bouncing_ball_script = @import("scripts/bouncing_ball.zig");
const physics_bouncing_ball_script = @import("scripts/physics_bouncing_ball.zig");

// Import hooks
const game_hooks = @import("hooks/game_hooks.zig");

const main_module = @This();

// Registries
pub const Prefabs = engine.PrefabRegistry(.{});
pub const Components = engine.ComponentRegistry(struct {
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
    pub const Velocity = main_module.Velocity;
    // Physics components
    pub const RigidBody = main_module.RigidBody;
    pub const Collider = main_module.Collider;
});
pub const Scripts = engine.ScriptRegistry(struct {
    pub const bouncing_ball = bouncing_ball_script;
    pub const physics_bouncing_ball = physics_bouncing_ball_script;
});

// Hooks
const Hooks = engine.MergeEngineHooks(.{game_hooks});
const Game = engine.GameWith(Hooks);

// Scene loader
pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
pub const initial_scene = @import("scenes/main.zon");

pub fn main() !void {
    // CI_TEST not available on WASM
    const ci_test = if (builtin.os.tag == .emscripten)
        false
    else
        std.posix.getenv("CI_TEST") != null;

    // Use c_allocator for WASM compatibility, GPA for native
    // Note: GPA must outlive the allocator, so declare it in the outer scope
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (builtin.os.tag != .emscripten) {
        _ = gpa.deinit();
    };
    const allocator = if (builtin.os.tag == .emscripten)
        std.heap.c_allocator
    else
        gpa.allocator();

    var game = try Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Bouncing Ball Demo",
            .target_fps = 60,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    game.fixPointers();
    // On WASM, main() returns immediately while the browser event loop runs.
    // Only deinit on native where main() blocks until the game loop ends.
    defer if (builtin.os.tag != .emscripten) game.deinit();

    // Apply camera (center of screen)
    game.setCameraPosition(400, 300);

    const ctx = engine.SceneContext.init(&game);

    // Emit scene_before_load hook
    game.hook_dispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = allocator } });

    var scene = try Loader.load(initial_scene, ctx);
    defer if (builtin.os.tag != .emscripten) scene.deinit();

    // Emit scene_load hook
    game.hook_dispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

    defer if (builtin.os.tag != .emscripten) {
        if (game.getCurrentSceneName() == null) {
            game.hook_dispatcher.emit(.{ .scene_unload = .{ .name = initial_scene.name } });
        }
    };

    if (ci_test) return;

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
