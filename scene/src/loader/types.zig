// Loader types and helpers
//
// This module contains types and utility functions used by the scene loader.

const std = @import("std");
const ecs = @import("ecs");
const hooks_types = @import("../../../hooks/types.zig");

pub const Entity = ecs.Entity;

/// ComponentPayload for onReady callbacks - reuse the same type as onAdd
pub const ComponentPayload = hooks_types.ComponentPayload;

/// Entry in the onReady callback queue
pub const ReadyCallbackEntry = struct {
    entity: Entity,
    callback: *const fn (ComponentPayload) void,
};

/// Convert a comptime string to lowercase (public for testing)
pub fn toLowercase(comptime str: []const u8) *const [str.len]u8 {
    comptime {
        var result: [str.len]u8 = undefined;
        for (str, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const final = result;
        return &final;
    }
}

/// Parent context for nested entity creation
pub const ParentContext = struct {
    entity: Entity,
    component_name: []const u8, // The parent component type name (e.g., "Workstation")
};

/// No parent context (for top-level entities)
pub const no_parent: ?ParentContext = null;

/// Scene-level camera configuration
pub const SceneCameraConfig = struct {
    x: ?f32 = null,
    y: ?f32 = null,
    zoom: f32 = 1.0,
};

/// Named camera slot for multi-camera scenes
pub const CameraSlot = enum(u2) {
    main = 0, // Primary camera (camera 0)
    player2 = 1, // Second player camera (camera 1)
    minimap = 2, // Minimap/overview camera (camera 2)
    camera3 = 3, // Fourth camera (camera 3)
};

/// Simple position struct for loader internal use
pub const Pos = struct { x: f32, y: f32 };

// ============================================
// ENTITY REFERENCES (Issue #242)
// ============================================

/// Reference to another entity by name or ID.
/// Used in .zon files with syntax:
///   - By name: .{ .ref = .{ .entity = "player" } }
///   - By ID:   .{ .ref = .{ .id = "player_1" } }
///   - Self:    .{ .ref = .self }
pub const EntityRef = struct {
    /// The referenced entity (resolved at load time)
    entity: Entity = @bitCast(@as(ecs.EntityBits, 0)),

    /// Check if this reference is valid (entity exists)
    pub fn isValid(self: EntityRef, registry: *ecs.Registry) bool {
        return registry.entityExists(self.entity);
    }

    /// Get a component from the referenced entity
    pub fn getComponent(self: EntityRef, comptime T: type, registry: *ecs.Registry) ?*T {
        if (!registry.entityExists(self.entity)) return null;
        return registry.getComponent(self.entity, T);
    }

    /// Create an invalid/empty reference
    pub fn invalid() EntityRef {
        return .{ .entity = @bitCast(@as(ecs.EntityBits, 0)) };
    }
};

/// Callback type for resolving entity references
pub const RefResolveCallback = *const fn (registry: *ecs.Registry, target: Entity, resolved: Entity) void;

/// Entry for deferred reference resolution (Phase 2 of loading)
pub const PendingReference = struct {
    /// The entity that has the reference field
    target_entity: Entity,
    /// Callback to set the resolved entity (captures comptime component/field)
    resolve_callback: RefResolveCallback,
    /// Name or ID of the referenced entity
    ref_key: []const u8,
    /// Whether this is a self-reference (.ref = .self)
    is_self_ref: bool,
    /// Whether this reference is by ID (true) or by name (false)
    is_id_ref: bool,
};

/// Entry for deferred parent-child relationship (Phase 2 of loading)
/// Used when .parent field is specified on an entity definition
pub const PendingParentRef = struct {
    /// The child entity that will be parented
    child_entity: Entity,
    /// Name or ID of the parent entity (resolved by trying ID first, then name)
    parent_key: []const u8,
    /// Display name of the child entity (for diagnostics)
    child_name: []const u8 = "",
    /// Whether to inherit rotation from parent
    inherit_rotation: bool = false,
    /// Whether to inherit scale from parent
    inherit_scale: bool = false,
};

/// Entity map for reference resolution (used for both names and IDs)
pub const EntityMap = std.StringHashMap(Entity);

/// Context for reference resolution during scene loading
pub const ReferenceContext = struct {
    /// Map of entity display names to entity IDs (for .ref.entity lookups)
    named_entities: EntityMap,
    /// Map of entity unique IDs to entity IDs (for .ref.id lookups)
    entity_ids: EntityMap,
    /// Current entity being created (for self-references)
    current_entity: ?Entity = null,
    /// Pending references to resolve in Phase 2
    pending_refs: std.ArrayListUnmanaged(PendingReference),
    /// Pending parent-child relationships to resolve in Phase 2
    pending_parents: std.ArrayListUnmanaged(PendingParentRef),
    /// Allocator for pending refs
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ReferenceContext {
        return .{
            .named_entities = EntityMap.init(allocator),
            .entity_ids = EntityMap.init(allocator),
            .pending_refs = .{},
            .pending_parents = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReferenceContext) void {
        self.named_entities.deinit();
        self.entity_ids.deinit();
        self.pending_refs.deinit(self.allocator);
        self.pending_parents.deinit(self.allocator);
    }

    /// Register a named entity for later reference resolution (display name)
    /// Note: Names can duplicate - last entity with a given name wins for reference resolution
    pub fn registerNamed(self: *ReferenceContext, name: []const u8, entity: Entity) !void {
        try self.named_entities.put(name, entity);
    }

    /// Register an entity ID for later reference resolution (unique ID)
    /// Warns if duplicate ID is registered (IDs should be unique)
    pub fn registerId(self: *ReferenceContext, id: []const u8, entity: Entity) !void {
        if (self.entity_ids.contains(id)) {
            std.log.warn("[SceneLoader] Duplicate entity ID '{s}' - previous entity will be unreachable by ID reference", .{id});
        }
        try self.entity_ids.put(id, entity);
    }

    /// Add a pending reference to resolve in Phase 2
    pub fn addPendingRef(self: *ReferenceContext, pending: PendingReference) !void {
        try self.pending_refs.append(self.allocator, pending);
    }

    /// Add a pending parent-child relationship to resolve in Phase 2
    pub fn addPendingParent(self: *ReferenceContext, pending: PendingParentRef) !void {
        try self.pending_parents.append(self.allocator, pending);
    }

    /// Resolve an entity reference by display name
    pub fn resolveByName(self: *const ReferenceContext, name: []const u8) ?Entity {
        return self.named_entities.get(name);
    }

    /// Resolve an entity reference by unique ID
    pub fn resolveById(self: *const ReferenceContext, id: []const u8) ?Entity {
        return self.entity_ids.get(id);
    }

    /// Resolve an entity reference (by ID or name based on is_id_ref flag)
    pub fn resolve(self: *const ReferenceContext, key: []const u8, is_id_ref: bool) ?Entity {
        return if (is_id_ref) self.resolveById(key) else self.resolveByName(key);
    }
};

/// Get a field from comptime data or return a default value if not present
pub fn getFieldOrDefault(comptime data: anytype, comptime field_name: []const u8, comptime default: anytype) @TypeOf(default) {
    if (@hasField(@TypeOf(data), field_name)) {
        return @field(data, field_name);
    } else {
        return default;
    }
}

/// Get position from entity definition's .components.Position
/// Returns null if no Position component is defined
pub fn getPositionFromComponents(comptime entity_def: anytype) ?Pos {
    if (@hasField(@TypeOf(entity_def), "components")) {
        if (@hasField(@TypeOf(entity_def.components), "Position")) {
            const pos = entity_def.components.Position;
            return .{
                .x = getFieldOrDefault(pos, "x", @as(f32, 0)),
                .y = getFieldOrDefault(pos, "y", @as(f32, 0)),
            };
        }
    }
    return null;
}

/// Apply camera configuration from comptime config data to a camera
pub fn applyCameraConfig(comptime config: anytype, camera: anytype) void {
    // Extract optional x and y values
    const x: ?f32 = if (@hasField(@TypeOf(config), "x") and @TypeOf(config.x) != @TypeOf(null))
        config.x
    else
        null;
    const y: ?f32 = if (@hasField(@TypeOf(config), "y") and @TypeOf(config.y) != @TypeOf(null))
        config.y
    else
        null;

    // Apply position if either coordinate is specified
    if (x != null or y != null) {
        camera.setPosition(x orelse 0, y orelse 0);
    }

    // Apply zoom if specified
    if (@hasField(@TypeOf(config), "zoom")) {
        camera.setZoom(config.zoom);
    }
}
