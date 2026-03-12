// Gizmo Registry — debug visualization configs
//
// Ported from v1 scene/src/gizmo_registry.zig

const std = @import("std");

/// Re-export canonical GizmoComponent from labelle-core so engine and renderer
/// use the same Zig type (same source location → same type identity).
pub const GizmoComponent = @import("labelle-core").GizmoComponent;

/// Comptime gizmo registry — maps prefab names to debug visualization configs.
///
/// Usage:
///   const Gizmos = GizmoRegistry(.{
///       .player = @import("gizmos/player.zon"),
///       .enemy = @import("gizmos/enemy.zon"),
///   });
///
/// Gizmo .zon files support optional `.match` and `.exclude` fields for
/// component-based reconciliation:
///   .{ .match = .{"Item"}, .exclude = .{"Stored"}, .entity = .{ ... } }
pub fn GizmoRegistry(comptime gizmo_map: anytype) type {
    return struct {
        const GizmoMap = @TypeOf(gizmo_map);
        pub const fields = @typeInfo(GizmoMap).@"struct".fields;

        pub fn has(comptime name: []const u8) bool {
            return @hasField(GizmoMap, name);
        }

        pub fn get(comptime name: []const u8) @TypeOf(@field(gizmo_map, name)) {
            return @field(gizmo_map, name);
        }

        pub fn getEntityGizmos(comptime name: []const u8) ?EntityGizmosType(name) {
            const data = get(name);
            if (@hasField(@TypeOf(data), "entity")) {
                return data.entity;
            }
            return null;
        }

        pub fn getChildrenGizmos(comptime name: []const u8) ?ChildrenGizmosType(name) {
            const data = get(name);
            if (@hasField(@TypeOf(data), "children")) {
                return data.children;
            }
            return null;
        }

        fn EntityGizmosType(comptime name: []const u8) type {
            const T = @TypeOf(@field(gizmo_map, name));
            if (@hasField(T, "entity")) return @TypeOf(@field(gizmo_map, name).entity);
            return void;
        }

        fn ChildrenGizmosType(comptime name: []const u8) type {
            const T = @TypeOf(@field(gizmo_map, name));
            if (@hasField(T, "children")) return @TypeOf(@field(gizmo_map, name).children);
            return void;
        }
    };
}

/// Convert snake_case to PascalCase at comptime.
pub fn snakeToPascal(comptime snake: []const u8) []const u8 {
    return comptime blk: {
        var buf: [snake.len]u8 = undefined;
        var ri: usize = 0;
        var cap_next = true;
        for (snake) |c| {
            if (c == '_') {
                cap_next = true;
            } else {
                buf[ri] = if (cap_next) std.ascii.toUpper(c) else c;
                cap_next = false;
                ri += 1;
            }
        }
        const final: *const [ri]u8 = buf[0..ri];
        break :blk final;
    };
}

/// Empty gizmo registry for when no gizmos are defined.
pub const NoGizmos = GizmoRegistry(.{});
