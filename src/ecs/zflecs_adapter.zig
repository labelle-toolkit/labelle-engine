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
    /// This adapter auto-registers components on first use.
    pub fn add(self: *Registry, entity: Entity, component: anytype) void {
        const T = @TypeOf(component);
        // flecs.id(T) returns 0 if not yet registered
        // COMPONENT macro checks internally if already registered, so safe to call
        if (flecs.id(T) == 0) {
            flecs.COMPONENT(self.world, T);
        }
        _ = flecs.set(self.world, entity.toFlecs(), T, component);
    }

    /// Try to get a component from an entity, returns null if not present
    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        // Component must be registered to get it
        if (flecs.id(T) == 0) {
            flecs.COMPONENT(self.world, T);
        }
        return flecs.get_mut(self.world, entity.toFlecs(), T);
    }

    /// Remove a component from an entity
    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        if (flecs.id(T) == 0) {
            flecs.COMPONENT(self.world, T);
        }
        flecs.remove(self.world, entity.toFlecs(), T);
    }

    /// Create an iterator for entities with a single component
    /// This is where flecs really shines - archetype iteration
    pub fn each(self: *Registry, comptime T: type) flecs.iter_t {
        if (flecs.id(T) == 0) {
            flecs.COMPONENT(self.world, T);
        }
        return flecs.each(self.world, T);
    }

    /// Get the world pointer for advanced flecs operations
    pub fn getWorld(self: *Registry) *flecs.world_t {
        return self.world;
    }
};
