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
    scripts: []const script.UpdateFn,
    ctx: SceneContext,

    pub fn init(name: []const u8, scripts: []const script.UpdateFn, ctx: SceneContext) Scene {
        return .{
            .name = name,
            .entities = .{},
            .scripts = scripts,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Scene) void {
        const alloc = self.ctx.allocator();
        const reg = self.ctx.registry();
        const pipe = self.ctx.pipeline();

        // Call onDestroy for all entities and destroy ECS entities
        for (self.entities.items) |*instance| {
            if (instance.onDestroy) |destroy_fn| {
                destroy_fn(@bitCast(instance.entity), @ptrCast(self.ctx.game));
            }
            pipe.untrackEntity(instance.entity);
            reg.destroy(instance.entity);
        }
        self.entities.deinit(alloc);
    }

    pub fn update(self: *Scene, dt: f32) void {
        // Call prefab onUpdate hooks
        for (self.entities.items) |*entity_instance| {
            if (entity_instance.onUpdate) |update_fn| {
                update_fn(@bitCast(entity_instance.entity), @ptrCast(self.ctx.game), dt);
            }
        }

        // Call scene scripts
        for (self.scripts) |script_update| {
            script_update(self.ctx.game, self, dt);
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
/// Uses u32 for entity and *anyopaque for lifecycle hooks to avoid circular imports in prefab.zig.
/// This is necessary because prefab.zig cannot import game.zig without creating a cycle.
///
/// When implementing lifecycle hooks in prefabs, cast the parameters as follows:
/// ```zig
/// pub fn onCreate(entity_u32: u32, game_ptr: *anyopaque) void {
///     const entity: Entity = @bitCast(entity_u32);
///     const game: *Game = @ptrCast(@alignCast(game_ptr));
///     // ... use entity and game
/// }
/// ```
pub const EntityInstance = struct {
    entity: Entity,
    visual_type: VisualType = .sprite,
    prefab_name: ?[]const u8 = null,
    onUpdate: ?*const fn (u32, *anyopaque, f32) void = null,
    onDestroy: ?*const fn (u32, *anyopaque) void = null,

    // Compile-time verification that Entity can be safely cast to u32
    comptime {
        if (@sizeOf(Entity) != @sizeOf(u32)) {
            @compileError("Entity must be the same size as u32 for @bitCast in lifecycle hooks");
        }
    }
};

