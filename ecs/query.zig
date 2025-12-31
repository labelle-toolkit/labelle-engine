//! ECS Query Facade - Backend-agnostic Query API
//!
//! Provides a unified interface for ECS queries across different backends:
//! - zig_ecs (prime31/zig-ecs)
//! - zflecs (zig-gamedev/zflecs)
//!
//! Key design decisions:
//! - Zero-sized types (tags) are used as query filters only, no pointers passed
//! - All backends support the same query API
//! - No allocations per iteration
//!
//! Usage:
//!   var q = registry.query(.{ Position, Velocity });
//!   q.each(struct {
//!       fn run(e: ecs.Entity, pos: *Position, vel: *Velocity) void {
//!           pos.x += vel.x;
//!           pos.y += vel.y;
//!       }
//!   }.run);

const std = @import("std");

/// Separates component types into data components (non-zero-sized) and tag components (zero-sized)
pub fn separateComponents(comptime components: anytype) struct {
    data: []const type,
    tags: []const type,
} {
    comptime {
        var data_types: []const type = &.{};
        var tag_types: []const type = &.{};

        for (components) |T| {
            if (@sizeOf(T) == 0) {
                tag_types = tag_types ++ .{T};
            } else {
                data_types = data_types ++ .{T};
            }
        }

        return .{
            .data = data_types,
            .tags = tag_types,
        };
    }
}

/// Generates the callback function type for a query
/// Only includes pointers for non-zero-sized components
pub fn CallbackType(comptime EntityType: type, comptime components: anytype) type {
    const separated = separateComponents(components);
    const data_types = separated.data;

    // Build the function parameter types: Entity + *DataComponent...
    var params: [data_types.len + 1]std.builtin.Type.Fn.Param = undefined;

    // First param is always Entity
    params[0] = .{
        .is_generic = false,
        .is_noalias = false,
        .type = EntityType,
    };

    // Remaining params are pointers to data components
    for (data_types, 0..) |T, i| {
        params[i + 1] = .{
            .is_generic = false,
            .is_noalias = false,
            .type = *T,
        };
    }

    return @Type(.{
        .@"fn" = .{
            .calling_convention = .auto,
            .is_generic = false,
            .is_var_args = false,
            .return_type = void,
            .params = &params,
        },
    });
}

/// Test helper to verify component separation
pub fn testSeparation() void {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const TagPlayer = struct {};
    const TagEnemy = struct {};

    const result = separateComponents(.{ Position, TagPlayer, Velocity, TagEnemy });

    // At comptime, verify the separation
    comptime {
        std.debug.assert(result.data.len == 2);
        std.debug.assert(result.tags.len == 2);
        std.debug.assert(result.data[0] == Position);
        std.debug.assert(result.data[1] == Velocity);
        std.debug.assert(result.tags[0] == TagPlayer);
        std.debug.assert(result.tags[1] == TagEnemy);
    }
}

test "component separation" {
    testSeparation();
}
