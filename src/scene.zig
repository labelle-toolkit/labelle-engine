// Scene module - declarative scene and prefab system using comptime .zon files
//
// This module provides:
// - Prefabs: comptime struct templates with optional lifecycle hooks
// - Scenes: .zon files that declare entities (prefabs or inline components)
// - Components: ECS components that can be attached to entities
// - Comptime merging of prefab defaults with scene overrides

const std = @import("std");
const labelle = @import("labelle");
const ecs = @import("ecs");
const build_options = @import("build_options");

// Re-export build options for downstream users
pub const Backend = build_options.backend;

pub const prefab = @import("prefab.zig");
pub const loader = @import("loader.zig");
pub const component = @import("component.zig");
pub const script = @import("script.zig");
pub const game = @import("game.zig");
pub const build_helpers = @import("build_helpers.zig");
pub const render_pipeline = @import("render_pipeline.zig");
pub const project_config = @import("project_config.zig");
pub const generator = @import("generator.zig");

// Re-export commonly used types
pub const Prefab = prefab.Prefab;
pub const SpriteConfig = prefab.SpriteConfig;
pub const PrefabRegistry = prefab.PrefabRegistry;
pub const SceneLoader = loader.SceneLoader;
pub const ComponentRegistry = component.ComponentRegistry;
pub const ScriptRegistry = script.ScriptRegistry;
pub const ScriptFns = script.ScriptFns;
pub const InitFn = script.InitFn;
pub const DeinitFn = script.DeinitFn;
pub const Game = game.Game;
pub const GameConfig = game.GameConfig;
pub const WindowConfig = game.WindowConfig;

// Re-export render pipeline types
pub const RenderPipeline = render_pipeline.RenderPipeline;
pub const Position = render_pipeline.Position;
pub const Sprite = render_pipeline.Sprite;
pub const Shape = render_pipeline.Shape;
pub const Text = render_pipeline.Text;
pub const VisualType = render_pipeline.VisualType;
pub const RetainedEngine = render_pipeline.RetainedEngine;
pub const TextureId = render_pipeline.TextureId;
pub const FontId = render_pipeline.FontId;
pub const Color = render_pipeline.Color;

// Re-export ZIndex from prefab for backwards compatibility
pub const ZIndex = prefab.ZIndex;

// Re-export Camera types from labelle-gfx
pub const Camera = labelle.Camera;
pub const CameraManager = labelle.CameraManager;
pub const SplitScreenLayout = labelle.SplitScreenLayout;

// Re-export scene camera config from loader
pub const SceneCameraConfig = loader.SceneCameraConfig;
pub const CameraSlot = loader.CameraSlot;

// Re-export ECS types
pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

// Re-export project config types
pub const ProjectConfig = project_config.ProjectConfig;
pub const Plugin = project_config.Plugin;

/// Context passed to prefab lifecycle functions and scene loading
/// Uses Game facade for unified access to ECS, pipeline, and engine
pub const SceneContext = struct {
    game: *Game,

    pub fn init(g: *Game) SceneContext {
        return .{ .game = g };
    }

    // Convenience accessors
    pub fn registry(self: *SceneContext) *Registry {
        return self.game.getRegistry();
    }

    pub fn pipeline(self: *SceneContext) *RenderPipeline {
        return self.game.getPipeline();
    }

    pub fn allocator(self: *SceneContext) std.mem.Allocator {
        return self.game.allocator;
    }
};

/// Runtime scene instance that tracks loaded entities
pub const Scene = struct {
    name: []const u8,
    entities: std.ArrayListUnmanaged(EntityInstance),
    scripts: []const script.ScriptFns,
    ctx: SceneContext,
    initialized: bool = false,

    pub fn init(name: []const u8, scripts: []const script.ScriptFns, ctx: SceneContext) Scene {
        return .{
            .name = name,
            .entities = .{},
            .scripts = scripts,
            .ctx = ctx,
            .initialized = false,
        };
    }

    /// Call all script init functions. Called automatically on first update,
    /// but can be called manually if needed before the game loop starts.
    pub fn initScripts(self: *Scene) void {
        if (self.initialized) return;
        self.initialized = true;

        for (self.scripts) |script_fns| {
            if (script_fns.init) |init_fn| {
                init_fn(self.ctx.game, self);
            }
        }
    }

    pub fn deinit(self: *Scene) void {
        const alloc = self.ctx.allocator();
        const reg = self.ctx.registry();
        const pipe = self.ctx.pipeline();

        // Call script deinit functions (in reverse order for proper cleanup)
        if (self.initialized) {
            var i = self.scripts.len;
            while (i > 0) {
                i -= 1;
                if (self.scripts[i].deinit) |deinit_fn| {
                    deinit_fn(self.ctx.game, self);
                }
            }
        }

        // Call onDestroy for all entities and destroy ECS entities
        for (self.entities.items) |*instance| {
            if (instance.onDestroy) |destroy_fn| {
                destroy_fn(entityToU64(instance.entity), @ptrCast(self.ctx.game));
            }
            pipe.untrackEntity(instance.entity);
            reg.destroy(instance.entity);
        }
        self.entities.deinit(alloc);
    }

    pub fn update(self: *Scene, dt: f32) void {
        // Initialize scripts on first update if not already done
        if (!self.initialized) {
            self.initScripts();
        }

        // Call prefab onUpdate hooks
        for (self.entities.items) |*entity_instance| {
            if (entity_instance.onUpdate) |update_fn| {
                update_fn(entityToU64(entity_instance.entity), @ptrCast(self.ctx.game), dt);
            }
        }

        // Call scene script update functions
        for (self.scripts) |script_fns| {
            if (script_fns.update) |update_fn| {
                update_fn(self.ctx.game, self, dt);
            }
        }
    }

    pub fn addEntity(self: *Scene, instance: EntityInstance) !void {
        try self.entities.append(self.ctx.allocator(), instance);
    }

    pub fn entityCount(self: *const Scene) usize {
        return self.entities.items.len;
    }
};

/// Runtime entity instance
///
/// Uses u64 for entity and *anyopaque for lifecycle hooks to avoid circular imports in prefab.zig.
/// This is necessary because prefab.zig cannot import game.zig without creating a cycle.
/// The u64 type accommodates both 32-bit (zig_ecs) and 64-bit (zflecs) entity IDs.
///
/// When implementing lifecycle hooks in prefabs, cast the parameters as follows:
/// ```zig
/// pub fn onCreate(entity_u64: u64, game_ptr: *anyopaque) void {
///     const entity: Entity = @bitCast(@as(EntityBits, @truncate(entity_u64)));
///     const game: *Game = @ptrCast(@alignCast(game_ptr));
///     // ... use entity and game
/// }
/// ```
/// Or use the helper function:
/// ```zig
/// pub fn onCreate(entity_u64: u64, game_ptr: *anyopaque) void {
///     const entity = entityFromU64(entity_u64);
///     const game: *Game = @ptrCast(@alignCast(game_ptr));
///     // ... use entity and game
/// }
/// ```
pub const EntityInstance = struct {
    entity: Entity,
    visual_type: VisualType = .sprite,
    prefab_name: ?[]const u8 = null,
    onUpdate: ?*const fn (u64, *anyopaque, f32) void = null,
    onDestroy: ?*const fn (u64, *anyopaque) void = null,

    // Compile-time verification that Entity fits in u64
    comptime {
        if (@sizeOf(Entity) > @sizeOf(u64)) {
            @compileError("Entity must fit in u64 for lifecycle hooks");
        }
    }
};

/// The underlying integer type that stores Entity bits
pub const EntityBits = std.meta.Int(.unsigned, @bitSizeOf(Entity));

/// Convert Entity to u64 for lifecycle hooks
pub fn entityToU64(entity: Entity) u64 {
    return @as(EntityBits, @bitCast(entity));
}

/// Convert u64 back to Entity in lifecycle hooks
pub fn entityFromU64(value: u64) Entity {
    return @bitCast(@as(EntityBits, @truncate(value)));
}

