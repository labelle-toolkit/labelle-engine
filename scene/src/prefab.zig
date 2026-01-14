// Prefab system - comptime prefabs with typed components
//
// Prefabs are .zon files imported at comptime that define:
// - components.Position: Entity position (can be overridden in scene)
// - components.Sprite: Visual configuration for the entity
// - components.*: Other typed component data
// - gizmos: Debug visualizations (only created in debug builds)
//
// Example prefab file (prefabs/player.zon):
// .{
//     .components = .{
//         .Position = .{ .x = 0, .y = 0 },  // default position, can be overridden in scene
//         .Sprite = .{ .name = "player.png", .scale_x = 2.0, .scale_y = 2.0 },
//         .Health = .{ .current = 100, .max = 100 },
//         .Speed = .{ .value = 5.0 },
//     },
//     .gizmos = .{  // debug-only visualizations
//         .Text = .{ .text = "Player", .size = 12, .y = -20 },
//         .Shape = .{ .shape = .{ .circle = .{ .radius = 5 } }, .color = .{ .r = 255 } },
//     },
// }

const std = @import("std");

/// Comptime prefab registry - maps prefab names to their comptime data
/// Usage:
///   const Prefabs = PrefabRegistry(.{
///       .player = @import("prefabs/player.zon"),
///       .enemy = @import("prefabs/enemy.zon"),
///   });
pub fn PrefabRegistry(comptime prefab_map: anytype) type {
    return struct {
        const Self = @This();
        const PrefabMap = @TypeOf(prefab_map);

        /// Check if a prefab exists
        pub fn has(comptime name: anytype) bool {
            const name_str: []const u8 = name;
            return @hasField(PrefabMap, name_str);
        }

        /// Get prefab data by name (comptime only)
        pub fn get(comptime name: []const u8) @TypeOf(@field(prefab_map, name)) {
            return @field(prefab_map, name);
        }

        /// Check if prefab has components
        pub fn hasComponents(comptime name: []const u8) bool {
            const prefab_data = get(name);
            return @hasField(@TypeOf(prefab_data), "components");
        }

        /// Get prefab components data (for use with ComponentRegistry.addComponents)
        pub fn getComponents(comptime name: []const u8) @TypeOf(@field(get(name), "components")) {
            return get(name).components;
        }

        /// Check if prefab has gizmos (debug visualizations)
        pub fn hasGizmos(comptime name: []const u8) bool {
            const prefab_data = get(name);
            return @hasField(@TypeOf(prefab_data), "gizmos");
        }

        /// Get prefab gizmos data
        pub fn getGizmos(comptime name: []const u8) @TypeOf(@field(get(name), "gizmos")) {
            return get(name).gizmos;
        }
    };
}
