// zig_ecs adapter - wraps prime31/zig-ecs to conform to the core.Ecs(Backend) trait
//
// This adapter provides a thin wrapper around zig-ecs, exposing only the
// methods used by labelle-engine:
// - init/deinit: Registry lifecycle
// - createEntity/destroyEntity/entityExists: Entity lifecycle
// - addComponent/getComponent/hasComponent/removeComponent: Component operations
// - setComponent: Component update with onSet callback
// - view/query: Query-based iteration

const std = @import("std");
const zig_ecs = @import("zig_ecs");
const query_facade = @import("query.zig");

/// Entity type from zig-ecs (does not have 'invalid' or 'eql' - use interface helpers)
pub const Entity = zig_ecs.Entity;

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


/// View for iterating entities with specific components
pub fn View(comptime Components: type) type {
    return struct {
        const Self = @This();
        const ComponentsTuple = std.meta.Tuple(&typeArrayFromStruct(Components));

        inner: zig_ecs.MultiView(typeArrayFromStruct(Components), .{}),

        pub fn init(registry: *Registry) Self {
            return .{ .inner = registry.inner.view(typeArrayFromStruct(Components), .{}) };
        }

        /// Iterate over all entities matching the view
        pub fn each(self: *Self, callback: *const fn (Entity, *Components) void) void {
            var iter = self.inner.iterator();
            while (iter.next()) |entity| {
                var comps: Components = undefined;
                inline for (std.meta.fields(Components), 0..) |field, i| {
                    const FieldType = @typeInfo(field.type).pointer.child;
                    @field(comps, field.name) = self.inner.getComponents(entity)[i];
                    _ = FieldType;
                }
                callback(entity, &comps);
            }
        }

        /// Get raw component slices for maximum performance iteration
        pub fn raw(self: *Self, comptime T: type) []T {
            return self.inner.raw(T);
        }

        /// Get the number of entities in the view
        pub fn len(self: *Self) usize {
            return self.inner.inner.len();
        }

        /// Iterator for manual iteration
        pub fn iterator(self: *Self) @TypeOf(self.inner.iterator()) {
            return self.inner.iterator();
        }

        /// Get components for an entity
        pub fn get(self: *Self, entity: Entity) ComponentsTuple {
            return self.inner.getComponents(entity);
        }
    };
}

/// Helper to extract type array from a struct of pointers
fn typeArrayFromStruct(comptime T: type) [std.meta.fields(T).len]type {
    const fields = std.meta.fields(T);
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, i| {
        types[i] = @typeInfo(field.type).pointer.child;
    }
    return types;
}

/// The underlying integer type that stores Entity bits (for callback wrappers)
const EntityBits = std.meta.Int(.unsigned, @bitSizeOf(Entity));

/// Register component lifecycle callbacks if the component type defines them.
/// Supports onAdd, onSet, and onRemove callbacks.
///
/// Note: onSet is NOT registered as a zig-ecs signal because we want it to only
/// fire via setComponent() for consistent behavior with zflecs backend.
/// onSet is triggered manually in setComponent().
pub fn registerComponentCallbacks(registry: *Registry, comptime T: type) void {
    // onAdd - called when component is added to an entity
    if (@hasDecl(T, "onAdd")) {
        const AddWrapper = struct {
            fn callback(_: *zig_ecs.Registry, entity: Entity) void {
                const entity_u64: u64 = @as(EntityBits, @bitCast(entity));
                if (game_ptr) |gp| {
                    T.onAdd(.{ .entity_id = entity_u64, .game_ptr = gp });
                } else {
                    std.log.warn("[zig_ecs_adapter] onAdd callback fired but game_ptr not set for component {s}", .{@typeName(T)});
                }
            }
        };
        registry.inner.onConstruct(T).connect(AddWrapper.callback);
    }

    // onRemove - called when component is removed from an entity
    if (@hasDecl(T, "onRemove")) {
        const RemoveWrapper = struct {
            fn callback(_: *zig_ecs.Registry, entity: Entity) void {
                const entity_u64: u64 = @as(EntityBits, @bitCast(entity));
                if (game_ptr) |gp| {
                    T.onRemove(.{ .entity_id = entity_u64, .game_ptr = gp });
                } else {
                    std.log.warn("[zig_ecs_adapter] onRemove callback fired but game_ptr not set for component {s}", .{@typeName(T)});
                }
            }
        };
        registry.inner.onDestruct(T).connect(RemoveWrapper.callback);
    }
}

/// Registry wrapper that delegates to zig-ecs Registry
pub const Registry = struct {
    inner: zig_ecs.Registry,

    const Self = @This();

    /// Entity type for core.Ecs(Backend) trait conformance.
    pub const Entity = zig_ecs.Entity;

    /// Initialize a new registry
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .inner = zig_ecs.Registry.init(allocator) };
    }

    /// Clean up the registry
    pub fn deinit(self: *Registry) void {
        self.inner.deinit();
    }

    /// Create a new entity
    pub fn createEntity(self: *Self) Self.Entity {
        return self.inner.create();
    }

    /// Destroy an entity
    pub fn destroyEntity(self: *Self, entity: Self.Entity) void {
        self.inner.destroy(entity);
    }

    /// Add a component to an entity
    pub fn addComponent(self: *Self, entity: Self.Entity, component: anytype) void {
        self.inner.add(entity, component);
    }

    /// Alias for addComponent - for compatibility with plugins
    pub fn add(self: *Self, entity: Self.Entity, component: anytype) void {
        self.addComponent(entity, component);
    }

    /// Get a component from an entity, returns null if not present
    /// Note: Direct mutation via the returned pointer will NOT trigger onSet callbacks.
    /// Use setComponent() to update a component and trigger onSet.
    pub fn getComponent(self: *Self, entity: Self.Entity, comptime T: type) ?*T {
        return self.inner.tryGet(T, entity);
    }

    /// Check if an entity has a component
    pub fn hasComponent(self: *Self, entity: Self.Entity, comptime T: type) bool {
        return self.inner.tryGet(T, entity) != null;
    }

    /// Set/update a component on an entity, triggering onSet callback if defined.
    /// If the entity doesn't have the component, it will be added (triggering onAdd).
    /// If the entity already has the component, it will be replaced (triggering onSet).
    pub fn setComponent(self: *Self, entity: Self.Entity, component: anytype) void {
        const T = @TypeOf(component);
        if (self.inner.tryGet(T, entity)) |ptr| {
            // Component exists - update it and manually trigger onSet
            ptr.* = component;
            // Trigger onSet callback if defined
            if (@hasDecl(T, "onSet")) {
                const entity_u64: u64 = @as(EntityBits, @bitCast(entity));
                if (game_ptr) |gp| {
                    T.onSet(.{ .entity_id = entity_u64, .game_ptr = gp });
                } else {
                    std.log.warn("[zig_ecs_adapter] onSet callback fired but game_ptr not set for component {s}", .{@typeName(T)});
                }
            }
        } else {
            // Component doesn't exist - add it (onAdd will be triggered by the signal)
            self.inner.add(entity, component);
        }
    }

    /// Alias for setComponent - for compatibility with physics systems
    pub fn set(self: *Self, entity: Self.Entity, component: anytype) void {
        self.setComponent(entity, component);
    }

    /// Remove a component from an entity
    pub fn removeComponent(self: *Self, entity: Self.Entity, comptime T: type) void {
        self.inner.remove(T, entity);
    }

    /// Alias for removeComponent - for compatibility with plugins
    pub fn remove(self: *Self, comptime T: type, entity: Self.Entity) void {
        self.removeComponent(entity, T);
    }

    /// Alias for getComponent - for compatibility with plugins
    pub fn tryGet(self: *Self, comptime T: type, entity: Self.Entity) ?*T {
        return self.getComponent(entity, T);
    }

    /// Get a mutable pointer to a component (alias for getComponent)
    pub fn getComponentPtr(self: *Self, entity: Self.Entity, comptime T: type) ?*T {
        return self.getComponent(entity, T);
    }

    /// Check if an entity exists in the registry
    pub fn entityExists(self: *Self, entity: Self.Entity) bool {
        return self.inner.valid(entity);
    }

    /// Mark a component as dirty (for render pipeline sync)
    /// Currently a no-op - the render pipeline handles its own dirty tracking
    pub fn markDirty(self: *Self, entity: Self.Entity, comptime T: type) void {
        _ = self;
        _ = entity;
        _ = T;
        // No-op: The render pipeline tracks dirty state independently.
        // Physics systems call this but the actual dirty tracking happens
        // via position component mutation detection.
    }

    /// Determine the view type based on the number of components
    /// Single component -> BasicView (optimized), multiple -> MultiView
    fn ViewType(comptime includes: anytype) type {
        comptime {
            const T = @TypeOf(includes);
            const ti = @typeInfo(T);
            if (ti != .@"struct" or !ti.@"struct".is_tuple) {
                @compileError("view() expects a tuple of types, e.g. '.{MyComponent}'");
            }
            if (includes.len == 0) {
                @compileError("view() requires at least one component type; empty tuples are not supported");
            }
        }
        if (includes.len == 1) return zig_ecs.BasicView(includes[0]);
        return zig_ecs.MultiView(includes, .{});
    }

    /// Create a view for iterating entities with specific components
    /// Usage: var view = registry.view(.{ Position, Velocity });
    /// Note: Single-component views return BasicView for better performance
    pub fn view(self: *Self, comptime includes: anytype) ViewType(includes) {
        return self.inner.view(includes, .{});
    }

    /// Create a basic view for a single component (faster than MultiView)
    pub fn basicView(self: *Self, comptime T: type) zig_ecs.BasicView(T) {
        return self.inner.basicView(T);
    }

    /// Create a query for the given component types
    /// Zero-sized components are used as filters only
    /// WARNING: zig_ecs cannot filter by tags - they are added but not checked
    pub fn query(self: *Self, comptime components: anytype) Query(components) {
        return Query(components).init(self);
    }
};

/// Query type for zig_ecs backend
/// Provides the unified query API with both each() callback and next() iterator patterns
pub fn Query(comptime components: anytype) type {
    const separated = query_facade.separateComponents(components);
    const data_types = separated.data;

    // Determine the inner view type based on component count
    const InnerViewType = switch (data_types.len) {
        0 => void,
        1 => zig_ecs.BasicView(data_types[0]),
        2 => zig_ecs.MultiView(.{ data_types[0], data_types[1] }, .{}),
        3 => zig_ecs.MultiView(.{ data_types[0], data_types[1], data_types[2] }, .{}),
        4 => zig_ecs.MultiView(.{ data_types[0], data_types[1], data_types[2], data_types[3] }, .{}),
        else => @compileError("zig_ecs query supports a maximum of 4 data components"),
    };

    // Iterator type - get from the view's entityIterator return type
    // BasicView (1 component) returns ReverseSliceIterator, MultiView has .Iterator
    const InnerIterType = if (data_types.len == 0)
        void
    else if (data_types.len == 1)
        @import("zig_ecs").utils.ReverseSliceIterator(Entity)
    else
        InnerViewType.Iterator;

    return struct {
        registry: *Registry,
        view: InnerViewType,
        iter: ?InnerIterType,

        const Self = @This();

        /// Query item returned by next()
        pub const Item = struct {
            entity: Entity,
            registry_inner: *zig_ecs.Registry,

            /// Get a component pointer by type
            pub fn get(self: Item, comptime T: type) *T {
                return self.registry_inner.tryGet(T, self.entity).?;
            }
        };

        pub fn init(registry: *Registry) Self {
            if (data_types.len == 0) {
                return .{ .registry = registry, .view = {}, .iter = null };
            }
            const view = switch (data_types.len) {
                1 => registry.inner.view(.{data_types[0]}, .{}),
                2 => registry.inner.view(.{ data_types[0], data_types[1] }, .{}),
                3 => registry.inner.view(.{ data_types[0], data_types[1], data_types[2] }, .{}),
                4 => registry.inner.view(.{ data_types[0], data_types[1], data_types[2], data_types[3] }, .{}),
                else => unreachable,
            };
            // Don't create iterator here - the view will be moved when struct is returned
            // Iterator is lazily created on first next() call
            return .{
                .registry = registry,
                .view = view,
                .iter = null,
            };
        }

        /// Get next item in iteration, or null if done
        pub fn next(self: *Self) ?Item {
            if (data_types.len == 0) return null;

            // Lazily initialize iterator from the stored view
            if (self.iter == null) {
                self.iter = self.view.entityIterator();
            }

            if (self.iter.?.next()) |entity| {
                return Item{
                    .entity = entity,
                    .registry_inner = &self.registry.inner,
                };
            }
            return null;
        }

        /// Iterate with a callback function
        /// Callback receives: (entity: Entity, data_ptr1: *T1, data_ptr2: *T2, ...)
        /// Note: zig_ecs view() requires tuple literals, so we use a switch for 1-4 components.
        pub fn each(self: Self, callback: anytype) void {
            if (data_types.len == 0) {
                return;
            }

            // zig_ecs view() requires tuple literals (.{T1, T2, ...}), not runtime tuples.
            // Using a switch to generate the correct tuple for each component count.
            switch (data_types.len) {
                1 => {
                    var view_iter = self.registry.inner.view(.{data_types[0]}, .{});
                    var iter = view_iter.entityIterator();
                    while (iter.next()) |entity| {
                        const c0 = self.registry.inner.tryGet(data_types[0], entity).?;
                        callback(entity, c0);
                    }
                },
                2 => {
                    var view_iter = self.registry.inner.view(.{ data_types[0], data_types[1] }, .{});
                    var iter = view_iter.entityIterator();
                    while (iter.next()) |entity| {
                        const c0 = self.registry.inner.tryGet(data_types[0], entity).?;
                        const c1 = self.registry.inner.tryGet(data_types[1], entity).?;
                        callback(entity, c0, c1);
                    }
                },
                3 => {
                    var view_iter = self.registry.inner.view(.{ data_types[0], data_types[1], data_types[2] }, .{});
                    var iter = view_iter.entityIterator();
                    while (iter.next()) |entity| {
                        const c0 = self.registry.inner.tryGet(data_types[0], entity).?;
                        const c1 = self.registry.inner.tryGet(data_types[1], entity).?;
                        const c2 = self.registry.inner.tryGet(data_types[2], entity).?;
                        callback(entity, c0, c1, c2);
                    }
                },
                4 => {
                    var view_iter = self.registry.inner.view(.{ data_types[0], data_types[1], data_types[2], data_types[3] }, .{});
                    var iter = view_iter.entityIterator();
                    while (iter.next()) |entity| {
                        const c0 = self.registry.inner.tryGet(data_types[0], entity).?;
                        const c1 = self.registry.inner.tryGet(data_types[1], entity).?;
                        const c2 = self.registry.inner.tryGet(data_types[2], entity).?;
                        const c3 = self.registry.inner.tryGet(data_types[3], entity).?;
                        callback(entity, c0, c1, c2, c3);
                    }
                },
                else => @compileError("zig_ecs query supports a maximum of 4 data components"),
            }
        }
    };
}
