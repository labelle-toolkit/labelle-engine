//! Scene Core Types
//!
//! Runtime scene types: Scene, SceneContext, EntityInstance

const std = @import("std");
const ecs = @import("ecs");
const core_mod = @import("../../core/mod.zig");
const engine_mod = @import("../../engine/game.zig");
const script_mod = @import("script.zig");

pub const Entity = ecs.Entity;
pub const Registry = ecs.Registry;
pub const Game = engine_mod.Game;
pub const entityToU64 = core_mod.entityToU64;

/// Visual type for entity instances (render-agnostic)
pub const VisualType = enum {
    none, // Entity has no visual (e.g., nested data-only entities)
    sprite,
    shape,
    text,
};

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

    pub fn allocator(self: *const SceneContext) std.mem.Allocator {
        return self.game().allocator;
    }
};

/// Runtime scene instance that tracks loaded entities
pub const Scene = struct {
    name: []const u8,
    entities: std.ArrayListUnmanaged(EntityInstance),
    scripts: []const script_mod.ScriptFns,
    /// GUI view names to render with this scene (from .gui_views in scene .zon)
    gui_view_names: []const []const u8 = &.{},
    ctx: SceneContext,
    initialized: bool = false,
    /// Tracks allocated entity slices for cleanup (used by nested entity composition)
    allocated_entity_slices: std.ArrayListUnmanaged([]Entity) = .{},

    pub fn init(
        name: []const u8,
        scripts: []const script_mod.ScriptFns,
        gui_view_names: []const []const u8,
        ctx: SceneContext,
    ) Scene {
        return .{
            .name = name,
            .entities = .{},
            .scripts = scripts,
            .gui_view_names = gui_view_names,
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

        // Register entity destroy cleanup callback so destroyed entities
        // are removed from the scene's list at destroy time (zero per-frame cost)
        const g = self.ctx.game();
        g.on_entity_destroy_cleanup = .{
            .context = @ptrCast(self),
            .callback = removeEntityCallback,
        };

        for (self.scripts) |script_fns| {
            if (script_fns.init) |init_fn| {
                init_fn(self.ctx.game_ptr, @ptrCast(self));
            }
        }
    }

    /// Remove an entity from the scene's entity list (called via destroy cleanup callback).
    pub fn removeEntity(self: *Scene, entity: Entity) void {
        for (self.entities.items, 0..) |instance, i| {
            if (instance.entity == entity) {
                _ = self.entities.swapRemove(i);
                return;
            }
        }
    }

    /// Static callback for Game.EntityDestroyCleanup — casts context to *Scene and calls removeEntity.
    fn removeEntityCallback(ctx: *anyopaque, entity: Entity) void {
        const scene: *Scene = @ptrCast(@alignCast(ctx));
        scene.removeEntity(entity);
    }

    pub fn deinit(self: *Scene) void {
        const alloc = self.ctx.allocator();
        const g = self.ctx.game();

        // 1. Script deinit (may destroy entities → callback → removeEntity)
        if (self.initialized) {
            var i = self.scripts.len;
            while (i > 0) {
                i -= 1;
                if (self.scripts[i].deinit) |deinit_fn| {
                    deinit_fn(self.ctx.game_ptr, @ptrCast(self));
                }
            }
        }

        // 2. Deregister callback (so bulk destroy below doesn't trigger swapRemove)
        g.on_entity_destroy_cleanup = null;

        // 3. Destroy remaining entities (no callback fires, no swapRemove)
        for (self.entities.items) |*instance| {
            if (instance.onDestroy) |destroy_fn| {
                destroy_fn(entityToU64(instance.entity), @ptrCast(g));
            }
            g.getPipeline().untrackEntity(instance.entity);
            g.getRegistry().destroy(instance.entity);
        }

        // 4. Free entity list and allocated slices
        self.entities.deinit(alloc);

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

        // Call prefab onUpdate hooks (reverse iteration: safe with swapRemove during callbacks)
        const g = self.ctx.game();
        var i: usize = self.entities.items.len;
        while (i > 0) {
            i -= 1;
            if (i >= self.entities.items.len) continue;
            const entity_instance = self.entities.items[i];
            if (entity_instance.onUpdate) |update_fn| {
                update_fn(entityToU64(entity_instance.entity), @ptrCast(g), dt);
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
