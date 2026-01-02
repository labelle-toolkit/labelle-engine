// GravityBody Component
// Marks an entity for physics simulation with gravity

pub const BodyType = enum {
    dynamic,
    static,
    kinematic,
};

pub const GravityBody = struct {
    body_type: BodyType = .dynamic,
    restitution: f32 = 0.5,
    friction: f32 = 0.3,
    density: f32 = 1.0,
};
