// Scene Core — Runtime scene and entity instance types
//
// Ported from v1 scene/src/core.zig

const std = @import("std");
const labelle_core = @import("labelle-core");

// ScriptFns re-exported here so scene/src/root.zig can expose it
const script_mod = @import("script.zig");
pub const ScriptFns = script_mod.ScriptFns;
pub const VisualType = labelle_core.VisualType;

// ============================================================
// Parent-child hierarchy components (re-exported from labelle-core)
// ============================================================

pub const ParentComponent = labelle_core.ParentComponent;
pub const ChildrenComponent = labelle_core.ChildrenComponent;

// ============================================================
// Scene runtime
// ============================================================

/// Runtime scene — tracks loaded entities, runs scripts, manages lifecycle.
pub fn Scene(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const EntityInstance = struct {
            entity: Entity,
            visual_type: VisualType = .sprite,
            prefab_name: ?[]const u8 = null,
            persistent: bool = false,
            onUpdate: ?*const fn (u64, *anyopaque, f32) void = null,
            onDestroy: ?*const fn (u64, *anyopaque) void = null,
        };

        const NameMap = std.StringHashMapUnmanaged(Entity);

        name: []const u8,
        entities: std.ArrayListUnmanaged(EntityInstance),
        named_entities: NameMap,
        /// GUI view names to render with this scene (from .gui_views in scene .zon)
        gui_view_names: []const []const u8 = &.{},
        allocator: std.mem.Allocator,
        game_ptr: *anyopaque,
        /// Type-erased callback to game.destroyEntity() — used to clean up ECS on scene unload.
        destroy_entity_fn: ?*const fn (*anyopaque, Entity) void = null,

        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            gui_view_names: []const []const u8,
            game_ptr: *anyopaque,
            destroy_entity_fn: ?*const fn (*anyopaque, Entity) void,
        ) Self {
            return .{
                .name = name,
                .entities = .{},
                .named_entities = .{},
                .gui_view_names = gui_view_names,
                .allocator = allocator,
                .game_ptr = game_ptr,
                .destroy_entity_fn = destroy_entity_fn,
            };
        }

        pub fn deinit(self: *Self) void {
            // Destroy non-persistent entities in the ECS; fire onDestroy hooks.
            // Persistent entities survive scene unload (DontDestroyOnLoad pattern).
            for (self.entities.items) |*instance| {
                if (instance.onDestroy) |destroy_fn| {
                    if (!instance.persistent) {
                        destroy_fn(entityToU64(instance.entity), self.game_ptr);
                    }
                }
                if (!instance.persistent) {
                    if (self.destroy_entity_fn) |destroy_fn| {
                        destroy_fn(self.game_ptr, instance.entity);
                    }
                }
            }

            self.entities.deinit(self.allocator);
            self.named_entities.deinit(self.allocator);
        }

        /// Look up a named entity registered during scene loading.
        pub fn getEntityByName(self: *const Self, name: []const u8) ?Entity {
            return self.named_entities.get(name);
        }

        /// Register a named entity (called by the scene loader).
        pub fn registerName(self: *Self, name: []const u8, entity: Entity) !void {
            try self.named_entities.put(self.allocator, name, entity);
        }

        /// Per-frame update: runs entity onUpdate hooks.
        /// Script lifecycle is handled by ScriptRunner, not by Scene.
        pub fn update(self: *Self, dt: f32) void {
            // Entity onUpdate hooks (reverse iteration for safe removal)
            var i: usize = self.entities.items.len;
            while (i > 0) {
                i -= 1;
                if (i >= self.entities.items.len) continue;
                const instance = self.entities.items[i];
                if (instance.onUpdate) |update_fn| {
                    update_fn(entityToU64(instance.entity), self.game_ptr, dt);
                }
            }
        }

        pub fn removeEntity(self: *Self, entity: Entity) void {
            for (self.entities.items, 0..) |instance, idx| {
                if (instance.entity == entity) {
                    _ = self.entities.swapRemove(idx);
                    return;
                }
            }
        }

        pub fn addEntity(self: *Self, instance: EntityInstance) !void {
            try self.entities.append(self.allocator, instance);
        }

        pub fn entityCount(self: *const Self) usize {
            return self.entities.items.len;
        }

        fn entityToU64(entity: Entity) u64 {
            if (Entity == u32) return @intCast(entity);
            if (Entity == u64) return entity;
            if (@hasDecl(Entity, "toU64")) return entity.toU64();
            return @intCast(@as(u32, @bitCast(entity)));
        }
    };
}
