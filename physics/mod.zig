//! labelle-physics - 2D Physics Module for labelle-engine
//!
//! Provides physics simulation via Box2D, integrated with the ECS.
//!
//! ## Quick Start
//! ```zig
//! const physics = @import("labelle-physics");
//!
//! // Initialize physics world
//! var world = try physics.PhysicsWorld.init(allocator, .{ 0, 9.8 });
//! defer world.deinit();
//!
//! // In game loop:
//! physics.systems.physicsInitSystem(&world, registry);
//! physics.systems.physicsSystem(&world, registry, dt);
//!
//! // Query collision events:
//! for (world.getCollisionBeginEvents()) |event| {
//!     // Handle collision
//! }
//! ```

const std = @import("std");

// Core types
pub const PhysicsWorld = @import("src/world.zig").PhysicsWorld;
pub const CollisionEvent = @import("src/world.zig").CollisionEvent;
pub const SensorEvent = @import("src/world.zig").SensorEvent;
pub const FixtureList = @import("src/world.zig").FixtureList;
pub const DEFAULT_MAX_ENTITIES = @import("src/world.zig").DEFAULT_MAX_ENTITIES;

// Data structures
pub const SparseSet = @import("src/sparse_set.zig").SparseSet;

// Components (user-facing, serializable to .zon)
pub const components = @import("src/components.zig");
pub const RigidBody = components.RigidBody;
pub const Collider = components.Collider;
pub const Velocity = components.Velocity;
pub const BodyType = components.BodyType;
pub const Shape = components.Shape;

// ZON-friendly component (avoids tagged union limitation)
pub const PhysicsBody = components.PhysicsBody;
pub const ColliderType = components.ColliderType;

// Systems
pub const systems = @import("src/systems.zig");

// Debug rendering
pub const debug = @import("src/debug.zig");

// Box2D adapter (internal, but exposed for advanced use)
pub const box2d = @import("src/box2d/adapter.zig");

test {
    std.testing.refAllDecls(@This());
}
