// Gizmo registry - comptime gizmo configurations per prefab
//
// Gizmos are debug-only visualizations defined separately from prefabs.
// Each prefab can have a corresponding gizmo file in the gizmos/ directory.
//
// Gizmo file format:
//
// Simple prefab (no children):
//   .{
//       .entity = .{
//           .Text = .{ .text = "Player", .size = 12, .y = -25, .color = ... },
//           .Shape = .{ .shape = .{ .circle = .{ .radius = 3 } }, .color = ... },
//       },
//   }
//
// Prefab with nested children:
//   .{
//       .entity = .{
//           .Text = .{ .text = "Oven", .size = 14, .y = -40, .color = ... },
//       },
//       .children = .{
//           .storages = .{
//               .{ .Text = .{ .text = "EIS-F", ... } },
//               .{ .Text = .{ .text = "EIS-W", ... } },
//           },
//       },
//   }

/// Comptime gizmo registry - maps prefab names to their gizmo configurations.
/// Usage:
///   const Gizmos = GizmoRegistry(.{
///       .baker = @import("gizmos/baker.zon"),
///       .oven = @import("gizmos/oven.zon"),
///   });
pub fn GizmoRegistry(comptime gizmo_map: anytype) type {
    return struct {
        const GizmoMap = @TypeOf(gizmo_map);

        /// Check if a prefab has gizmo configuration
        pub fn has(comptime name: []const u8) bool {
            return @hasField(GizmoMap, name);
        }

        /// Get raw gizmo data for a prefab
        pub fn get(comptime name: []const u8) @TypeOf(@field(gizmo_map, name)) {
            return @field(gizmo_map, name);
        }

        /// Get the .entity gizmos for a prefab (top-level entity gizmos).
        /// Returns the gizmo struct if present, or null.
        pub fn getEntityGizmos(comptime name: []const u8) ?@TypeOf(getEntityGizmosType(name)) {
            const data = get(name);
            if (@hasField(@TypeOf(data), "entity")) {
                return data.entity;
            }
            return null;
        }

        /// Get the .children gizmos for a prefab (nested child entity gizmos).
        /// Returns the children struct if present, or null.
        pub fn getChildrenGizmos(comptime name: []const u8) ?@TypeOf(getChildrenGizmosType(name)) {
            const data = get(name);
            if (@hasField(@TypeOf(data), "children")) {
                return data.children;
            }
            return null;
        }

        // Type helpers for return type resolution
        fn getEntityGizmosType(comptime name: []const u8) @TypeOf(@field(gizmo_map, name).entity) {
            return get(name).entity;
        }

        fn getChildrenGizmosType(comptime name: []const u8) @TypeOf(@field(gizmo_map, name).children) {
            return get(name).children;
        }
    };
}
