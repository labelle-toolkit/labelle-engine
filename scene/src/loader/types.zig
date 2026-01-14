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

/// Reference to another entity by name.
/// Used in .zon files with syntax: .{ .ref = .{ .entity = "player" } }
/// For self-references: .{ .ref = .self }
pub const EntityRef = struct {
    /// The referenced entity (resolved at load time)
    entity: Entity = @bitCast(@as(ecs.EntityBits, 0)),

    /// Check if this reference is valid (entity exists)
    pub fn isValid(self: EntityRef, registry: *ecs.Registry) bool {
        return registry.isValid(self.entity);
    }

    /// Get a component from the referenced entity
    pub fn getComponent(self: EntityRef, comptime T: type, registry: *ecs.Registry) ?*T {
        if (!registry.isValid(self.entity)) return null;
        return registry.tryGet(T, self.entity);
    }

    /// Create an invalid/empty reference
    pub fn invalid() EntityRef {
        return .{ .entity = @bitCast(@as(ecs.EntityBits, 0)) };
    }
};

/// Entry for deferred reference resolution (Phase 2 of loading)
pub const PendingReference = struct {
    /// The entity that has the reference field
    target_entity: Entity,
    /// Component type name containing the reference
    component_name: []const u8,
    /// Field name within the component
    field_name: []const u8,
    /// Name of the referenced entity (from .ref.entity)
    ref_entity_name: []const u8,
    /// Whether this is a self-reference (.ref = .self)
    is_self_ref: bool,
};

/// Named entity registry for reference resolution
pub const NamedEntityMap = std.StringHashMap(Entity);

/// Context for reference resolution during scene loading
pub const ReferenceContext = struct {
    /// Map of entity names to entity IDs
    named_entities: NamedEntityMap,
    /// Current entity being created (for self-references)
    current_entity: ?Entity = null,
    /// Pending references to resolve in Phase 2
    pending_refs: std.ArrayList(PendingReference),

    pub fn init(allocator: std.mem.Allocator) ReferenceContext {
        return .{
            .named_entities = NamedEntityMap.init(allocator),
            .pending_refs = std.ArrayList(PendingReference).init(allocator),
        };
    }

    pub fn deinit(self: *ReferenceContext) void {
        self.named_entities.deinit();
        self.pending_refs.deinit();
    }

    /// Register a named entity for later reference resolution
    pub fn registerNamed(self: *ReferenceContext, name: []const u8, entity: Entity) !void {
        try self.named_entities.put(name, entity);
    }

    /// Resolve an entity reference by name
    pub fn resolve(self: *const ReferenceContext, name: []const u8) ?Entity {
        return self.named_entities.get(name);
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
