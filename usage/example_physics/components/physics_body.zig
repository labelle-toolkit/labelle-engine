// PhysicsBody Component
// Marks an entity for physics simulation

pub const BodyType = enum {
    dynamic,
    static,
    kinematic,
};

pub const ColliderType = enum {
    box,
    circle,
};

pub const PhysicsBody = struct {
    body_type: BodyType = .dynamic,
    collider_type: ColliderType = .box,
    // For box colliders
    width: f32 = 50,
    height: f32 = 50,
    // For circle colliders
    radius: f32 = 25,
    // Physics properties
    restitution: f32 = 0.5,
    friction: f32 = 0.3,
    density: f32 = 1.0,
};
