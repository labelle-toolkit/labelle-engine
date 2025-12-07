//! Example 4: Primitives with Scene Loading
//!
//! This example demonstrates how to create a game scene using
//! primitive shapes (circles and rectangles) loaded from a .zon file.
//!
//! Features demonstrated:
//! - Scene loading with shape entities from game_scene.zon
//! - Circle and rectangle primitives
//! - ECS components attached to shape entities
//! - Scripts that animate shapes
//!
//! Build and run:
//!   cd usage/example_4
//!   zig build run

const std = @import("std");
const engine = @import("labelle-engine");
const labelle = @import("labelle");

const VisualEngine = labelle.visual_engine.VisualEngine;

// =============================================================================
// Step 1: Import Components
// =============================================================================

const velocity = @import("components/velocity.zig");
pub const Velocity = velocity.Velocity;

// =============================================================================
// Step 2: Import Scripts
// =============================================================================

const movement = @import("scripts/movement.zig");

// =============================================================================
// Step 3: Create Registries (no prefabs for this example)
// =============================================================================

pub const Prefabs = engine.PrefabRegistry(.{});

const main_module = @This();

pub const Components = engine.ComponentRegistry(struct {
    pub const Velocity = main_module.Velocity;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const movement = main_module.movement;
});

// =============================================================================
// Step 4: Load Scene from .zon
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
        \\labelle-engine Example 4: Primitives with Scene Loading
        \\========================================================
        \\
        \\This example shows how to create game scenes using
        \\primitive shapes loaded from a .zon file.
        \\
        \\Scene: "{s}" with {d} entities
        \\
        \\Initializing...
        \\
    , .{
        game_scene.name,
        game_scene.entities.len,
    });

    // Initialize visual engine
    var ve = try VisualEngine.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "labelle-engine: Primitives Example",
            .target_fps = 60,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 20, .g = 25, .b = 35 },
    });
    defer ve.deinit();

    // Initialize ECS registry
    var registry = engine.Registry.init(allocator);
    defer registry.deinit();

    // Create scene context
    const ctx = engine.SceneContext.init(&ve, &registry, allocator);

    // Load scene from .zon
    var scene = try Loader.load(game_scene, ctx);
    defer scene.deinit();

    std.debug.print("Scene loaded: {s}\n", .{scene.name});
    std.debug.print("Entities spawned: {d}\n", .{scene.spriteCount()});

    // ==========================================================================
    // Assertions for CI
    // ==========================================================================

    std.debug.print("\nRunning assertions:\n", .{});

    std.debug.assert(std.mem.eql(u8, scene.name, "primitives_scene"));
    std.debug.assert(scene.spriteCount() == 12); // 1 sun + 1 ground + 3 buildings + 2 circles + 4 stars + 1 moving ball
    std.debug.print("  ✓ Scene loaded with correct name and entity count\n", .{});

    std.debug.assert(Components.has("Velocity"));
    std.debug.print("  ✓ Component registry: Velocity registered\n", .{});

    std.debug.assert(Scripts.has("movement"));
    std.debug.print("  ✓ Script registry: movement script registered\n", .{});

    std.debug.print("\n✅ All assertions passed!\n\n", .{});

    var frame_count: u32 = 0;

    std.debug.print("Press ESC to exit\n\n", .{});

    // Game loop
    while (ve.isRunning()) {
        frame_count += 1;

        if (ci_test) {
            if (frame_count == 30) ve.takeScreenshot("screenshot_example4.png");
            if (frame_count == 35) break;
        }

        const dt = ve.getDeltaTime();

        // Update scene (runs scripts)
        scene.update(dt);

        // Render
        ve.beginFrame();
        ve.tick(dt);

        // UI
        labelle.Engine.UI.text("labelle-engine: Primitives from Scene", .{ .x = 10, .y = 10, .size = 20, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });

        var scene_buf: [64]u8 = undefined;
        const scene_str = std.fmt.bufPrintZ(&scene_buf, "Scene: {s}  Shapes: {d}", .{ scene.name, scene.spriteCount() }) catch "?";
        labelle.Engine.UI.text(scene_str, .{ .x = 10, .y = 35, .size = 14, .color = .{ .r = 0, .g = 255, .b = 0, .a = 255 } });

        labelle.Engine.UI.text("Shapes loaded from game_scene.zon", .{ .x = 10, .y = 55, .size = 14, .color = .{ .r = 135, .g = 206, .b = 235, .a = 255 } });
        labelle.Engine.UI.text("ESC: Exit", .{ .x = 10, .y = 580, .size = 14, .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 } });

        ve.endFrame();
    }

    std.debug.print("Example 4 completed.\n", .{});
}
