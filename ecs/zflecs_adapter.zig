// zflecs adapter - wraps zig-gamedev/zflecs (flecs bindings) to conform to the core.Ecs(Backend) trait
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
const AdapterEntity = packed struct {
    id: u64,

    pub const invalid: AdapterEntity = .{ .id = 0 };

    pub fn eql(self: AdapterEntity, other: AdapterEntity) bool {
        return self.id == other.id;
    }

    fn toFlecs(self: AdapterEntity) flecs.entity_t {
        return self.id;
    }

    fn fromFlecs(e: flecs.entity_t) AdapterEntity {
        return .{ .id = e };
    }
};

/// Public Entity type alias
pub const Entity = AdapterEntity;

/// Registry wrapper that delegates to flecs World
pub const Registry = struct {
    world: *flecs.world_t,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Entity type for core.Ecs(Backend) trait conformance.
    pub const Entity = AdapterEntity;

    /// Initialize a new registry
    pub fn init(allocator: std.mem.Allocator) Registry {
        const world = flecs.init();
        return .{
            .world = world,
            .allocator = allocator,
        };
    }

    /// Clean up the registry
    pub fn deinit(self: *Self) void {
        _ = flecs.fini(self.world);
    }

    /// Create a new entity
    pub fn createEntity(self: *Self) Self.Entity {
        const e = flecs.new_id(self.world);
        return Self.Entity.fromFlecs(e);
    }

    /// Check if an entity exists in the registry
    pub fn entityExists(self: *Self, entity: Self.Entity) bool {
        return flecs.is_alive(self.world, entity.toFlecs());
    }

    /// Destroy an entity
    pub fn destroyEntity(self: *Self, entity: Self.Entity) void {
        flecs.delete(self.world, entity.toFlecs());
    }

    /// Add a component to an entity
    /// Note: flecs requires components to be registered before use.
    /// This adapter auto-registers components on each call to handle world recreation.
    pub fn addComponent(self: *Self, entity: Self.Entity, component: anytype) void {
        const T = @TypeOf(component);
        // Always register - COMPONENT is idempotent per-world, and we need to handle
        // world recreation (scene changes). Don't use flecs.id(T) == 0 as it may be stale.
        flecs.COMPONENT(self.world, T);
        _ = flecs.set(self.world, entity.toFlecs(), T, component);
    }

    /// Get a component from an entity, returns null if not present
    /// Note: Direct mutation via the returned pointer will NOT trigger onSet callbacks.
    /// Use setComponent() to update a component and trigger onSet.
    pub fn getComponent(self: *Self, entity: Self.Entity, comptime T: type) ?*T {
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);
        return flecs.get_mut(self.world, entity.toFlecs(), T);
    }

    /// Check if an entity has a component
    pub fn hasComponent(self: *Self, entity: Self.Entity, comptime T: type) bool {
        flecs.COMPONENT(self.world, T);
        return flecs.get_mut(self.world, entity.toFlecs(), T) != null;
    }

    /// Set/update a component on an entity, triggering onSet callback if defined.
    /// If the entity doesn't have the component, it will be added (triggering onAdd).
    /// If the entity already has the component, it will be replaced (triggering onSet).
    pub fn setComponent(self: *Self, entity: Self.Entity, component: anytype) void {
        const T = @TypeOf(component);
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);

        const has_comp = flecs.get_mut(self.world, entity.toFlecs(), T) != null;

        // Use flecs.set to update the component
        _ = flecs.set(self.world, entity.toFlecs(), T, component);

        // Manually trigger onSet only if component already existed
        // (onAdd is handled by flecs hook, onSet is NOT registered as flecs hook)
        if (has_comp) {
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
    pub fn removeComponent(self: *Self, entity: Self.Entity, comptime T: type) void {
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);
        flecs.remove(self.world, entity.toFlecs(), T);
    }

    /// Create an iterator for entities with a single component
    /// This is where flecs really shines - archetype iteration
    pub fn each(self: *Self, comptime T: type) flecs.iter_t {
        // Always register - handles world recreation after scene changes
        flecs.COMPONENT(self.world, T);
        return flecs.each(self.world, T);
    }

    /// Get the world pointer for advanced flecs operations
    pub fn getWorld(self: *Self) *flecs.world_t {
        return self.world;
    }

    /// Determine the view type based on includes and excludes
    fn ViewType(comptime includes: anytype, comptime excludes: anytype) type {
        comptime {
            const IncT = @TypeOf(includes);
            const inc_ti = @typeInfo(IncT);
            if (inc_ti != .@"struct" or !inc_ti.@"struct".is_tuple) {
                @compileError("view()/viewExcluding() expects a tuple of types for includes, e.g. '.{MyComponent}'");
            }
            if (includes.len == 0) {
                @compileError("view()/viewExcluding() requires at least one include component type; empty tuples are not supported");
            }
            const ExcT = @TypeOf(excludes);
            const exc_ti = @typeInfo(ExcT);
            if (exc_ti != .@"struct" or !exc_ti.@"struct".is_tuple) {
                @compileError("viewExcluding() expects a tuple of types for excludes, e.g. '.{Locked}'");
            }
            if (includes.len + excludes.len > 32) {
                @compileError("view()/viewExcluding() supports a maximum of 32 total terms (includes + excludes)");
            }
        }
        return FlecsView(includes, excludes);
    }

    /// Create a view for iterating entities with specific components
    /// Usage: var view = registry.view(.{ Position, Velocity });
    pub fn view(self: *Self, comptime includes: anytype) ViewType(includes, .{}) {
        return ViewType(includes, .{}).init(self);
    }

    /// Create a view with exclude filters
    /// Usage: var view = registry.viewExcluding(.{ Worker, Position }, .{ Locked });
    /// Entities with any excluded component are skipped during iteration.
    pub fn viewExcluding(self: *Self, comptime includes: anytype, comptime excludes: anytype) ViewType(includes, excludes) {
        return ViewType(includes, excludes).init(self);
    }

    /// Create a query for the given component types
    /// Zero-sized components are used as filters only
    pub fn query(self: *Self, comptime components: anytype) Query(components) {
        return Query(components).init(self);
    }
};

/// View type for zflecs backend
/// Wraps a flecs query to provide the same API as zig_ecs views:
/// entityIterator(), get(T, entity), get(entity) for single-component views
fn FlecsView(comptime _includes: anytype, comptime _excludes: anytype) type {
    return struct {
        registry: *Registry,

        const Self = @This();

        pub fn init(registry: *Registry) Self {
            // Ensure all component types are registered with this world
            inline for (_includes ++ _excludes) |T| {
                if (@sizeOf(T) == 0) {
                    flecs.TAG(registry.world, T);
                } else {
                    flecs.COMPONENT(registry.world, T);
                }
            }
            return .{ .registry = registry };
        }

        /// Get a component from an entity
        /// Single-component view (1 include, 0 excludes): get(entity) -> *T
        /// Multi-component view (or any excludes): get(T, entity) -> *T
        /// Matches zig_ecs BasicView/MultiView API respectively
        pub const get = if (_includes.len == 1 and _excludes.len == 0)
            getSingle
        else
            getMulti;

        fn getSingle(self: Self, entity: Entity) *_includes[0] {
            return flecs.get_mut(self.registry.world, entity.toFlecs(), _includes[0]).?;
        }

        fn getMulti(self: Self, comptime T: type, entity: Entity) *T {
            return flecs.get_mut(self.registry.world, entity.toFlecs(), T).?;
        }

        /// Entity iterator that streams entities from a flecs query chunk by chunk.
        /// Call `deinit()` if you break out of the loop early to free the query.
        /// If you exhaust the iterator (next() returns null), cleanup is automatic.
        pub fn entityIterator(self: *Self) EntityIterator {
            return EntityIterator.init(self);
        }

        pub const EntityIterator = struct {
            flecs_query: *flecs.query_t,
            iter: flecs.iter_t,
            /// Current chunk's entity slice
            entities: []const flecs.entity_t,
            /// Current index within the chunk
            index: usize,
            done: bool,

            fn init(v: *Self) EntityIterator {
                var terms: [32]flecs.term_t = @splat(.{});

                inline for (_includes, 0..) |T, i| {
                    terms[i] = .{ .id = flecs.id(T) };
                }

                inline for (_excludes, 0..) |T, i| {
                    terms[_includes.len + i] = .{
                        .id = flecs.id(T),
                        .oper = .Not,
                    };
                }

                const q = flecs.query_init(v.registry.world, &.{
                    .terms = terms,
                }) catch @panic("Failed to create flecs query for view");

                var it = flecs.query_iter(v.registry.world, q);

                // Pre-fetch the first chunk
                var entities: []const flecs.entity_t = &.{};
                var done = false;
                if (flecs.query_next(&it)) {
                    entities = it.entities()[0..it.count()];
                } else {
                    flecs.query_fini(q);
                    done = true;
                }

                return .{
                    .flecs_query = q,
                    .iter = it,
                    .entities = entities,
                    .index = 0,
                    .done = done,
                };
            }

            /// Free the underlying flecs query. Safe to call multiple times.
            /// Called automatically when next() returns null.
            /// Must be called manually if breaking out of the loop early.
            pub fn deinit(self: *EntityIterator) void {
                if (!self.done) {
                    // Drain remaining chunks so flecs iterator is finalized
                    while (flecs.query_next(&self.iter)) {}
                    flecs.query_fini(self.flecs_query);
                    self.done = true;
                }
            }

            pub fn next(self: *EntityIterator) ?Entity {
                while (true) {
                    if (self.index < self.entities.len) {
                        const entity = Entity.fromFlecs(self.entities[self.index]);
                        self.index += 1;
                        return entity;
                    }

                    // Try next chunk
                    if (flecs.query_next(&self.iter)) {
                        self.entities = self.iter.entities()[0..self.iter.count()];
                        self.index = 0;
                    } else {
                        // Iteration complete, clean up
                        flecs.query_fini(self.flecs_query);
                        self.done = true;
                        return null;
                    }
                }
            }
        };
    };
}

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
