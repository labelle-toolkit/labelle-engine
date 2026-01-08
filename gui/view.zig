//! GUI View Registry
//!
//! Comptime registry for declarative GUI views defined in .zon files.
//! Similar to PrefabRegistry for scene prefabs.

const std = @import("std");
const types = @import("types.zig");

/// View definition loaded from .zon file
pub const ViewDef = struct {
    /// View name (for identification and loading)
    name: []const u8,
    /// List of GUI elements in this view
    elements: []const types.GuiElement,
};

/// Comptime view registry for declarative GUI views.
///
/// Usage:
/// ```zig
/// const Views = gui.ViewRegistry(.{
///     .hud = @import("gui/hud.zon"),
///     .pause_menu = @import("gui/pause_menu.zon"),
/// });
///
/// // Check if view exists
/// if (Views.has("hud")) { ... }
///
/// // Get view definition
/// const hud = Views.get("hud");
/// ```
pub fn ViewRegistry(comptime view_map: anytype) type {
    return struct {
        const Self = @This();

        /// Check if a view with the given name exists
        pub fn has(comptime name: []const u8) bool {
            return @hasField(@TypeOf(view_map), name);
        }

        /// Get the view definition for the given name
        pub fn get(comptime name: []const u8) ViewDef {
            const view_data = @field(view_map, name);
            return .{
                .name = if (@hasField(@TypeOf(view_data), "name")) view_data.name else name,
                .elements = if (@hasField(@TypeOf(view_data), "elements")) view_data.elements else &.{},
            };
        }

        /// Get all view names in this registry
        pub fn names() []const []const u8 {
            comptime {
                const fields = std.meta.fields(@TypeOf(view_map));
                var result: [fields.len][]const u8 = undefined;
                for (fields, 0..) |field, i| {
                    result[i] = field.name;
                }
                return &result;
            }
        }

        /// Get the number of views in this registry
        pub fn count() comptime_int {
            return std.meta.fields(@TypeOf(view_map)).len;
        }
    };
}

/// Empty view registry for when no GUI views are defined
pub const EmptyViewRegistry = ViewRegistry(.{});

// Tests
test "ViewRegistry basic functionality" {
    const TestViews = ViewRegistry(.{
        .test_view = .{
            .name = "test_view",
            .elements = &.{
                .{ .Label = .{ .text = "Hello" } },
            },
        },
    });

    try std.testing.expect(TestViews.has("test_view"));
    try std.testing.expect(!TestViews.has("nonexistent"));

    const view = TestViews.get("test_view");
    try std.testing.expectEqualStrings("test_view", view.name);
    try std.testing.expectEqual(@as(usize, 1), view.elements.len);
}
