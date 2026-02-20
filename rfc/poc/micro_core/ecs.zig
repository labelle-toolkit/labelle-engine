const std = @import("std");

/// Comptime ECS trait — defines the operations any ECS backend must support.
/// Plugins parameterize on this; engine provides the concrete type.
/// Everything resolves at comptime, zero runtime overhead.
pub fn Ecs(comptime Backend: type) type {
    comptime {
        if (!@hasDecl(Backend, "Entity"))
            @compileError("ECS backend must define Entity type, found: " ++ @typeName(Backend));
        // Validate required operations exist
        const required = .{ "createEntity", "destroyEntity", "entityExists" };
        for (required) |name| {
            if (!@hasDecl(Backend, name))
                @compileError("ECS backend must implement " ++ name);
        }
    }

    return struct {
        pub const Entity = Backend.Entity;
        backend: *Backend,

        const Self = @This();

        // Entity lifecycle
        pub fn createEntity(self: Self) Entity {
            return self.backend.createEntity();
        }

        pub fn destroyEntity(self: Self, entity: Entity) void {
            self.backend.destroyEntity(entity);
        }

        pub fn entityExists(self: Self, entity: Entity) bool {
            return self.backend.entityExists(entity);
        }

        // Component operations — type-safe via comptime
        pub fn add(self: Self, entity: Entity, component: anytype) void {
            self.backend.addComponent(entity, component);
        }

        pub fn get(self: Self, entity: Entity, comptime T: type) ?*T {
            return self.backend.getComponent(entity, T);
        }

        pub fn has(self: Self, entity: Entity, comptime T: type) bool {
            return self.backend.hasComponent(entity, T);
        }

        pub fn remove(self: Self, entity: Entity, comptime T: type) void {
            self.backend.removeComponent(entity, T);
        }
    };
}

/// Mock ECS backend for testing — satisfies the Ecs trait with in-memory storage.
/// Uses type-erased storage internally but presents a type-safe API.
pub fn MockEcsBackend(comptime EntityType: type) type {
    return struct {
        pub const Entity = EntityType;

        const CleanupFn = *const fn (*Self) void;
        const RemoveEntityFn = *const fn (*Self, EntityType) void;

        next_id: EntityType = 1,
        alive: std.AutoHashMap(EntityType, void),
        // Component storage: keyed by type ID, stores type-erased pointers
        storages: std.AutoHashMap(usize, *anyopaque),
        // Cleanup functions for each storage
        cleanups: std.ArrayListUnmanaged(CleanupFn) = .{},
        // Per-storage entity removal functions (for destroyEntity cleanup)
        remove_fns: std.ArrayListUnmanaged(RemoveEntityFn) = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .alive = std.AutoHashMap(EntityType, void).init(allocator),
                .storages = std.AutoHashMap(usize, *anyopaque).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.cleanups.items) |cleanup| {
                cleanup(self);
            }
            self.cleanups.deinit(self.allocator);
            self.remove_fns.deinit(self.allocator);
            self.storages.deinit();
            self.alive.deinit();
        }

        pub fn createEntity(self: *Self) EntityType {
            const id = self.next_id;
            self.next_id += 1;
            self.alive.put(id, {}) catch @panic("OOM");
            return id;
        }

        pub fn destroyEntity(self: *Self, entity: EntityType) void {
            _ = self.alive.remove(entity);
            // Clean up components from all storages
            for (self.remove_fns.items) |remove_fn| {
                remove_fn(self, entity);
            }
        }

        pub fn entityExists(self: *Self, entity: EntityType) bool {
            return self.alive.contains(entity);
        }

        pub fn addComponent(self: *Self, entity: EntityType, component: anytype) void {
            const T = @TypeOf(component);
            const storage = self.getOrCreateStorage(T);
            storage.put(entity, component) catch @panic("OOM");
        }

        pub fn getComponent(self: *Self, entity: EntityType, comptime T: type) ?*T {
            const storage = self.getStorage(T) orelse return null;
            return storage.getPtr(entity);
        }

        pub fn hasComponent(self: *Self, entity: EntityType, comptime T: type) bool {
            const storage = self.getStorage(T) orelse return false;
            return storage.contains(entity);
        }

        pub fn removeComponent(self: *Self, entity: EntityType, comptime T: type) void {
            const storage = self.getStorage(T) orelse return;
            _ = storage.remove(entity);
        }

        // Internal: get or create a typed storage map for component type T
        fn getOrCreateStorage(self: *Self, comptime T: type) *std.AutoHashMap(EntityType, T) {
            const tid = typeId(T);
            if (self.storages.get(tid)) |raw| {
                return @ptrCast(@alignCast(raw));
            }
            const storage = self.allocator.create(std.AutoHashMap(EntityType, T)) catch @panic("OOM");
            storage.* = std.AutoHashMap(EntityType, T).init(self.allocator);
            self.storages.put(tid, @ptrCast(storage)) catch @panic("OOM");

            // Register cleanup function for this storage type
            self.cleanups.append(self.allocator, &struct {
                fn cleanup(s: *Self) void {
                    const id = typeId(T);
                    if (s.storages.get(id)) |raw| {
                        const typed: *std.AutoHashMap(EntityType, T) = @ptrCast(@alignCast(raw));
                        typed.deinit();
                        s.allocator.destroy(typed);
                    }
                }
            }.cleanup) catch @panic("OOM");

            // Register per-entity removal function for destroyEntity cleanup
            self.remove_fns.append(self.allocator, &struct {
                fn remove(s: *Self, entity: EntityType) void {
                    const id = typeId(T);
                    if (s.storages.get(id)) |raw| {
                        const typed: *std.AutoHashMap(EntityType, T) = @ptrCast(@alignCast(raw));
                        _ = typed.remove(entity);
                    }
                }
            }.remove) catch @panic("OOM");

            return storage;
        }

        fn getStorage(self: *Self, comptime T: type) ?*std.AutoHashMap(EntityType, T) {
            const tid = typeId(T);
            const raw = self.storages.get(tid) orelse return null;
            return @ptrCast(@alignCast(raw));
        }

        /// Unique type ID per component type. The anonymous struct references T
        /// to prevent the compiler from deduplicating across different types.
        fn typeId(comptime T: type) usize {
            return @intFromPtr(&struct {
                comptime {
                    _ = T;
                }
                var x: u8 = 0;
            }.x);
        }
    };
}
