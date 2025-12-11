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
    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        return self.inner.tryGet(T, entity);
    }

    /// Remove a component from an entity
    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        self.inner.remove(T, entity);
    }

    /// Create a view for iterating entities with specific components
    /// Usage: var view = registry.view(.{ Position, Velocity });
    pub fn view(self: *Registry, comptime includes: anytype) zig_ecs.MultiView(includes, .{}) {
        return self.inner.view(includes, .{});
    }

    /// Create a basic view for a single component (faster than MultiView)
    pub fn basicView(self: *Registry, comptime T: type) zig_ecs.BasicView(T) {
        return self.inner.basicView(T);
    }
};
