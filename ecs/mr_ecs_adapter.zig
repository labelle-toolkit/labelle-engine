// mr_ecs adapter - wraps Games-by-Mason/mr_ecs to conform to the ECS interface
//
// IMPORTANT: This adapter requires Zig 0.16.0+ (mr_ecs uses @Tuple builtin)
// Build with: zig build -Decs_backend=mr_ecs
//
// mr_ecs is an archetype-based ECS with:
// - Persistent entity keys (handles remain valid after destruction via generation counters)
// - Archetype-based iteration for cache-efficient access
// - Command buffers for deferred operations (this adapter uses immediate operations)
// - No dynamic allocation after initialization
//
// This adapter provides a Registry-like interface that matches the labelle-engine API.

const std = @import("std");
const mr_ecs = @import("mr_ecs");
const query_facade = @import("query.zig");

// ============================================
// Default capacity configuration
// ============================================

/// Default maximum number of entities
pub const DEFAULT_ENTITY_CAPACITY: u32 = 100000;
/// Default maximum number of archetypes
pub const DEFAULT_ARCH_CAPACITY: u32 = 256;
/// Default number of chunks to allocate
pub const DEFAULT_CHUNK_COUNT: u16 = 1024;
/// Default size of a single chunk in bytes
pub const DEFAULT_CHUNK_SIZE: u32 = 65536;

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
/// Note: mr_ecs doesn't have built-in component lifecycle hooks like flecs.
/// Callbacks are triggered manually in the adapter methods (add, setComponent, remove).
pub fn registerComponentCallbacks(registry: *Registry, comptime T: type) void {
    // mr_ecs doesn't have component registration like flecs.
    // We track registered types so we know to fire callbacks.
    _ = registry;
    _ = T;
    // Callbacks are triggered manually in add/setComponent/remove methods.
}

/// Entity handle - wraps mr_ecs Entity
pub const Entity = packed struct {
    inner: mr_ecs.Entity,

    pub const invalid: Entity = .{ .inner = .{ .key = .{ .index = 0, .generation = .invalid } } };

    pub fn eql(self: Entity, other: Entity) bool {
        return self.inner.eql(other.inner);
    }

    fn toMrEcs(self: Entity) mr_ecs.Entity {
        return self.inner;
    }

    fn fromMrEcs(e: mr_ecs.Entity) Entity {
        return .{ .inner = e };
    }
};

/// The underlying integer type that stores Entity bits (for callback wrappers)
/// This ensures consistent entity ID handling across all backends
const EntityBits = std.meta.Int(.unsigned, @bitSizeOf(Entity));

/// Registry wrapper that delegates to mr_ecs Entities
pub const Registry = struct {
    inner: mr_ecs.Entities,
    allocator: std.mem.Allocator,

    /// Initialize a new registry
    pub fn init(allocator: std.mem.Allocator) Registry {
        const inner = mr_ecs.Entities.init(.{
            .gpa = allocator,
            .cap = .{
                .entities = DEFAULT_ENTITY_CAPACITY,
                .arches = DEFAULT_ARCH_CAPACITY,
                .chunks = DEFAULT_CHUNK_COUNT,
                .chunk = DEFAULT_CHUNK_SIZE,
            },
        }) catch @panic("Failed to initialize mr_ecs Entities");

        return .{
            .inner = inner,
            .allocator = allocator,
        };
    }

    /// Clean up the registry
    pub fn deinit(self: *Registry) void {
        self.inner.deinit(self.allocator);
    }

    /// Create a new entity
    pub fn create(self: *Registry) Entity {
        // Reserve a new entity handle and commit it immediately
        const entity = mr_ecs.Entity.reserveImmediate(&self.inner);
        // Commit the empty entity so it shows up in iteration
        _ = entity.changeArchImmediate(&self.inner, struct {}, .{}) catch
            @panic("Failed to commit entity");
        return Entity.fromMrEcs(entity);
    }

    /// Check if an entity is valid (exists in the registry)
    pub fn isValid(self: *Registry, entity: Entity) bool {
        return entity.toMrEcs().exists(&self.inner);
    }

    /// Destroy an entity
    pub fn destroy(self: *Registry, entity: Entity) void {
        _ = entity.toMrEcs().destroyImmediate(&self.inner);
    }

    /// Add a component to an entity
    /// Note: Triggers onAdd callback if the component type defines it.
    pub fn add(self: *Registry, entity: Entity, component: anytype) void {
        const T = @TypeOf(component);
        const mr_entity = entity.toMrEcs();

        // Use changeArchImmediate to add the component
        const AddStruct = struct { comp: T };
        _ = mr_entity.changeArchImmediate(&self.inner, AddStruct, .{
            .add = .{ .comp = component },
        }) catch @panic("Failed to add component");

        // Trigger onAdd callback if defined
        if (@hasDecl(T, "onAdd")) {
            if (game_ptr) |gp| {
                const entity_u64: u64 = @as(EntityBits, @bitCast(entity));
                T.onAdd(.{ .entity_id = entity_u64, .game_ptr = gp });
            } else {
                std.log.warn("[mr_ecs_adapter] onAdd callback fired but game_ptr not set for component {s}", .{@typeName(T)});
            }
        }
    }

    /// Try to get a component from an entity, returns null if not present
    /// Note: Direct mutation via the returned pointer will NOT trigger onSet callbacks.
    /// Use setComponent() to update a component and trigger onSet.
    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        return entity.toMrEcs().get(&self.inner, T);
    }

    /// Set/update a component on an entity, triggering onSet callback if defined.
    /// If the entity doesn't have the component, it will be added (triggering onAdd).
    /// If the entity already has the component, it will be replaced (triggering onSet).
    pub fn setComponent(self: *Registry, entity: Entity, component: anytype) void {
        const T = @TypeOf(component);
        const mr_entity = entity.toMrEcs();

        // Check if component exists
        const has_component = mr_entity.get(&self.inner, T) != null;

        if (has_component) {
            // Update existing component
            const ptr = mr_entity.get(&self.inner, T).?;
            ptr.* = component;

            // Trigger onSet callback if defined
            if (@hasDecl(T, "onSet")) {
                if (game_ptr) |gp| {
                    const entity_u64: u64 = @as(EntityBits, @bitCast(entity));
                    T.onSet(.{ .entity_id = entity_u64, .game_ptr = gp });
                } else {
                    std.log.warn("[mr_ecs_adapter] onSet callback fired but game_ptr not set for component {s}", .{@typeName(T)});
                }
            }
        } else {
            // Add the component (onAdd will be triggered)
            self.add(entity, component);
        }
    }

    /// Remove a component from an entity
    /// Note: Triggers onRemove callback if the component type defines it.
    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        const mr_entity = entity.toMrEcs();

        // Check if component exists before removing
        if (mr_entity.get(&self.inner, T) == null) {
            return; // Nothing to remove
        }

        // Trigger onRemove callback if defined (before removal)
        if (@hasDecl(T, "onRemove")) {
            if (game_ptr) |gp| {
                const entity_u64: u64 = @as(EntityBits, @bitCast(entity));
                T.onRemove(.{ .entity_id = entity_u64, .game_ptr = gp });
            } else {
                std.log.warn("[mr_ecs_adapter] onRemove callback fired but game_ptr not set for component {s}", .{@typeName(T)});
            }
        }

        // Remove the component using changeArchImmediate
        const flag = mr_ecs.typeId(T).comp_flag orelse return;
        var remove_set = mr_ecs.CompFlag.Set{};
        remove_set.insert(flag);

        _ = mr_entity.changeArchImmediate(&self.inner, struct {}, .{
            .remove = remove_set,
        }) catch @panic("Failed to remove component");
    }

    /// Create a query for the given component types
    /// Zero-sized components are used as filters only
    pub fn query(self: *Registry, comptime components: anytype) Query(components) {
        return Query(components).init(self);
    }
};

/// Query type for mr_ecs backend
/// Provides the unified query API with both each() callback and next() iterator patterns
pub fn Query(comptime components: anytype) type {
    const separated = query_facade.separateComponents(components);
    const data_types = separated.data;
    // Note: mr_ecs doesn't support tag filtering directly, tags are ignored

    // Build the View type for mr_ecs iterator
    // mr_ecs expects a struct with pointer fields
    const ViewType = blk: {
        var fields: [data_types.len]std.builtin.Type.StructField = undefined;
        for (data_types, 0..) |T, i| {
            fields[i] = .{
                .name = std.fmt.comptimePrint("f{d}", .{i}),
                .type = *T,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = 0,
            };
        }
        break :blk @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    };

    return struct {
        registry: *Registry,
        iterator: if (data_types.len == 0) void else mr_ecs.Entities.Iterator(ViewType),

        const Self = @This();

        /// Query item returned by next()
        pub const Item = struct {
            entity: Entity,
            registry_inner: *mr_ecs.Entities,

            /// Get a component pointer by type
            pub fn get(self: Item, comptime T: type) *T {
                return self.registry_inner.getEntity(self.entity.toMrEcs()).get(&self.registry_inner.*, T).?;
            }
        };

        pub fn init(registry: *Registry) Self {
            if (data_types.len == 0) {
                return .{ .registry = registry, .iterator = {} };
            }
            return .{
                .registry = registry,
                .iterator = registry.inner.iterator(ViewType),
            };
        }

        /// Get next item in iteration, or null if done
        pub fn next(self: *Self) ?Item {
            if (data_types.len == 0) return null;

            if (self.iterator.next(&self.registry.inner)) |view_result| {
                // Get entity from the first component pointer
                const first_comp = @field(view_result, "f0");
                const entity = self.registry.inner.getEntity(first_comp);
                return Item{
                    .entity = Entity.fromMrEcs(entity),
                    .registry_inner = &self.registry.inner,
                };
            }
            return null;
        }

        /// Iterate with a callback function
        /// Callback receives: (entity: Entity, data_ptr1: *T1, data_ptr2: *T2, ...)
        pub fn each(self: Self, callback: anytype) void {
            if (data_types.len == 0) {
                return;
            }

            var iter = self.registry.inner.iterator(ViewType);
            while (iter.next(&self.registry.inner)) |view_result| {
                // Get entity from the first component pointer
                const first_comp = @field(view_result, "f0");
                const entity = Entity.fromMrEcs(self.registry.inner.getEntity(first_comp));

                // Call the callback with entity and all component pointers
                switch (data_types.len) {
                    1 => callback(entity, @field(view_result, "f0")),
                    2 => callback(entity, @field(view_result, "f0"), @field(view_result, "f1")),
                    3 => callback(entity, @field(view_result, "f0"), @field(view_result, "f1"), @field(view_result, "f2")),
                    4 => callback(entity, @field(view_result, "f0"), @field(view_result, "f1"), @field(view_result, "f2"), @field(view_result, "f3")),
                    else => @compileError("mr_ecs query supports a maximum of 4 data components"),
                }
            }
        }
    };
}
