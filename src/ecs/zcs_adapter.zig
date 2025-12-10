// ZCS adapter - wraps Games-by-Mason/ZCS to conform to the ECS interface
//
// NOTE: ZCS v0.1.1 uses @Tuple which was removed in Zig 0.15.x
// This adapter provides a stub implementation until ZCS is updated.
// Once ZCS releases a Zig 0.15+ compatible version, this can be fully implemented.
//
// ZCS has a different API model than zig_ecs:
// - Uses command buffers for entity/component operations
// - Entity handles include generation for safe reuse
//
// This adapter provides a synchronous wrapper that immediately executes
// command buffer operations to match the direct API expected by labelle-engine.

const std = @import("std");

// ZCS import is disabled until it's compatible with Zig 0.15+
// const zcs = @import("zcs");

/// Entity handle - a 32-bit identifier for compatibility with labelle-engine
pub const Entity = packed struct {
    id: u32,

    pub const invalid: Entity = .{ .id = 0 };

    pub fn eql(self: Entity, other: Entity) bool {
        return self.id == other.id;
    }
};

/// Registry - stub implementation until ZCS is compatible with Zig 0.15+
///
/// This implementation uses a simple approach similar to zig_ecs
/// but without the underlying ZCS library. Once ZCS is updated,
/// this can be replaced with the proper ZCS integration.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    next_id: u32,

    // Simple component storage using type-erased maps
    // In a real implementation, this would use ZCS's archetype storage
    component_storage: std.AutoHashMap(u64, *anyopaque),

    /// Initialize a new registry
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .next_id = 1, // Start at 1, 0 is invalid
            .component_storage = std.AutoHashMap(u64, *anyopaque).init(allocator),
        };
    }

    /// Clean up the registry
    pub fn deinit(self: *Registry) void {
        // In a full implementation, would need to free all stored components
        self.component_storage.deinit();
    }

    /// Create a new entity
    pub fn create(self: *Registry) Entity {
        const handle = Entity{ .id = self.next_id };
        self.next_id += 1;
        return handle;
    }

    /// Destroy an entity
    pub fn destroy(_: *Registry, _: Entity) void {
        // In a full implementation, would remove all components for this entity
        // ZCS stub - no-op until ZCS is compatible with Zig 0.15+
    }

    /// Add a component to an entity
    pub fn add(self: *Registry, entity: Entity, component: anytype) void {
        const T = @TypeOf(component);
        const key = makeKey(T, entity);

        // Allocate storage for the component
        const ptr = self.allocator.create(T) catch @panic("Failed to allocate component");
        ptr.* = component;

        self.component_storage.put(key, @ptrCast(ptr)) catch @panic("Failed to store component");
    }

    /// Try to get a component from an entity, returns null if not present
    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        const key = makeKey(T, entity);
        if (self.component_storage.get(key)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    /// Remove a component from an entity
    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        const key = makeKey(T, entity);
        if (self.component_storage.fetchSwapRemove(key)) |kv| {
            const ptr: *T = @ptrCast(@alignCast(kv.value));
            self.allocator.destroy(ptr);
        }
    }

    /// Generate a unique key for (type, entity) pair
    fn makeKey(comptime T: type, entity: Entity) u64 {
        const type_hash: u64 = @truncate(@intFromPtr(&T));
        return (type_hash << 32) | @as(u64, entity.id);
    }
};
