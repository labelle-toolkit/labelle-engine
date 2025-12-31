// Entity utility functions for lifecycle hooks
//
// These functions convert between Entity and u64 for safe use in
// lifecycle hooks where Game/Scene types cannot be imported due
// to circular dependency constraints.

const std = @import("std");
const ecs = @import("ecs");

pub const Entity = ecs.Entity;

/// The underlying integer type that stores Entity bits
pub const EntityBits = std.meta.Int(.unsigned, @bitSizeOf(Entity));

/// Convert Entity to u64 for lifecycle hooks
pub fn entityToU64(entity: Entity) u64 {
    return @as(EntityBits, @bitCast(entity));
}

/// Convert u64 back to Entity in lifecycle hooks
pub fn entityFromU64(value: u64) Entity {
    return @bitCast(@as(EntityBits, @truncate(value)));
}

// Compile-time verification that Entity fits in u64
comptime {
    if (@sizeOf(Entity) > @sizeOf(u64)) {
        @compileError("Entity must fit in u64 for lifecycle hooks");
    }
}
