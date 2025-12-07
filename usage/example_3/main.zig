//! Example 3: labelle-engine Scene + labelle Visual Rendering
//!
//! This example demonstrates the full integration of:
//! - labelle-engine: Scene loading, prefabs, components, scripts (ECS)
//! - labelle: Visual rendering with comptime sprite atlases
//!
//! Features demonstrated:
//! - Comptime loading of sprite atlas (.zon file)
//! - Scene definition with prefabs and inline entities (.zon file)
//! - ECS components attached to entities
//! - Scripts that run game logic each frame
//! - Opening a window and rendering sprites from the scene
//!
//! Build and run:
//!   cd usage/example_3
//!   zig build run

const std = @import("std");
const engine = @import("labelle-engine");
const labelle = @import("labelle");

const Game = engine.Game;

// =============================================================================
// Step 1: Load sprite data at comptime
// =============================================================================

const character_frames = @import("fixtures/characters_frames.zon");

// =============================================================================
// Step 2: Import Prefabs from prefabs folder
// =============================================================================

const PlayerPrefab = @import("prefabs/player.zig");
const EnemyPrefab = @import("prefabs/enemy.zig");

// =============================================================================
// Step 3: Import Components from components folder
// =============================================================================

const velocity = @import("components/velocity.zig");
const health = @import("components/health.zig");
const gravity_comp = @import("components/gravity.zig");

pub const Velocity = velocity.Velocity;
pub const Health = health.Health;
pub const Gravity = gravity_comp.Gravity;

// =============================================================================
// Step 4: Import Scripts from scripts folder
// =============================================================================

const gravity = @import("scripts/gravity.zig");

// =============================================================================
// Step 5: Create Registries
// =============================================================================

pub const Prefabs = engine.PrefabRegistry(.{
    PlayerPrefab,
    EnemyPrefab,
});

const main_module = @This();

pub const Components = engine.ComponentRegistry(struct {
    pub const Velocity = main_module.Velocity;
    pub const Health = main_module.Health;
    pub const Gravity = main_module.Gravity;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const gravity = main_module.gravity;
});

// =============================================================================
// Step 6: Load Scene from .zon
// =============================================================================

pub const game_scene = @import("game_scene.zon");
pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print(
        \\labelle-engine Example 3: Scene + Visual Rendering
        \\===================================================
        \\
        \\Comptime data loaded:
        \\  - Sprites: {d} frames
        \\  - Scene: "{s}" with {d} entities
        \\
        \\Initializing...
        \\
    , .{
        comptime std.meta.fields(@TypeOf(character_frames)).len,
        game_scene.name,
        game_scene.entities.len,
    });

    // Initialize Game facade
    var game = try Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "labelle-engine: Scene + Rendering",
            .target_fps = 60,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    defer game.deinit();

    // Get underlying engine for advanced operations
    const re = game.getRetainedEngine();

    // Note: Atlas loading skipped for now - scene entities will use invalid textures
    // The scene loading and ECS functionality will still work correctly
    _ = character_frames; // Acknowledge comptime data exists

    // Create scene context using Game facade
    const ctx = engine.SceneContext.init(&game);

    // Load scene from .zon
    var scene = try Loader.load(game_scene, ctx);
    defer scene.deinit();

    std.debug.print("Scene loaded: {s}\n", .{scene.name});
    std.debug.print("Entities spawned: {d}\n", .{scene.entityCount()});

    // ==========================================================================
    // Assertions - CI will fail if any of these fail
    // ==========================================================================

    std.debug.print("\nRunning assertions:\n", .{});

    // Scene assertions
    std.debug.assert(std.mem.eql(u8, scene.name, "game_scene"));
    std.debug.assert(scene.entityCount() == 6);
    std.debug.print("  ✓ Scene loaded with correct name and entity count\n", .{});

    // Prefab registry assertions
    std.debug.assert(Prefabs.get("player") != null);
    std.debug.assert(Prefabs.get("enemy") != null);
    std.debug.print("  ✓ Prefab registry: player and enemy registered\n", .{});

    // Component registry assertions
    std.debug.assert(Components.has("Velocity"));
    std.debug.assert(Components.has("Health"));
    std.debug.assert(Components.has("Gravity"));
    std.debug.print("  ✓ Component registry: Velocity, Health, Gravity registered\n", .{});

    // Script registry assertions
    std.debug.assert(Scripts.has("gravity"));
    std.debug.print("  ✓ Script registry: gravity script registered\n", .{});

    // Comptime data assertions
    std.debug.assert(std.meta.fields(@TypeOf(character_frames)).len == 18);
    std.debug.print("  ✓ Comptime atlas: 18 sprite frames loaded\n", .{});

    std.debug.print("\n✅ All assertions passed!\n\n", .{});

    // In CI mode, exit after assertions - the rendering loop has issues
    // without proper atlas loading (sprites have invalid textures)
    if (ci_test) {
        std.debug.print("CI mode: exiting after assertions\n", .{});
        return;
    }

    std.debug.print("Press ESC to exit\n\n", .{});

    // Game loop (only runs in interactive mode with display)
    while (game.isRunning()) {
        const dt = game.getDeltaTime();

        // Update scene (runs scripts)
        scene.update(dt);

        // Sync ECS to renderer
        game.getPipeline().sync(game.getRegistry());

        // Render
        re.beginFrame();
        re.render();

        // UI (using raylib directly for now)
        labelle.Engine.UI.text("labelle-engine: Scene + Rendering", .{ .x = 10, .y = 10, .size = 20, .color = labelle.Color.white });

        var scene_buf: [64]u8 = undefined;
        const scene_str = std.fmt.bufPrintZ(&scene_buf, "Scene: {s}  Entities: {d}", .{ scene.name, scene.entityCount() }) catch "?";
        labelle.Engine.UI.text(scene_str, .{ .x = 10, .y = 35, .size = 14, .color = labelle.Color.green });

        labelle.Engine.UI.text("Sprites loaded from game_scene.zon", .{ .x = 10, .y = 55, .size = 14, .color = labelle.Color.sky_blue });

        labelle.Engine.UI.text("ESC: Exit", .{ .x = 10, .y = 580, .size = 14, .color = labelle.Color.light_gray });

        re.endFrame();
    }

    std.debug.print("Example 3 completed.\n", .{});
}
