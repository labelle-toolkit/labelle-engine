// zig_ecs adapter - wraps prime31/zig-ecs to conform to the ECS interface
//
// This adapter provides a thin wrapper around zig-ecs, exposing only the
// methods used by labelle-engine:
// - init/deinit: Registry lifecycle
// - create/destroy: Entity lifecycle
// - add/tryGet/remove: Component operations

const std = @import("std");
const zig_ecs = @import("zig_ecs");

/// Entity type from zig-ecs
pub const Entity = zig_ecs.Entity;

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
};
