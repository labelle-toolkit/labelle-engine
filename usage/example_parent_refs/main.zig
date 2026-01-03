// ============================================================================
// Example: Parent References & onReady Callbacks (RFC #169)
// ============================================================================
//
// This example demonstrates:
// 1. Convention-based parent reference population
// 2. onReady callbacks that fire after hierarchy completion
//
// When a component (like Storage) is created as a nested entity inside another
// component (like Workstation), the loader automatically populates a parent
// reference field if one exists following the naming convention:
//
//   - Parent component: Workstation
//   - Child component field: workstation (lowercase parent name)
//   - Result: Storage.workstation = parent Workstation entity
//
// Callback order:
// 1. Workstation created → Workstation.onAdd
// 2. Storage entities created (parent ref set before add) → Storage.onAdd
// 3. Workstation.storages array populated
// 4. --- Hierarchy complete ---
// 5. Workstation.onReady (can access full storages array)
// 6. Storage.onReady (can access parent and siblings)

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const ProjectConfig = engine.ProjectConfig;

// Import components
const workstation_comp = @import("components/workstation.zig");
const storage_comp = @import("components/storage.zig");
pub const Workstation = workstation_comp.Workstation;
pub const Storage = storage_comp.Storage;

// Import prefabs
const workstation_prefab = @import("prefabs/workstation.zon");

const main_module = @This();

// Registries
pub const Prefabs = engine.PrefabRegistry(.{
    .workstation = workstation_prefab,
});

pub const Components = engine.ComponentRegistry(struct {
    // Engine built-in components
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
    // Project components
    pub const Workstation = main_module.Workstation;
    pub const Storage = main_module.Storage;
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

    std.log.info("=== Loading scene - watch for callback order ===", .{});
    const ctx = engine.SceneContext.init(&game);
    var scene = try Loader.load(initial_scene, ctx);
    defer scene.deinit();
    std.log.info("=== Scene loaded - all onReady callbacks have fired ===", .{});

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
