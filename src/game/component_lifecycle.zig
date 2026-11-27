//! Stack-owned guards: callbacks may remove a component or destroy an entity
//! recursively. Keep no component pointers across callback boundaries.
pub const Removal = struct {
    entity: u64,
    component: []const u8,
    world: *anyopaque,
    previous: ?*const Removal,
};

pub const Destruction = struct {
    entity: u64,
    world: *anyopaque,
    previous: ?*const Destruction,
};
