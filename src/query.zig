//! ECS Query Facade — Backend-agnostic Query API
//!
//! Provides utilities for ECS queries across different backends.
//! The actual query execution is done by the ECS backend via Ecs(Backend).

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

/// Generates the callback function type for a query.
/// Only includes pointers for non-zero-sized components.
pub fn CallbackType(comptime EntityType: type, comptime components: anytype) type {
    const separated = separateComponents(components);
    const data_types = separated.data;

    var params: [data_types.len + 1]std.builtin.Type.Fn.Param = undefined;

    params[0] = .{
        .is_generic = false,
        .is_noalias = false,
        .type = EntityType,
    };

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

