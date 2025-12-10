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
    /// NOTE: This stub implementation leaks memory for components not explicitly removed.
    /// This will be resolved when replaced with the actual ZCS adapter.
    pub fn deinit(self: *Registry) void {
        // Stub: Cannot properly free type-erased components without tracking their types.
        // A full implementation would use ZCS's proper cleanup mechanisms.
        self.component_storage.deinit();
    }

    /// Create a new entity
    pub fn create(self: *Registry) Entity {
        const handle = Entity{ .id = self.next_id };
        self.next_id += 1;
        return handle;
    }

    /// Destroy an entity
    /// NOTE: This stub is a no-op and leaks components associated with the entity.
    /// This will be resolved when replaced with the actual ZCS adapter.
    pub fn destroy(_: *Registry, _: Entity) void {
        // Stub: Cannot remove components without tracking which types an entity has.
        // A full implementation would use ZCS's entity destruction with proper cleanup.
    }

    /// Add a component to an entity
    /// If the component already exists, it will be replaced (previous allocation freed).
    pub fn add(self: *Registry, entity: Entity, component: anytype) void {
        const T = @TypeOf(component);
        const key = makeKey(T, entity);

        // Free existing component if present (avoid memory leak on duplicate adds)
        if (self.component_storage.get(key)) |old_ptr| {
            const typed_ptr: *T = @ptrCast(@alignCast(old_ptr));
            self.allocator.destroy(typed_ptr);
        }

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
        // Use comptime type name hash for type identification
        const type_name = @typeName(T);
        comptime var type_hash: u64 = 0;
        inline for (type_name) |c| {
            type_hash = type_hash *% 31 +% c;
        }
        return (type_hash << 32) | @as(u64, entity.id);
    }
};
