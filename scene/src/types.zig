// Scene Types — Entity references, reference context, and shared utilities
//
// Ported from v1 scene/src/loader/types.zig

const std = @import("std");

// ============================================================
// Entity Reference Types
// ============================================================

/// Reference info extracted at comptime from .zon entity reference syntax.
///
/// Supported syntaxes:
///   - By name: .{ .ref = .{ .entity = "player" } }
///   - By ID:   .{ .ref = .{ .id = "player_1" } }
///   - Self:    .{ .ref = .self }
pub const RefInfo = struct {
    ref_key: ?[]const u8, // null for self-ref
    is_self: bool,
    is_id_ref: bool,
};

/// Check if a comptime .zon value is an entity reference marker.
pub fn isReference(comptime val: anytype) bool {
    const T = @TypeOf(val);
    if (@typeInfo(T) != .@"struct") return false;
    return @hasField(T, "ref");
}

/// Extract reference info from a comptime .zon value.
/// Returns null if the value is not a reference.
pub fn extractRefInfo(comptime val: anytype) ?RefInfo {
    if (!@hasField(@TypeOf(val), "ref")) return null;
    const ref = val.ref;
    const RefType = @TypeOf(ref);

    // .ref = .self  (enum literal)
    if (RefType == @TypeOf(.self)) {
        return .{ .ref_key = null, .is_self = true, .is_id_ref = false };
    }

    // .ref = .{ .entity = "name" }
    if (@hasField(RefType, "entity")) {
        return .{ .ref_key = ref.entity, .is_self = false, .is_id_ref = false };
    }

    // .ref = .{ .id = "unique_id" }
    if (@hasField(RefType, "id")) {
        return .{ .ref_key = ref.id, .is_self = false, .is_id_ref = true };
    }

    return null;
}

// ============================================================
// Reference context for two-phase loading
// ============================================================

/// Pending entity reference to resolve in Phase 2.
pub fn PendingReference(comptime Entity: type) type {
    return struct {
        target_entity: Entity,
        resolve_callback: *const fn (*anyopaque, Entity, Entity) void,
        ref_key: []const u8,
        is_self_ref: bool,
        is_id_ref: bool,
    };
}

/// Pending parent-child relationship to resolve in Phase 2b.
pub fn PendingParentRef(comptime Entity: type) type {
    return struct {
        child_entity: Entity,
        parent_key: []const u8,
        child_name: []const u8 = "",
    };
}

/// Context for entity reference resolution during scene loading.
/// Tracks named/ID'd entities and pending references for two-phase loading.
pub fn ReferenceContext(comptime Entity: type) type {
    const EntityMap = std.StringHashMap(Entity);
    const PendingRef = PendingReference(Entity);
    const PendingParent = PendingParentRef(Entity);

    return struct {
        const Self = @This();

        named_entities: EntityMap,
        entity_ids: EntityMap,
        current_entity: ?Entity = null,
        pending_refs: std.ArrayListUnmanaged(PendingRef),
        pending_parents: std.ArrayListUnmanaged(PendingParent),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .named_entities = EntityMap.init(allocator),
                .entity_ids = EntityMap.init(allocator),
                .pending_refs = .{},
                .pending_parents = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.named_entities.deinit();
            self.entity_ids.deinit();
            self.pending_refs.deinit(self.allocator);
            self.pending_parents.deinit(self.allocator);
        }

        pub fn registerNamed(self: *Self, name: []const u8, entity: Entity) !void {
            try self.named_entities.put(name, entity);
        }

        pub fn registerId(self: *Self, id: []const u8, entity: Entity) !void {
            try self.entity_ids.put(id, entity);
        }

        pub fn addPendingRef(self: *Self, pending: PendingRef) !void {
            try self.pending_refs.append(self.allocator, pending);
        }

        pub fn addPendingParent(self: *Self, pending: PendingParent) !void {
            try self.pending_parents.append(self.allocator, pending);
        }

        pub fn resolveByName(self: *const Self, name: []const u8) ?Entity {
            return self.named_entities.get(name);
        }

        pub fn resolveById(self: *const Self, id: []const u8) ?Entity {
            return self.entity_ids.get(id);
        }

        pub fn resolve(self: *const Self, key: []const u8, is_id_ref: bool) ?Entity {
            return if (is_id_ref) self.resolveById(key) else self.resolveByName(key);
        }
    };
}
