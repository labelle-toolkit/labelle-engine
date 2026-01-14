// ============================================================================
// Example: Entity References (Issue #242)
// ============================================================================
//
// This example demonstrates entity-to-entity references using the .ref syntax:
//
// 1. Reference by ID:   .{ .ref = .{ .id = "player_1" } }
//    - Uses unique identifier
//    - Recommended for editors/UI tools
//    - Auto-generated as _e0, _e1... if not specified
//
// 2. Reference by name: .{ .ref = .{ .entity = "player" } }
//    - Uses display name
//    - Can have duplicates (e.g., "enemy" for all enemies)
//    - Good for quick prototyping
//
// 3. Self-reference:    .{ .ref = .self }
//    - References the same entity being defined
//    - Useful for HealthBar reading from its own Health component
//
// References are resolved in two phases:
// 1. Phase 1: All entities created, IDs/names registered
// 2. Phase 2: References resolved after all entities exist (forward refs work)

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const ProjectConfig = engine.ProjectConfig;

// Import components
const ai_comp = @import("components/ai.zig");
const health_bar_comp = @import("components/health_bar.zig");
const health_comp = @import("components/health.zig");

pub const AI = ai_comp.AI;
pub const HealthBar = health_bar_comp.HealthBar;
pub const Health = health_comp.Health;

// Import prefabs
const player_prefab = @import("prefabs/player.zon");
const enemy_prefab = @import("prefabs/enemy.zon");

const main_module = @This();

// Registries
pub const Prefabs = engine.PrefabRegistry(.{
    .player = player_prefab,
    .enemy = enemy_prefab,
});

pub const Components = engine.ComponentRegistry(struct {
    // Engine built-in components
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
    // Project components
    pub const AI = main_module.AI;
    pub const HealthBar = main_module.HealthBar;
    pub const Health = main_module.Health;
});

pub const Scripts = engine.ScriptRegistry(struct {});
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
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    game.fixPointers();
    defer game.deinit();

    // Apply camera configuration
    if (project.camera.x != null or project.camera.y != null) {
        game.setCameraPosition(project.camera.x orelse 0, project.camera.y orelse 0);
    }
    if (project.camera.zoom != 1.0) {
        game.setCameraZoom(project.camera.zoom);
    }

    std.log.info("=== Loading scene with entity references ===", .{});
    const ctx = engine.SceneContext.init(&game);
    var scene = try Loader.load(initial_scene, ctx);
    defer scene.deinit();
    std.log.info("=== Scene loaded - all references resolved ===", .{});

    // Log entity reference summary
    logReferenceSummary(&game);

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

fn logReferenceSummary(game: *Game) void {
    _ = game;
    std.log.info("", .{});
    std.log.info("=== Entity References Demo ===", .{});
    std.log.info("  - 4 enemies targeting player (via .ref.id)", .{});
    std.log.info("  - 1 player with self-referencing health bar", .{});
    std.log.info("===============================", .{});
    std.log.info("", .{});
}
