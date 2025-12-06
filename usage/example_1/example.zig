//! Example usage of labelle-engine
//!
//! This file demonstrates how to use the labelle-engine library to create
//! a scene-based game with prefabs, components, and scripts.
//!
//! Scene definitions can be:
//! 1. Inline in code (see level1_scene below)
//! 2. Loaded from external .zon files (see level1_from_file)

const std = @import("std");
const engine = @import("labelle-engine");

// =============================================================================
// Step 1: Define your prefabs
// =============================================================================
// Prefabs are reusable entity templates with default configurations.
// They can have lifecycle hooks (onCreate, onUpdate, onDestroy).

pub const PlayerPrefab = struct {
    pub const name = "player";
    pub const sprite = engine.prefab.SpriteConfig{
        .name = "player.png",
        .x = 400,
        .y = 300,
        .z_index = engine.ZIndex.characters,
        .scale = 1.0,
    };
    pub const animation = "idle";

    pub fn onCreate(sprite_id: engine.SpriteId, ve: *engine.VisualEngine) void {
        _ = sprite_id;
        _ = ve;
        std.debug.print("Player created!\n", .{});
    }

    pub fn onUpdate(sprite_id: engine.SpriteId, ve: *engine.VisualEngine, dt: f32) void {
        _ = sprite_id;
        _ = ve;
        _ = dt;
        // Update player logic here
    }

    pub fn onDestroy(sprite_id: engine.SpriteId, ve: *engine.VisualEngine) void {
        _ = sprite_id;
        _ = ve;
        std.debug.print("Player destroyed!\n", .{});
    }
};

pub const EnemyPrefab = struct {
    pub const name = "enemy";
    pub const sprite = engine.prefab.SpriteConfig{
        .name = "enemy.png",
        .z_index = engine.ZIndex.characters,
        .scale = 0.8,
    };
    pub const animation = "patrol";
};

// Prefabs can inherit from other prefabs using the `base` field
pub const BossPrefab = struct {
    pub const name = "boss";
    pub const base = EnemyPrefab; // Inherits sprite config from EnemyPrefab
    pub const sprite = engine.prefab.SpriteConfig{
        .name = "boss.png", // Override the sprite name
        .scale = 2.0, // Override the scale
        // z_index is inherited from EnemyPrefab
    };
    pub const animation = "idle";
};

pub const BackgroundPrefab = struct {
    pub const name = "background";
    pub const sprite = engine.prefab.SpriteConfig{
        .name = "background.png",
        .x = 0,
        .y = 0,
        .z_index = engine.ZIndex.background,
    };
};

// =============================================================================
// Step 2: Define your components
// =============================================================================
// Components are data attached to entities for game logic.

pub const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

pub const Gravity = struct {
    strength: f32 = 9.8,
    enabled: bool = true,
};

pub const Collectible = struct {
    points: i32 = 10,
    collected: bool = false,
};

// =============================================================================
// Step 3: Define your scripts
// =============================================================================
// Scripts contain game logic that runs every frame for a scene.

pub const gravity_script = struct {
    pub fn update(
        registry: *engine.Registry,
        ve: *engine.VisualEngine,
        scene: *engine.Scene,
        dt: f32,
    ) void {
        _ = ve;
        _ = scene;

        // Query all entities with Velocity and Gravity components
        var view = registry.view(struct { vel: *Velocity, grav: *const Gravity }, .{});
        var iter = view.iterator();

        while (iter.next()) |item| {
            if (item.grav.enabled) {
                item.vel.y += item.grav.strength * dt;
            }
        }
    }
};

pub const movement_script = struct {
    pub fn update(
        registry: *engine.Registry,
        ve: *engine.VisualEngine,
        scene: *engine.Scene,
        dt: f32,
    ) void {
        _ = scene;

        // Apply velocity to sprite positions
        var view = registry.view(struct { vel: *const Velocity }, .{});
        var iter = view.iterator();

        while (iter.next()) |item| {
            // In a real implementation, you'd update the sprite position
            // through the visual engine based on entity mapping
            _ = ve;
            _ = dt;
            _ = item;
        }
    }
};

// =============================================================================
// Step 4: Create registries
// =============================================================================
// Registries map names to types for scene loading.

// Prefab registry - maps prefab names to prefab types
pub const Prefabs = engine.PrefabRegistry(.{
    PlayerPrefab,
    EnemyPrefab,
    BossPrefab,
    BackgroundPrefab,
});

// Component registry - maps component names to component types
// Note: We define components inside the registry struct to avoid naming conflicts
pub const Components = engine.ComponentRegistry(struct {
    pub const Velocity = example.Velocity;
    pub const Health = example.Health;
    pub const Gravity = example.Gravity;
    pub const Collectible = example.Collectible;
});

const example = @This();

// Script registry - maps script names to script modules
pub const Scripts = engine.ScriptRegistry(struct {
    pub const gravity = gravity_script;
    pub const movement = movement_script;
});

// =============================================================================
// Step 5: Define scenes using .zon format
// =============================================================================
// Scenes are declarative definitions of what entities exist in a level.
// You can define them inline or load from external .zon files.

// Option A: Load scene from external .zon file
// This allows level designers to edit scenes without recompiling code.
pub const level1_from_file = @import("level1.zon");

// Option B: Define scene inline in code
pub const level1_scene = .{
    .name = "level1",
    .scripts = .{ "gravity", "movement" },
    .entities = .{
        // Background (using prefab)
        .{ .prefab = "background" },

        // Player (using prefab with position override)
        .{
            .prefab = "player",
            .x = 100,
            .y = 200,
            .components = .{
                .Velocity = .{ .x = 0, .y = 0 },
                .Health = .{ .current = 100, .max = 100 },
            },
        },

        // Enemies (using prefab with different positions)
        .{
            .prefab = "enemy",
            .x = 500,
            .y = 200,
            .components = .{
                .Velocity = .{ .x = -50, .y = 0 },
                .Health = .{ .current = 50, .max = 50 },
            },
        },
        .{
            .prefab = "enemy",
            .x = 700,
            .y = 200,
            .components = .{
                .Velocity = .{ .x = -30, .y = 0 },
                .Health = .{ .current = 50, .max = 50 },
            },
        },

        // Inline entity (no prefab, just sprite definition)
        .{
            .sprite = .{ .name = "coin.png", .x = 300, .y = 150 },
            .components = .{
                .Collectible = .{ .points = 100 },
            },
        },

        // Boss
        .{
            .prefab = "boss",
            .x = 800,
            .y = 250,
            .components = .{
                .Health = .{ .current = 500, .max = 500 },
            },
        },
    },
};

// =============================================================================
// Step 6: Create the scene loader and load scenes
// =============================================================================

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

// Example of how to use the library in a game
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // In a real application, you would:
    // 1. Initialize the visual engine (labelle.VisualEngine)
    // 2. Initialize the ECS registry
    // 3. Create a scene context
    // 4. Load and run scenes

    std.debug.print(
        \\labelle-engine Example
        \\======================
        \\
        \\This example demonstrates:
        \\
        \\1. Prefabs - Reusable entity templates
        \\   - PlayerPrefab: Has lifecycle hooks (onCreate, onUpdate, onDestroy)
        \\   - EnemyPrefab: Basic enemy with animation
        \\   - BossPrefab: Inherits from EnemyPrefab with overrides
        \\   - BackgroundPrefab: Background layer
        \\
        \\2. Components - ECS data components
        \\   - Velocity: Movement speed
        \\   - Health: HP tracking
        \\   - Gravity: Physics
        \\   - Collectible: Pickup items
        \\
        \\3. Scripts - Per-frame game logic
        \\   - gravity_script: Applies gravity to entities
        \\   - movement_script: Moves entities by velocity
        \\
        \\4. Scenes - Declarative level definitions
        \\   - level1_scene: Inline scene definition
        \\   - level1_from_file: Loaded from level1.zon file
        \\
        \\Usage in a real game:
        \\
        \\  const ctx = engine.SceneContext.init(&visual_engine, &ecs_registry, allocator);
        \\
        \\  // Load scene from inline definition
        \\  var scene = try Loader.load(level1_scene, ctx);
        \\
        \\  // Or load scene from .zon file
        \\  var scene = try Loader.load(level1_from_file, ctx);
        \\
        \\  defer scene.deinit();
        \\
        \\  // Game loop
        \\  while (running) {{
        \\      scene.update(delta_time);
        \\  }}
        \\
    , .{});

    // Demonstrate prefab lookup
    std.debug.print("\nPrefab Registry Demo:\n", .{});
    if (Prefabs.get("player")) |player| {
        std.debug.print("  Found prefab: {s}\n", .{player.name});
        std.debug.print("  Sprite: {s} at ({d}, {d})\n", .{
            player.sprite.name,
            player.sprite.x,
            player.sprite.y,
        });
    }

    // Demonstrate component registry
    std.debug.print("\nComponent Registry Demo:\n", .{});
    std.debug.print("  Has 'Health': {}\n", .{Components.has("Health")});
    std.debug.print("  Has 'Unknown': {}\n", .{Components.has("Unknown")});

    // Demonstrate script registry
    std.debug.print("\nScript Registry Demo:\n", .{});
    std.debug.print("  Has 'gravity': {}\n", .{Scripts.has("gravity")});
    std.debug.print("  Has 'movement': {}\n", .{Scripts.has("movement")});

    // Demonstrate scene loading from .zon file
    std.debug.print("\nScene from .zon file (level1.zon):\n", .{});
    std.debug.print("  Name: {s}\n", .{level1_from_file.name});
    std.debug.print("  Scripts: {d}\n", .{level1_from_file.scripts.len});
    std.debug.print("  Entities: {d}\n", .{level1_from_file.entities.len});

    _ = allocator;
}
