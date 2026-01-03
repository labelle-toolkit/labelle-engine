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
