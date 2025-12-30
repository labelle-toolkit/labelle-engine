// zig_ecs adapter - wraps prime31/zig-ecs to conform to the ECS interface
//
// This adapter provides a thin wrapper around zig-ecs, exposing only the
// methods used by labelle-engine:
// - init/deinit: Registry lifecycle
// - create/destroy: Entity lifecycle
// - add/tryGet/remove: Component operations
// - view: Query-based iteration

const std = @import("std");
const zig_ecs = @import("zig_ecs");

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

    /// Initialize a new registry
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .inner = zig_ecs.Registry.init(allocator) };
    }

    /// Clean up the registry
    pub fn deinit(self: *Registry) void {
        self.inner.deinit();
    }

    /// Create a new entity
    pub fn create(self: *Registry) Entity {
        return self.inner.create();
    }

    /// Destroy an entity
    pub fn destroy(self: *Registry, entity: Entity) void {
        self.inner.destroy(entity);
    }

    /// Add a component to an entity
    pub fn add(self: *Registry, entity: Entity, component: anytype) void {
        self.inner.add(entity, component);
    }

    /// Try to get a component from an entity, returns null if not present
    /// Note: Direct mutation via the returned pointer will NOT trigger onSet callbacks.
    /// Use setComponent() to update a component and trigger onSet.
    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        return self.inner.tryGet(T, entity);
    }

    /// Set/update a component on an entity, triggering onSet callback if defined.
    /// If the entity doesn't have the component, it will be added (triggering onAdd).
    /// If the entity already has the component, it will be replaced (triggering onSet).
    pub fn setComponent(self: *Registry, entity: Entity, component: anytype) void {
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

    /// Remove a component from an entity
    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        self.inner.remove(T, entity);
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
    pub fn view(self: *Registry, comptime includes: anytype) ViewType(includes) {
        return self.inner.view(includes, .{});
    }

    /// Create a basic view for a single component (faster than MultiView)
    pub fn basicView(self: *Registry, comptime T: type) zig_ecs.BasicView(T) {
        return self.inner.basicView(T);
    }
};
