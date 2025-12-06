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

// Re-export commonly used types
pub const Prefab = prefab.Prefab;
pub const SpriteConfig = prefab.SpriteConfig;
pub const PrefabRegistry = prefab.PrefabRegistry;
pub const SceneLoader = loader.SceneLoader;
pub const ComponentRegistry = component.ComponentRegistry;
pub const ScriptRegistry = script.ScriptRegistry;

// Re-export labelle types used by scenes
pub const VisualEngine = labelle.VisualEngine;
pub const SpriteId = labelle.visual_engine.SpriteId;
pub const ZIndex = labelle.ZIndex;

// Re-export ECS types
pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

/// Context passed to prefab lifecycle functions and scene loading
pub const SceneContext = struct {
    engine: *VisualEngine,
    registry: *Registry,
    allocator: std.mem.Allocator,

    pub fn init(engine: *VisualEngine, registry: *Registry, allocator: std.mem.Allocator) SceneContext {
        return .{
            .engine = engine,
            .registry = registry,
            .allocator = allocator,
        };
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
        // Call onDestroy for all entities and destroy ECS entities
        for (self.entities.items) |*instance| {
            if (instance.onDestroy) |destroy_fn| {
                destroy_fn(instance.sprite_id, self.ctx.engine);
            }
            self.ctx.registry.destroy(instance.entity);
        }
        self.entities.deinit(self.ctx.allocator);
    }

    pub fn update(self: *Scene, dt: f32) void {
        // Call prefab onUpdate hooks
        for (self.entities.items) |*entity| {
            if (entity.onUpdate) |update_fn| {
                update_fn(entity.sprite_id, self.ctx.engine, dt);
            }
        }

        // Call scene scripts
        for (self.scripts) |script_update| {
            script_update(self.ctx.registry, self.ctx.engine, self, dt);
        }
    }

    pub fn addEntity(self: *Scene, instance: EntityInstance) !void {
        try self.entities.append(self.ctx.allocator, instance);
    }

    pub fn spriteCount(self: *const Scene) usize {
        return self.entities.items.len;
    }
};

/// Runtime entity instance
pub const EntityInstance = struct {
    entity: Entity,
    sprite_id: SpriteId,
    prefab_name: ?[]const u8 = null,
    onUpdate: ?*const fn (SpriteId, *VisualEngine, f32) void = null,
    onDestroy: ?*const fn (SpriteId, *VisualEngine) void = null,
};

test "scene module" {
    // Basic import test
    _ = prefab;
    _ = loader;
}
