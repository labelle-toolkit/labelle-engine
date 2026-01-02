//! labelle-physics - 2D Physics Module for labelle-engine
//!
//! Provides physics simulation via Box2D, integrated with the ECS.
//! Uses ECS-native design: collision state via Touching component (37x faster),
//! compound shapes via shapes array (2500x faster).
//!
//! ## Quick Start
//! ```zig
//! const physics = @import("labelle-physics");
//! const engine = @import("labelle-engine");
//!
//! // Create parameterized physics systems for your Position type
//! const PhysicsSystems = physics.Systems(engine.Position);
//!
//! // Initialize physics world with gravity (pixels/sec^2)
//! var world = try physics.PhysicsWorld.init(allocator, .{ 0, 980 });
//! defer world.deinit();
//!
//! // In game loop:
//! PhysicsSystems.initBodies(&world, registry);  // Create bodies for new entities
//! PhysicsSystems.update(&world, registry, dt);  // Step physics and sync ECS
//!
//! // Query collision state via Touching component (ECS-native):
//! var query = registry.query(.{ engine.Position, physics.Touching });
//! while (query.next()) |item| {
//!     const touching = item.get(physics.Touching);
//!     for (touching.slice()) |other_id| {
//!         // Handle collision with other_id
//!     }
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
pub const Touching = components.Touching;
pub const BodyType = components.BodyType;
pub const Shape = components.Shape;
pub const ShapeEntry = components.ShapeEntry;
pub const MAX_SHAPES = components.MAX_SHAPES;
pub const MAX_TOUCHING = components.MAX_TOUCHING;


// Systems (parameterized by Position type)
pub const Systems = @import("src/systems.zig").Systems;

// Debug rendering
pub const debug = @import("src/debug.zig");

// Box2D adapter (internal, but exposed for advanced use)
pub const box2d = @import("src/box2d/adapter.zig");

test {
    std.testing.refAllDecls(@This());
}
