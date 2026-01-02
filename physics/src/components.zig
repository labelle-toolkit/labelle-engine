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

/// Collider configuration
///
/// Defines the collision shape and material properties.
/// Must be paired with RigidBody for physics simulation.
///
/// Example in .zon:
/// ```
/// .Collider = .{
///     .shape = .{ .box = .{ .width = 32, .height = 32 } },
///     .friction = 0.3,
///     .restitution = 0.1,
/// },
/// ```
pub const Collider = struct {
    /// Collision shape (required)
    shape: Shape,

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

    /// Offset from entity position (for compound shapes)
    offset: [2]f32 = .{ 0, 0 },

    /// Rotation offset in radians
    angle: f32 = 0,
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
