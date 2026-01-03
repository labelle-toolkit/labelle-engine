//! Physics Components
//!
//! User-facing components for physics simulation. These components are:
//! - Pure data (no runtime pointers)
//! - Serializable to .zon scene files
//! - Configured by the user, read by the physics system
//!
//! Runtime physics state (body IDs, fixtures) is stored internally
//! in PhysicsWorld, not in these components.

const std = @import("std");

/// Body type determines how the physics engine treats the body
pub const BodyType = enum {
    /// Never moves - use for ground, walls, platforms
    static,
    /// Moved by code, not physics - use for moving platforms, elevators
    kinematic,
    /// Fully simulated by physics - use for players, projectiles, debris
    dynamic,
};

/// Rigid body dynamics configuration
///
/// Add this component to make an entity participate in physics simulation.
/// The actual physics body is created/managed internally by PhysicsWorld.
///
/// Example in .zon:
/// ```
/// .RigidBody = .{ .body_type = .dynamic, .mass = 1.0 },
/// ```
pub const RigidBody = struct {
    /// How the physics engine treats this body
    body_type: BodyType = .dynamic,

    /// Mass in kg (only used for dynamic bodies)
    mass: f32 = 1.0,

    /// Gravity multiplier (0 = no gravity, 1 = normal, 2 = double)
    gravity_scale: f32 = 1.0,

    /// Linear velocity damping (0 = no damping, higher = more friction)
    linear_damping: f32 = 0.0,

    /// Angular velocity damping (0 = no damping)
    angular_damping: f32 = 0.0,

    /// Prevent rotation (useful for characters)
    fixed_rotation: bool = false,

    /// Enable continuous collision detection for fast-moving objects
    /// (prevents tunneling through thin walls)
    bullet: bool = false,

    /// Initial awake state (sleeping bodies don't simulate until disturbed)
    awake: bool = true,

    /// Can this body sleep when at rest? (improves performance)
    allow_sleep: bool = true,
};

/// Collision shape types
pub const Shape = union(enum) {
    /// Axis-aligned box (most common for platformers)
    box: struct {
        width: f32,
        height: f32,
    },

    /// Circle (good for balls, wheels, or simple characters)
    circle: struct {
        radius: f32,
    },

    /// Convex polygon (max 8 vertices in Box2D)
    polygon: struct {
        /// Vertices in local space, counter-clockwise order
        vertices: []const [2]f32,
    },

    /// Edge/line segment (for terrain, one-sided platforms)
    edge: struct {
        start: [2]f32,
        end: [2]f32,
    },

    /// Chain of edges (for complex terrain outlines)
    chain: struct {
        vertices: []const [2]f32,
        /// If true, creates a closed loop
        loop: bool = false,
    },
};

/// Shape entry for compound colliders
/// Each entry represents a single shape with its own offset and rotation
pub const ShapeEntry = struct {
    /// The collision shape
    shape: Shape,
    /// Offset from entity center (in pixels)
    offset: [2]f32 = .{ 0, 0 },
    /// Rotation offset in radians
    angle: f32 = 0,
};

/// Maximum shapes per collider (based on benchmark results)
pub const MAX_SHAPES: usize = 8;

/// Collider configuration
///
/// Defines collision shape(s) and material properties.
/// Must be paired with RigidBody for physics simulation.
///
/// Single shape example:
/// ```
/// .Collider = .{
///     .shape = .{ .box = .{ .width = 32, .height = 32 } },
///     .friction = 0.3,
/// },
/// ```
///
/// Compound shape example (L-shaped):
/// ```
/// .Collider = .{
///     .shapes = &.{
///         .{ .shape = .{ .box = .{ .width = 50, .height = 20 } }, .offset = .{ 0, 0 } },
///         .{ .shape = .{ .box = .{ .width = 20, .height = 50 } }, .offset = .{ 15, 15 } },
///     },
/// },
/// ```
pub const Collider = struct {
    /// Single collision shape (use for simple colliders)
    /// If null, uses shapes array instead
    shape: ?Shape = null,

    /// Multiple shapes for compound colliders (per benchmark: 2500x faster than multi-component)
    /// Use this for L-shapes, T-shapes, complex characters, etc.
    shapes: []const ShapeEntry = &.{},

    /// Density in kg/m² (affects mass when using density-based mass)
    density: f32 = 1.0,

    /// Friction coefficient (0 = ice, 1 = rubber)
    friction: f32 = 0.3,

    /// Bounciness (0 = no bounce, 1 = perfect bounce)
    restitution: f32 = 0.0,

    /// Restitution velocity threshold (velocities below this won't bounce)
    restitution_threshold: f32 = 1.0,

    /// If true, collider triggers events but has no physical response
    /// (use for trigger zones, pickups, damage areas)
    is_sensor: bool = false,

    /// Collision filtering - what categories this collider belongs to
    category_bits: u16 = 0x0001,

    /// Collision filtering - what categories this collider collides with
    mask_bits: u16 = 0xFFFF,

    /// Group index for fine-grained collision control
    /// Negative = never collide with same group
    /// Positive = always collide with same group
    group_index: i16 = 0,

    /// Offset from entity position (for single shape only)
    offset: [2]f32 = .{ 0, 0 },

    /// Rotation offset in radians (for single shape only)
    angle: f32 = 0,

    /// Returns an iterator over all shapes in this collider
    pub fn shapeIterator(self: *const Collider) ShapeIterator {
        return ShapeIterator.init(self);
    }

    /// Shape iterator for unified access to single or compound shapes
    pub const ShapeIterator = struct {
        collider: *const Collider,
        index: usize = 0,

        pub fn init(collider: *const Collider) ShapeIterator {
            return .{ .collider = collider };
        }

        pub fn next(self: *ShapeIterator) ?ShapeEntry {
            // If single shape is set, return it first
            if (self.index == 0 and self.collider.shape != null) {
                self.index = 1;
                return ShapeEntry{
                    .shape = self.collider.shape.?,
                    .offset = self.collider.offset,
                    .angle = self.collider.angle,
                };
            }

            // Then iterate compound shapes
            const shapes_start: usize = if (self.collider.shape != null) 1 else 0;
            const shapes_index = self.index - shapes_start;

            if (shapes_index < self.collider.shapes.len) {
                self.index += 1;
                return self.collider.shapes[shapes_index];
            }

            return null;
        }

        pub fn count(self: *const ShapeIterator) usize {
            var n: usize = 0;
            if (self.collider.shape != null) n += 1;
            n += self.collider.shapes.len;
            return n;
        }
    };
};

/// Velocity component for direct velocity access
///
/// Optional - physics bodies have velocity internally, but this component
/// allows direct access/modification from game code.
///
/// Example in .zon:
/// ```
/// .Velocity = .{ .linear = .{ 100, 0 } },  // Moving right at 100 units/sec
/// ```
pub const Velocity = struct {
    /// Linear velocity in units per second
    linear: [2]f32 = .{ 0, 0 },

    /// Angular velocity in radians per second
    angular: f32 = 0,
};

/// Maximum entities that can be touching at once
pub const MAX_TOUCHING: usize = 8;

/// Touching component - queryable collision state (auto-managed by physics)
///
/// This component is automatically added/updated by the physics system.
/// It provides O(1) collision queries via standard ECS queries.
/// Per benchmark: 37x faster iteration than central registry.
///
/// Example query in game code:
/// ```zig
/// var query = registry.query(.{ Position, Touching });
/// while (query.next()) |e, pos, touching| {
///     for (touching.slice()) |other| {
///         // e is touching other
///     }
/// }
/// ```
///
/// Sensor overlap example:
/// ```zig
/// var sensors = registry.query(.{ Collider, Touching });
/// while (sensors.next()) |e, collider, touching| {
///     if (collider.is_sensor) {
///         // touching.slice() contains overlapping entities
///     }
/// }
/// ```
pub const Touching = struct {
    /// Entity IDs currently touching this entity
    entities: [MAX_TOUCHING]u64 = undefined,
    /// Number of valid entries in entities array
    count: u8 = 0,

    /// Check if touching a specific entity
    pub fn contains(self: *const Touching, entity: u64) bool {
        for (self.entities[0..self.count]) |e| {
            if (e == entity) return true;
        }
        return false;
    }

    /// Get slice of all touching entities
    pub fn slice(self: *const Touching) []const u64 {
        return self.entities[0..self.count];
    }

    /// Add an entity to the touching list (used internally by physics)
    pub fn add(self: *Touching, entity: u64) void {
        // Check if already present
        for (self.entities[0..self.count]) |e| {
            if (e == entity) return;
        }
        // Add if space available
        if (self.count < MAX_TOUCHING) {
            self.entities[self.count] = entity;
            self.count += 1;
        } else {
            std.log.warn("Touching component full (max: {}). Dropping contact.", .{MAX_TOUCHING});
        }
    }

    /// Remove an entity from the touching list (used internally by physics)
    pub fn remove(self: *Touching, entity: u64) void {
        for (0..self.count) |i| {
            if (self.entities[i] == entity) {
                // Swap with last element
                if (i < self.count - 1) {
                    self.entities[i] = self.entities[self.count - 1];
                }
                self.count -= 1;
                return;
            }
        }
    }

    /// Clear all touching entities (used internally by physics)
    pub fn clear(self: *Touching) void {
        self.count = 0;
    }

    /// Check if not touching anything
    pub fn isEmpty(self: *const Touching) bool {
        return self.count == 0;
    }
};


// Tests
test "RigidBody defaults" {
    const rb = RigidBody{};
    try std.testing.expectEqual(BodyType.dynamic, rb.body_type);
    try std.testing.expectEqual(@as(f32, 1.0), rb.mass);
    try std.testing.expectEqual(@as(f32, 1.0), rb.gravity_scale);
    try std.testing.expect(rb.awake);
    try std.testing.expect(rb.allow_sleep);
    try std.testing.expect(!rb.fixed_rotation);
    try std.testing.expect(!rb.bullet);
}

test "Collider defaults" {
    const collider = Collider{
        .shape = .{ .box = .{ .width = 32, .height = 32 } },
    };
    try std.testing.expectEqual(@as(f32, 1.0), collider.density);
    try std.testing.expectEqual(@as(f32, 0.3), collider.friction);
    try std.testing.expectEqual(@as(f32, 0.0), collider.restitution);
    try std.testing.expect(!collider.is_sensor);
    try std.testing.expectEqual(@as(u16, 0x0001), collider.category_bits);
    try std.testing.expectEqual(@as(u16, 0xFFFF), collider.mask_bits);
}

test "Shape variants" {
    const box = Shape{ .box = .{ .width = 10, .height = 20 } };
    const circle = Shape{ .circle = .{ .radius = 5 } };
    const edge = Shape{ .edge = .{ .start = .{ 0, 0 }, .end = .{ 100, 0 } } };

    switch (box) {
        .box => |b| {
            try std.testing.expectEqual(@as(f32, 10), b.width);
            try std.testing.expectEqual(@as(f32, 20), b.height);
        },
        else => unreachable,
    }

    switch (circle) {
        .circle => |c| try std.testing.expectEqual(@as(f32, 5), c.radius),
        else => unreachable,
    }

    switch (edge) {
        .edge => |e| {
            try std.testing.expectEqual(@as(f32, 0), e.start[0]);
            try std.testing.expectEqual(@as(f32, 100), e.end[0]);
        },
        else => unreachable,
    }
}
