// Bouncer component - makes entities bounce around the screen
//
// This component works identically regardless of which ECS backend is used
// (zig_ecs or zflecs). The ECS interface abstracts away the differences.

pub const Bouncer = struct {
    speed_x: f32 = 100,
    speed_y: f32 = 100,
};
