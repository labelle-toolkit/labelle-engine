// zflecs adapter - wraps zig-gamedev/zflecs (flecs bindings) to conform to the ECS interface
//
// zflecs provides Zig bindings for the flecs ECS library (C-based).
// Flecs is a high-performance ECS with features like:
// - Archetype-based storage for cache-efficient iteration
// - Relationships and entity hierarchies
// - Built-in systems and queries
//
// This adapter provides a Registry-like interface that matches the labelle-engine API.

const std = @import("std");
const flecs = @import("zflecs");
const query_facade = @import("query.zig");

/// Module-level game pointer for component callbacks.
///
/// This is a **process-global singleton** shared by all `Registry` instances
/// using this adapter. It is intended for the common case where there is a
/// single "game" object per process that component callbacks need to access.
///
/// Limitations:
/// - Multiple registries **cannot** have different game pointers at the same time.
/// - Tests that create multiple registries must ensure they either share the same
///   game object or carefully control sequencing.
///
/// If you require per-registry game pointers, you must extend the `Registry`
/// type to carry that state explicitly instead of relying on this global.
var game_ptr: ?*anyopaque = null;

/// Set the global game pointer for component callbacks to access.
/// Pass null to clear the game pointer during cleanup.
///
/// In normal usage this is set automatically by `Game.fixPointers()`, so you
/// usually do not need to call this directly unless you are wiring a custom
/// game/registry setup.
pub fn setGamePtr(ptr: ?*anyopaque) void {
    game_ptr = ptr;
}

/// Get the global game pointer. Returns null if not set.
pub fn getGamePtr() ?*anyopaque {
    return game_ptr;
}


/// Register component lifecycle callbacks if the component type defines them.
/// Supports onAdd, onSet, and onRemove callbacks.
///
/// Note: onSet is NOT registered as a flecs hook because flecs fires on_set
/// on initial add too. Instead, onSet is triggered manually only via setComponent()
/// to ensure consistent behavior with zig_ecs backend.
pub fn registerComponentCallbacks(registry: *Registry, comptime T: type) void {
    // Check if any callbacks are defined (excluding onSet which is handled manually)
    const has_on_add = @hasDecl(T, "onAdd");
    const has_on_remove = @hasDecl(T, "onRemove");

    if (!has_on_add and !has_on_remove) {
        return;
    }

    // Always register component with this world - flecs.COMPONENT is idempotent per-world
    // but we must call it for each new world (e.g., after scene change recreates the registry).
    // Do NOT use `flecs.id(T) == 0` as that value may be stale from a previous world.
    flecs.COMPONENT(registry.world, T);

    // Build type hooks struct with defined callbacks
    // Note: onSet is intentionally NOT included here - it's handled manually in setComponent()
    var type_hooks: flecs.type_hooks_t = .{};

    // onAdd - called when component is added to an entity
    if (has_on_add) {
        const AddWrapper = struct {
            fn callback(it: *flecs.iter_t) callconv(.c) void {
                const entities = it.entities();
                var i: usize = 0;
                while (i < it.count()) : (i += 1) {
                    if (game_ptr) |gp| {
                        T.onAdd(.{ .entity_id = entities[i], .game_ptr = gp });
                    } else {
                        std.log.warn("[zflecs_adapter] onAdd callback fired but game_ptr not set for component {s}", .{@typeName(T)});
                    }
                }
            }
        };
        type_hooks.on_add = AddWrapper.callback;
    }

    // onRemove - called when component is removed from an entity
    if (has_on_remove) {
        const RemoveWrapper = struct {
            fn callback(it: *flecs.iter_t) callconv(.c) void {
                const entities = it.entities();
                var i: usize = 0;
                while (i < it.count()) : (i += 1) {
                    if (game_ptr) |gp| {
                        T.onRemove(.{ .entity_id = entities[i], .game_ptr = gp });
                    } else {
                        std.log.warn("[zflecs_adapter] onRemove callback fired but game_ptr not set for component {s}", .{@typeName(T)});
                    }
                }
            }
        };
        type_hooks.on_remove = RemoveWrapper.callback;
    }

    // Set all hooks at once
    const component_id = flecs.id(T);
    flecs.set_hooks_id(registry.world, component_id, &type_hooks);
}

/// Entity handle - wraps flecs entity_t as a full 64-bit ID
/// This preserves the generation counter in the upper 32 bits for proper entity lifecycle tracking
pub const Entity = packed struct {
    id: u64,

    pub const invalid: Entity = .{ .id = 0 };

    pub fn eql(self: Entity, other: Entity) bool {
        return self.id == other.id;
    }

    fn toFlecs(self: Entity) flecs.entity_t {
        return self.id;
    }

    fn fromFlecs(e: flecs.entity_t) Entity {
        return .{ .id = e };
    }
};

/// Registry wrapper that delegates to flecs World
pub const Registry = struct {
    world: *flecs.world_t,
    allocator: std.mem.Allocator,

    /// Initialize a new registry
    pub fn init(allocator: std.mem.Allocator) Registry {
        const world = flecs.init();
        return .{
            .world = world,
            .allocator = allocator,
        };
    }

    /// Clean up the registry
    pub fn deinit(self: *Registry) void {
        _ = flecs.fini(self.world);
    }

    /// Create a new entity
    pub fn create(self: *Registry) Entity {
        const e = flecs.new_id(self.world);
        return Entity.fromFlecs(e);
    }

    /// Destroy an entity
    pub fn destroy(self: *Registry, entity: Entity) void {
        flecs.delete(self.world, entity.toFlecs());
    }

    /// Add a component to an entity
    /// Note: flecs requires components to be registered before use.
    /// This adapter auto-registers components on each call to handle world recreation.
    pub fn add(self: *Registry, entity: Entity, component: anytype) void {
        const T = @TypeOf(component);
        // Always register - COMPONENT is idempotent per-world, and we need to handle
        // world recreation (scene changes). Don't use flecs.id(T) == 0 as it may be stale.
        flecs.COMPONENT(self.world, T);
        _ = flecs.set(self.world, entity.toFlecs(), T, component);
    }

    /// Try to get a component from an entity, returns null if not present
    /// Note: Direct mutation via the returned pointer will NOT trigger onSet callbacks.
    /// Use setComponent() to update a component and trigger onSet.
    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);
        return flecs.get_mut(self.world, entity.toFlecs(), T);
    }

    /// Set/update a component on an entity, triggering onSet callback if defined.
    /// If the entity doesn't have the component, it will be added (triggering onAdd).
    /// If the entity already has the component, it will be replaced (triggering onSet).
    pub fn setComponent(self: *Registry, entity: Entity, component: anytype) void {
        const T = @TypeOf(component);
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);

        const has_component = flecs.get_mut(self.world, entity.toFlecs(), T) != null;

        // Use flecs.set to update the component
        _ = flecs.set(self.world, entity.toFlecs(), T, component);

        // Manually trigger onSet only if component already existed
        // (onAdd is handled by flecs hook, onSet is NOT registered as flecs hook)
        if (has_component) {
            if (@hasDecl(T, "onSet")) {
                if (game_ptr) |gp| {
                    T.onSet(.{ .entity_id = entity.id, .game_ptr = gp });
                } else {
                    std.log.warn("[zflecs_adapter] onSet callback fired but game_ptr not set for component {s}", .{@typeName(T)});
                }
            }
        }
        // If component didn't exist, flecs fires on_add hook only
    }

    /// Remove a component from an entity
    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);
        flecs.remove(self.world, entity.toFlecs(), T);
    }

    /// Create an iterator for entities with a single component
    /// This is where flecs really shines - archetype iteration
    pub fn each(self: *Registry, comptime T: type) flecs.iter_t {
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);
        return flecs.each(self.world, T);
    }

    /// Get the world pointer for advanced flecs operations
    pub fn getWorld(self: *Registry) *flecs.world_t {
        return self.world;
    }

    /// Create a query for the given component types
    /// Zero-sized components are used as filters only
    pub fn query(self: *Registry, comptime components: anytype) Query(components) {
        return Query(components).init(self);
    }
};

/// Query type for zflecs backend
/// Handles both data components and tag filters
pub fn Query(comptime components: anytype) type {
    const separated = query_facade.separateComponents(components);
    const data_types = separated.data;
    const tag_types = separated.tags;

    return struct {
        registry: *Registry,

        const Self = @This();

        pub fn init(registry: *Registry) Self {
            // Register all components before creating query
            inline for (components) |T| {
                if (@sizeOf(T) == 0) {
                    flecs.TAG(registry.world, T);
                } else {
                    flecs.COMPONENT(registry.world, T);
                }
            }
            return .{ .registry = registry };
        }

        /// Iterate with a callback function
        /// Callback receives: (entity: Entity, data_ptr1: *T1, data_ptr2: *T2, ...)
        pub fn each(self: Self, callback: anytype) void {
            // Build the query terms
            comptime {
                if (components.len > 32) @compileError("zflecs query supports a maximum of 32 components");
            }
            var terms: [32]flecs.term_t = @splat(.{});

            // Add data component terms
            inline for (data_types, 0..) |T, i| {
                terms[i] = .{ .id = flecs.id(T) };
            }

            // Add tag terms
            inline for (tag_types, 0..) |T, i| {
                terms[data_types.len + i] = .{ .id = flecs.id(T) };
            }

            const flecs_query = flecs.query_init(self.registry.world, &.{
                .terms = terms,
            }) catch @panic("Failed to create flecs query");
            defer flecs.query_fini(flecs_query);

            var it = flecs.query_iter(self.registry.world, flecs_query);

            while (flecs.query_next(&it)) {
                // Get component arrays for this archetype chunk
                var field_ptrs: [data_types.len][*]u8 = undefined;
                inline for (0..data_types.len) |i| {
                    // Query should only yield tables containing all components, so field should never be null
                    field_ptrs[i] = if (flecs.field(&it, data_types[i], i)) |ptr| @ptrCast(ptr) else unreachable;
                }

                const entities = it.entities();
                const count = it.count();

                // Iterate over entities in this chunk
                for (0..count) |idx| {
                    const entity = Entity.fromFlecs(entities[idx]);
                    callWithFields(entity, &field_ptrs, idx, callback);
                }
            }
        }

        fn callWithFields(entity: Entity, field_ptrs: *const [data_types.len][*]u8, idx: usize, callback: anytype) void {
            var args: std.meta.Tuple(&[_]type{Entity} ++ blk: {
                var types: [data_types.len]type = undefined;
                for (0..data_types.len) |i| {
                    types[i] = *data_types[i];
                }
                break :blk types;
            }) = undefined;

            args[0] = entity;

            inline for (0..data_types.len) |i| {
                const T = data_types[i];
                const base_ptr: [*]T = @ptrCast(@alignCast(field_ptrs[i]));
                args[i + 1] = &base_ptr[idx];
            }

            @call(.auto, callback, args);
        }
    };
}
