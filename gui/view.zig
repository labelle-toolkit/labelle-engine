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

/// Convert a .zon element tuple to a GuiElement slice at comptime
fn convertElements(comptime zon_elements: anytype) []const types.GuiElement {
    const ElementsType = @TypeOf(zon_elements);
    const fields = std.meta.fields(ElementsType);

    if (fields.len == 0) return &.{};

    comptime {
        var result: [fields.len]types.GuiElement = undefined;
        for (fields, 0..) |field, i| {
            const element = @field(zon_elements, field.name);
            result[i] = convertElement(element);
        }
        const final = result;
        return &final;
    }
}

/// Convert a single .zon element to GuiElement
fn convertElement(comptime zon_element: anytype) types.GuiElement {
    const ElementType = @TypeOf(zon_element);

    if (@hasField(ElementType, "Label")) {
        return .{ .Label = convertLabel(zon_element.Label) };
    } else if (@hasField(ElementType, "Button")) {
        return .{ .Button = convertButton(zon_element.Button) };
    } else if (@hasField(ElementType, "ProgressBar")) {
        return .{ .ProgressBar = convertProgressBar(zon_element.ProgressBar) };
    } else if (@hasField(ElementType, "Panel")) {
        return .{ .Panel = convertPanel(zon_element.Panel) };
    } else if (@hasField(ElementType, "Image")) {
        return .{ .Image = convertImage(zon_element.Image) };
    } else if (@hasField(ElementType, "Checkbox")) {
        return .{ .Checkbox = convertCheckbox(zon_element.Checkbox) };
    } else if (@hasField(ElementType, "Slider")) {
        return .{ .Slider = convertSlider(zon_element.Slider) };
    } else {
        @compileError("Unknown GUI element type");
    }
}

fn convertLabel(comptime zon: anytype) types.Label {
    return .{
        .id = if (@hasField(@TypeOf(zon), "id")) zon.id else "",
        .text = if (@hasField(@TypeOf(zon), "text")) zon.text else "",
        .position = if (@hasField(@TypeOf(zon), "position")) convertPosition(zon.position) else .{},
        .font_size = if (@hasField(@TypeOf(zon), "font_size")) zon.font_size else 16,
        .color = if (@hasField(@TypeOf(zon), "color")) convertColor(zon.color) else .{},
    };
}

fn convertButton(comptime zon: anytype) types.Button {
    return .{
        .id = if (@hasField(@TypeOf(zon), "id")) zon.id else "",
        .text = if (@hasField(@TypeOf(zon), "text")) zon.text else "",
        .position = if (@hasField(@TypeOf(zon), "position")) convertPosition(zon.position) else .{},
        .size = if (@hasField(@TypeOf(zon), "size")) convertSize(zon.size) else .{},
        .on_click = if (@hasField(@TypeOf(zon), "on_click")) zon.on_click else null,
    };
}

fn convertProgressBar(comptime zon: anytype) types.ProgressBar {
    return .{
        .id = if (@hasField(@TypeOf(zon), "id")) zon.id else "",
        .position = if (@hasField(@TypeOf(zon), "position")) convertPosition(zon.position) else .{},
        .size = if (@hasField(@TypeOf(zon), "size")) convertSize(zon.size) else .{},
        .value = if (@hasField(@TypeOf(zon), "value")) zon.value else 0,
        .color = if (@hasField(@TypeOf(zon), "color")) convertColor(zon.color) else .{ .r = 0, .g = 200, .b = 0 },
    };
}

fn convertPanel(comptime zon: anytype) types.Panel {
    return .{
        .id = if (@hasField(@TypeOf(zon), "id")) zon.id else "",
        .position = if (@hasField(@TypeOf(zon), "position")) convertPosition(zon.position) else .{},
        .size = if (@hasField(@TypeOf(zon), "size")) convertSize(zon.size) else .{},
        .background_color = if (@hasField(@TypeOf(zon), "background_color")) convertColor(zon.background_color) else .{ .r = 50, .g = 50, .b = 50, .a = 200 },
        .children = if (@hasField(@TypeOf(zon), "children")) convertElements(zon.children) else &.{},
    };
}

fn convertImage(comptime zon: anytype) types.Image {
    return .{
        .id = if (@hasField(@TypeOf(zon), "id")) zon.id else "",
        .name = if (@hasField(@TypeOf(zon), "name")) zon.name else "",
        .position = if (@hasField(@TypeOf(zon), "position")) convertPosition(zon.position) else .{},
        .size = if (@hasField(@TypeOf(zon), "size")) convertSize(zon.size) else null,
        .tint = if (@hasField(@TypeOf(zon), "tint")) convertColor(zon.tint) else .{},
    };
}

fn convertCheckbox(comptime zon: anytype) types.Checkbox {
    return .{
        .id = if (@hasField(@TypeOf(zon), "id")) zon.id else "",
        .text = if (@hasField(@TypeOf(zon), "text")) zon.text else "",
        .position = if (@hasField(@TypeOf(zon), "position")) convertPosition(zon.position) else .{},
        .checked = if (@hasField(@TypeOf(zon), "checked")) zon.checked else false,
        .on_change = if (@hasField(@TypeOf(zon), "on_change")) zon.on_change else null,
    };
}

fn convertSlider(comptime zon: anytype) types.Slider {
    return .{
        .id = if (@hasField(@TypeOf(zon), "id")) zon.id else "",
        .position = if (@hasField(@TypeOf(zon), "position")) convertPosition(zon.position) else .{},
        .size = if (@hasField(@TypeOf(zon), "size")) convertSize(zon.size) else .{},
        .value = if (@hasField(@TypeOf(zon), "value")) zon.value else 0,
        .min = if (@hasField(@TypeOf(zon), "min")) zon.min else 0,
        .max = if (@hasField(@TypeOf(zon), "max")) zon.max else 1,
        .on_change = if (@hasField(@TypeOf(zon), "on_change")) zon.on_change else null,
    };
}

fn convertPosition(comptime zon: anytype) types.Position {
    return .{
        .x = if (@hasField(@TypeOf(zon), "x")) zon.x else 0,
        .y = if (@hasField(@TypeOf(zon), "y")) zon.y else 0,
    };
}

fn convertSize(comptime zon: anytype) types.Size {
    return .{
        .width = if (@hasField(@TypeOf(zon), "width")) zon.width else 100,
        .height = if (@hasField(@TypeOf(zon), "height")) zon.height else 30,
    };
}

fn convertColor(comptime zon: anytype) types.Color {
    return .{
        .r = if (@hasField(@TypeOf(zon), "r")) zon.r else 255,
        .g = if (@hasField(@TypeOf(zon), "g")) zon.g else 255,
        .b = if (@hasField(@TypeOf(zon), "b")) zon.b else 255,
        .a = if (@hasField(@TypeOf(zon), "a")) zon.a else 255,
    };
}

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

        /// Get the pre-converted elements for a view
        fn getConvertedElements(comptime name: []const u8) []const types.GuiElement {
            const view_data = @field(view_map, name);
            if (@hasField(@TypeOf(view_data), "elements")) {
                return convertElements(view_data.elements);
            }
            return &[_]types.GuiElement{};
        }

        /// Get the view definition for the given name
        pub fn get(comptime name: []const u8) ViewDef {
            const view_data = @field(view_map, name);
            const view_name = if (@hasField(@TypeOf(view_data), "name")) view_data.name else name;
            return .{
                .name = view_name,
                .elements = comptime getConvertedElements(name),
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
