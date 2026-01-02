//! Scene Core Types
//!
//! Runtime scene types: Scene, SceneContext, EntityInstance

const std = @import("std");
const ecs = @import("ecs");
const core_mod = @import("../core/mod.zig");
const render_mod = @import("../render/src/pipeline.zig");
const engine_mod = @import("../engine/game.zig");
const script_mod = @import("script.zig");

pub const Entity = ecs.Entity;
pub const Registry = ecs.Registry;
pub const Game = engine_mod.Game;
pub const RenderPipeline = render_mod.RenderPipeline;
pub const VisualType = render_mod.VisualType;
pub const entityToU64 = core_mod.entityToU64;

/// Context passed to prefab lifecycle functions and scene loading
/// Uses Game facade for unified access to ECS, pipeline, and engine
pub const SceneContext = struct {
    game_ptr: *anyopaque,

    /// Initialize SceneContext with any GameWith(Hooks) type
    pub fn init(g: anytype) SceneContext {
        return .{ .game_ptr = @ptrCast(g) };
    }

    /// Get the underlying Game pointer (as base Game type)
    pub fn game(self: *const SceneContext) *Game {
        return @ptrCast(@alignCast(self.game_ptr));
    }

    // Convenience accessors
    pub fn registry(self: *const SceneContext) *Registry {
        return self.game().getRegistry();
    }

    pub fn pipeline(self: *const SceneContext) *RenderPipeline {
        return self.game().getPipeline();
    }

    pub fn allocator(self: *const SceneContext) std.mem.Allocator {
        return self.game().allocator;
    }
};

/// Runtime scene instance that tracks loaded entities
pub const Scene = struct {
    name: []const u8,
    entities: std.ArrayListUnmanaged(EntityInstance),
    scripts: []const script_mod.ScriptFns,
    ctx: SceneContext,
    initialized: bool = false,
    /// Tracks allocated entity slices for cleanup (used by nested entity composition)
    allocated_entity_slices: std.ArrayListUnmanaged([]Entity) = .{},

    pub fn init(name: []const u8, scripts: []const script_mod.ScriptFns, ctx: SceneContext) Scene {
        return .{
            .name = name,
            .entities = .{},
            .scripts = scripts,
            .ctx = ctx,
            .initialized = false,
            .allocated_entity_slices = .{},
        };
    }

    /// Register an allocated entity slice for cleanup on scene deinit.
    /// Used by nested entity composition to track dynamically allocated slices.
    pub fn trackAllocatedSlice(self: *Scene, slice: []Entity) !void {
        try self.allocated_entity_slices.append(self.ctx.allocator(), slice);
    }

    /// Call all script init functions. Called automatically on first update,
    /// but can be called manually if needed before the game loop starts.
    pub fn initScripts(self: *Scene) void {
        if (self.initialized) return;
        self.initialized = true;

        for (self.scripts) |script_fns| {
            if (script_fns.init) |init_fn| {
                init_fn(self.ctx.game_ptr, @ptrCast(self));
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
                    deinit_fn(self.ctx.game_ptr, @ptrCast(self));
                }
            }
        }

        // Call onDestroy for all entities and destroy ECS entities
        for (self.entities.items) |*instance| {
            if (instance.onDestroy) |destroy_fn| {
                destroy_fn(entityToU64(instance.entity), @ptrCast(self.ctx.game()));
            }
            pipe.untrackEntity(instance.entity);
            reg.destroy(instance.entity);
        }
        self.entities.deinit(alloc);

        // Free allocated entity slices (from nested entity composition)
        for (self.allocated_entity_slices.items) |slice| {
            alloc.free(slice);
        }
        self.allocated_entity_slices.deinit(alloc);
    }

    pub fn update(self: *Scene, dt: f32) void {
        // Initialize scripts on first update if not already done
        if (!self.initialized) {
            self.initScripts();
        }

        // Call prefab onUpdate hooks
        for (self.entities.items) |*entity_instance| {
            if (entity_instance.onUpdate) |update_fn| {
                update_fn(entityToU64(entity_instance.entity), @ptrCast(self.ctx.game()), dt);
            }
        }

        // Call scene script update functions
        for (self.scripts) |script_fns| {
            if (script_fns.update) |update_fn| {
                update_fn(self.ctx.game_ptr, @ptrCast(self), dt);
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
