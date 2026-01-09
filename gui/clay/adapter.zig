//! Clay UI Adapter
//!
//! GUI backend using Clay UI layout engine.
//! Clay provides a declarative, high-performance UI layout system.
//!
//! Architecture:
//! - Collector Pattern: Widget calls are stored during the frame
//! - Clay hierarchy is built in endFrame() from collected calls
//! - Render commands are processed by renderer.zig
//! - Rendering is delegated to labelle-gfx backends (raylib)
//!
//! This adapter bridges labelle-engine's immediate-mode API with Clay's
//! declarative scope-based API by collecting calls and building the hierarchy.

const std = @import("std");
const types = @import("../types.zig");
const clay = @import("bindings.zig").clay;
const rl = @import("raylib");
const renderer = @import("renderer.zig");

const Self = @This();

/// Widget call storage for collector pattern
const WidgetCall = union(enum) {
    label: types.Label,
    button: types.Button,
    progress_bar: types.ProgressBar,
    panel_begin: types.Panel,
    panel_end: void,
    image: types.Image,
    checkbox: types.Checkbox,
    slider: types.Slider,
};

// Clay memory and context
memory: []u8 = &.{},
allocator: std.mem.Allocator = undefined,
initialized: bool = false,

// Collector pattern storage
widget_calls: std.ArrayList(WidgetCall) = undefined,
gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined,

// Screen dimensions
screen_width: f32 = 1920,
screen_height: f32 = 1080,

pub fn init() Self {
    return .{
        .initialized = false,
    };
}

pub fn fixPointers(_: *Self) void {
    // Clay manages pointers internally
}

pub fn deinit(self: *Self) void {
    if (self.initialized) {
        if (self.widget_calls.items.len > 0 or self.widget_calls.capacity > 0) {
            self.widget_calls.deinit();
        }
        if (self.memory.len > 0) {
            self.allocator.free(self.memory);
        }
        _ = self.gpa.deinit();
        self.initialized = false;
    }
}

pub fn beginFrame(self: *Self) void {
    // Lazy initialization on first frame
    if (!self.initialized) {
        self.gpa = std.heap.GeneralPurposeAllocator(.{}){};
        self.allocator = self.gpa.allocator();
        self.widget_calls = std.ArrayList(WidgetCall).init(self.allocator);

        // Initialize Clay
        const min_memory = clay.Clay_MinMemorySize();
        self.memory = self.allocator.alloc(u8, min_memory) catch {
            std.debug.print("Failed to allocate Clay memory\n", .{});
            return;
        };

        const arena = clay.Clay_CreateArenaWithCapacityAndMemory(
            min_memory,
            self.memory.ptr,
        );

        _ = clay.Clay_Initialize(
            arena,
            .{ .width = self.screen_width, .height = self.screen_height },
            .{
                .errorHandler = .{
                    .errorHandlerFunction = errorHandler,
                    .userData = null,
                },
            },
        );

        // Set text measurement function for Clay layout calculations
        clay.Clay_SetMeasureTextFunction(null, null, measureTextCallback);

        self.initialized = true;
    }

    // Clear collected calls for new frame
    self.widget_calls.clearRetainingCapacity();
}

pub fn endFrame(self: *Self) void {
    if (!self.initialized) return;

    // Begin Clay layout
    clay.Clay_BeginLayout();

    // Build Clay hierarchy from collected calls
    var i: usize = 0;
    while (i < self.widget_calls.items.len) : (i += 1) {
        const call = self.widget_calls.items[i];
        switch (call) {
            .label => |lbl| buildClayLabel(lbl),
            .button => |btn| buildClayButton(btn),
            .progress_bar => |bar| buildClayProgressBar(bar),
            .panel_begin => |panel| buildClayPanelBegin(panel),
            .panel_end => buildClayPanelEnd(),
            .image => |img| buildClayImage(img),
            .checkbox => |cb| buildClayCheckbox(cb),
            .slider => |sl| buildClaySlider(sl),
        }
    }

    // Finalize Clay layout and get render commands
    const render_commands = clay.Clay_EndLayout();

    // Process render commands through renderer
    renderer.processRenderCommands(render_commands);
}

pub fn label(self: *Self, lbl: types.Label) void {
    self.widget_calls.append(.{ .label = lbl }) catch {
        std.debug.print("Failed to append label widget call\n", .{});
    };
}

pub fn button(self: *Self, btn: types.Button) bool {
    self.widget_calls.append(.{ .button = btn }) catch {
        std.debug.print("Failed to append button widget call\n", .{});
    };
    // TODO: Return actual click state from Clay pointer state
    return false;
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    self.widget_calls.append(.{ .progress_bar = bar }) catch {
        std.debug.print("Failed to append progress bar widget call\n", .{});
    };
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    self.widget_calls.append(.{ .panel_begin = panel }) catch {
        std.debug.print("Failed to append panel begin widget call\n", .{});
    };
}

pub fn endPanel(self: *Self) void {
    self.widget_calls.append(.{ .panel_end = {} }) catch {
        std.debug.print("Failed to append panel end widget call\n", .{});
    };
}

pub fn image(self: *Self, img: types.Image) void {
    self.widget_calls.append(.{ .image = img }) catch {
        std.debug.print("Failed to append image widget call\n", .{});
    };
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    self.widget_calls.append(.{ .checkbox = cb }) catch {
        std.debug.print("Failed to append checkbox widget call\n", .{});
    };
    // TODO: Return actual checked state from Clay pointer state
    return cb.checked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    self.widget_calls.append(.{ .slider = sl }) catch {
        std.debug.print("Failed to append slider widget call\n", .{});
    };
    // TODO: Return actual value from Clay pointer state
    return sl.value;
}

// ============================================================================
// Clay Element Builders
// ============================================================================

fn buildClayLabel(lbl: types.Label) void {
    // Convert labelle color to Clay color
    const color = clay.Clay_Color{
        .r = @floatFromInt(lbl.color.r),
        .g = @floatFromInt(lbl.color.g),
        .b = @floatFromInt(lbl.color.b),
        .a = @floatFromInt(lbl.color.a),
    };

    // Create text config
    const text_config = clay.Clay_TextElementConfig{
        .textColor = color,
        .fontSize = @intFromFloat(lbl.font_size),
        .letterSpacing = 0,
        .lineSpacing = 0,
        .wrapMode = clay.CLAY_TEXT_WRAP_WORDS,
    };

    // Create layout config for positioning
    const layout_config = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_GROW({}),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIT({}),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_LEFT,
            .y = clay.CLAY_ALIGN_Y_TOP,
        },
        .layoutDirection = clay.CLAY_TOP_TO_BOTTOM,
    };

    // Build Clay UI element
    const id = if (lbl.id.len > 0) clay.Clay_IDFromString(lbl.id) else clay.CLAY_ID_NULL;
    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachId(id);
    _ = clay.Clay_AttachLayoutConfig(&layout_config);

    // Add text
    const text_str = clay.Clay_String{ .length = lbl.text.len, .chars = lbl.text.ptr };
    _ = clay.Clay_Text(text_str, &text_config);

    clay.Clay_CloseElement();
}

fn buildClayButton(btn: types.Button) void {
    const bg_color = clay.Clay_Color{ .r = 100, .g = 100, .b = 200, .a = 255 };
    const text_color = clay.Clay_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

    const layout_config = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(btn.size.width)),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(btn.size.height)),
        },
        .padding = clay.Clay_Padding{ .x = 10, .y = 5 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_CENTER,
            .y = clay.CLAY_ALIGN_Y_CENTER,
        },
        .layoutDirection = clay.CLAY_TOP_TO_BOTTOM,
    };

    const rectangle_config = clay.Clay_RectangleElementConfig{
        .color = bg_color,
        .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 4, .topRight = 4, .bottomLeft = 4, .bottomRight = 4 },
        .link = null,
    };

    const text_config = clay.Clay_TextElementConfig{
        .textColor = text_color,
        .fontSize = 16,
        .letterSpacing = 0,
        .lineSpacing = 0,
        .wrapMode = clay.CLAY_TEXT_WRAP_WORDS,
    };

    const id = if (btn.id.len > 0) clay.Clay_IDFromString(btn.id) else clay.CLAY_ID_NULL;
    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachId(id);
    _ = clay.Clay_AttachLayoutConfig(&layout_config);
    _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &rectangle_config }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);

    const text_str = clay.Clay_String{ .length = btn.text.len, .chars = btn.text.ptr };
    _ = clay.Clay_Text(text_str, &text_config);

    clay.Clay_CloseElement();
}

fn buildClayProgressBar(bar: types.ProgressBar) void {
    const bg_color = clay.Clay_Color{ .r = 50, .g = 50, .b = 50, .a = 255 };
    const fill_color = clay.Clay_Color{
        .r = @floatFromInt(bar.color.r),
        .g = @floatFromInt(bar.color.g),
        .b = @floatFromInt(bar.color.b),
        .a = @floatFromInt(bar.color.a),
    };

    // Background container
    const bg_layout = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(bar.size.width)),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(bar.size.height)),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_LEFT,
            .y = clay.CLAY_ALIGN_Y_CENTER,
        },
        .layoutDirection = clay.CLAY_LEFT_TO_RIGHT,
    };

    const bg_rect = clay.Clay_RectangleElementConfig{
        .color = bg_color,
        .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 2, .topRight = 2, .bottomLeft = 2, .bottomRight = 2 },
        .link = null,
    };

    const id = if (bar.id.len > 0) clay.Clay_IDFromString(bar.id) else clay.CLAY_ID_NULL;
    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachId(id);
    _ = clay.Clay_AttachLayoutConfig(&bg_layout);
    _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &bg_rect }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);

    // Fill bar (based on value 0.0 to 1.0)
    const fill_width = bar.size.width * bar.value;
    if (fill_width > 0) {
        const fill_layout = clay.Clay_LayoutConfig{
            .sizing = .{
                .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(fill_width)),
                .height = clay.Clay_SizingAxis.CLAY_SIZING_GROW({}),
            },
            .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
            .childGap = 0,
            .childAlignment = .{
                .x = clay.CLAY_ALIGN_X_LEFT,
                .y = clay.CLAY_ALIGN_Y_CENTER,
            },
            .layoutDirection = clay.CLAY_TOP_TO_BOTTOM,
        };

        const fill_rect = clay.Clay_RectangleElementConfig{
            .color = fill_color,
            .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 2, .topRight = 2, .bottomLeft = 2, .bottomRight = 2 },
            .link = null,
        };

        _ = clay.Clay_OpenElement();
        _ = clay.Clay_AttachLayoutConfig(&fill_layout);
        _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &fill_rect }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);
        clay.Clay_CloseElement();
    }

    clay.Clay_CloseElement();
}

fn buildClayPanelBegin(panel: types.Panel) void {
    const bg_color = clay.Clay_Color{
        .r = @floatFromInt(panel.background_color.r),
        .g = @floatFromInt(panel.background_color.g),
        .b = @floatFromInt(panel.background_color.b),
        .a = @floatFromInt(panel.background_color.a),
    };

    const layout_config = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(panel.size.width)),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(panel.size.height)),
        },
        .padding = clay.Clay_Padding{ .x = 10, .y = 10 },
        .childGap = 5,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_LEFT,
            .y = clay.CLAY_ALIGN_Y_TOP,
        },
        .layoutDirection = clay.CLAY_TOP_TO_BOTTOM,
    };

    const rectangle_config = clay.Clay_RectangleElementConfig{
        .color = bg_color,
        .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 8, .topRight = 8, .bottomLeft = 8, .bottomRight = 8 },
        .link = null,
    };

    const id = if (panel.id.len > 0) clay.Clay_IDFromString(panel.id) else clay.CLAY_ID_NULL;
    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachId(id);
    _ = clay.Clay_AttachLayoutConfig(&layout_config);
    _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &rectangle_config }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);

    // Note: Clay_CloseElement() will be called by buildClayPanelEnd()
}

fn buildClayPanelEnd() void {
    clay.Clay_CloseElement();
}

fn buildClayImage(img: types.Image) void {
    // For now, just create a placeholder rectangle
    // TODO: Implement actual image rendering with texture IDs
    const placeholder_color = clay.Clay_Color{ .r = 128, .g = 128, .b = 128, .a = 255 };

    const width: f32 = if (img.size) |s| @floatCast(s.width) else 100;
    const height: f32 = if (img.size) |s| @floatCast(s.height) else 100;

    const layout_config = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(width),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(height),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_LEFT,
            .y = clay.CLAY_ALIGN_Y_TOP,
        },
        .layoutDirection = clay.CLAY_TOP_TO_BOTTOM,
    };

    const rectangle_config = clay.Clay_RectangleElementConfig{
        .color = placeholder_color,
        .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 0, .topRight = 0, .bottomLeft = 0, .bottomRight = 0 },
        .link = null,
    };

    const id = if (img.id.len > 0) clay.Clay_IDFromString(img.id) else clay.CLAY_ID_NULL;
    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachId(id);
    _ = clay.Clay_AttachLayoutConfig(&layout_config);
    _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &rectangle_config }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);
    clay.Clay_CloseElement();
}

fn buildClayCheckbox(cb: types.Checkbox) void {
    const box_size: f32 = 20;
    const bg_color = clay.Clay_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const check_color = clay.Clay_Color{ .r = 0, .g = 200, .b = 0, .a = 255 };
    const text_color = clay.Clay_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

    // Container for checkbox + label
    const container_layout = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_GROW({}),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIT({}),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 10,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_LEFT,
            .y = clay.CLAY_ALIGN_Y_CENTER,
        },
        .layoutDirection = clay.CLAY_LEFT_TO_RIGHT,
    };

    const id = if (cb.id.len > 0) clay.Clay_IDFromString(cb.id) else clay.CLAY_ID_NULL;
    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachId(id);
    _ = clay.Clay_AttachLayoutConfig(&container_layout);

    // Checkbox box
    const box_layout = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(box_size),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(box_size),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_CENTER,
            .y = clay.CLAY_ALIGN_Y_CENTER,
        },
        .layoutDirection = clay.CLAY_TOP_TO_BOTTOM,
    };

    const box_rect = clay.Clay_RectangleElementConfig{
        .color = if (cb.checked) check_color else bg_color,
        .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 2, .topRight = 2, .bottomLeft = 2, .bottomRight = 2 },
        .link = null,
    };

    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachLayoutConfig(&box_layout);
    _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &box_rect }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);
    clay.Clay_CloseElement();

    // Label text
    if (cb.text.len > 0) {
        const text_config = clay.Clay_TextElementConfig{
            .textColor = text_color,
            .fontSize = 16,
            .letterSpacing = 0,
            .lineSpacing = 0,
            .wrapMode = clay.CLAY_TEXT_WRAP_WORDS,
        };

        const text_str = clay.Clay_String{ .length = cb.text.len, .chars = cb.text.ptr };
        _ = clay.Clay_Text(text_str, &text_config);
    }

    clay.Clay_CloseElement();
}

fn buildClaySlider(sl: types.Slider) void {
    const track_color = clay.Clay_Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const thumb_color = clay.Clay_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };

    const track_height: f32 = 4;
    const thumb_size: f32 = 16;

    // Container
    const container_layout = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(sl.size.width)),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(@floatCast(sl.size.height)),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_LEFT,
            .y = clay.CLAY_ALIGN_Y_CENTER,
        },
        .layoutDirection = clay.CLAY_LEFT_TO_RIGHT,
    };

    const id = if (sl.id.len > 0) clay.Clay_IDFromString(sl.id) else clay.CLAY_ID_NULL;
    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachId(id);
    _ = clay.Clay_AttachLayoutConfig(&container_layout);

    // Track
    const track_layout = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_GROW({}),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(track_height),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_LEFT,
            .y = clay.CLAY_ALIGN_Y_CENTER,
        },
        .layoutDirection = clay.CLAY_LEFT_TO_RIGHT,
    };

    const track_rect = clay.Clay_RectangleElementConfig{
        .color = track_color,
        .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 2, .topRight = 2, .bottomLeft = 2, .bottomRight = 2 },
        .link = null,
    };

    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachLayoutConfig(&track_layout);
    _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &track_rect }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);
    clay.Clay_CloseElement();

    // Thumb (positioned based on value)
    const normalized = (sl.value - sl.min) / (sl.max - sl.min);
    const thumb_offset = normalized * (sl.size.width - thumb_size);

    const thumb_layout = clay.Clay_LayoutConfig{
        .sizing = .{
            .width = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(thumb_size),
            .height = clay.Clay_SizingAxis.CLAY_SIZING_FIXED(thumb_size),
        },
        .padding = clay.Clay_Padding{ .x = 0, .y = 0 },
        .childGap = 0,
        .childAlignment = .{
            .x = clay.CLAY_ALIGN_X_CENTER,
            .y = clay.CLAY_ALIGN_Y_CENTER,
        },
        .layoutDirection = clay.CLAY_TOP_TO_BOTTOM,
    };

    _ = thumb_offset; // TODO: Use this for positioning

    const thumb_rect = clay.Clay_RectangleElementConfig{
        .color = thumb_color,
        .cornerRadius = clay.Clay_CornerRadius{ .topLeft = 8, .topRight = 8, .bottomLeft = 8, .bottomRight = 8 },
        .link = null,
    };

    _ = clay.Clay_OpenElement();
    _ = clay.Clay_AttachLayoutConfig(&thumb_layout);
    _ = clay.Clay_AttachElementConfig(.{ .rectangleElementConfig = &thumb_rect }, clay.CLAY__ELEMENT_CONFIG_TYPE_RECTANGLE);
    clay.Clay_CloseElement();

    clay.Clay_CloseElement();
}

// ============================================================================
// Clay Callbacks
// ============================================================================

fn errorHandler(error_data: clay.Clay_ErrorData) callconv(.C) void {
    std.debug.print("Clay Error: {s}\n", .{error_data.errorText.chars[0..error_data.errorText.length]});
}

fn measureTextCallback(
    text: *clay.Clay_String,
    config: *clay.Clay_TextElementConfig,
    userData: ?*anyopaque,
) callconv(.C) clay.Clay_Dimensions {
    _ = userData;

    // Create a null-terminated buffer for raylib
    const max_len = @min(text.length, 4096);
    var buf: [4096:0]u8 = undefined;
    @memcpy(buf[0..max_len], text.chars[0..max_len]);
    buf[max_len] = 0;

    // Measure using raylib
    const text_width = rl.measureText(&buf, @intCast(config.fontSize));
    const text_height = config.fontSize;

    return .{
        .width = @floatFromInt(text_width),
        .height = @floatFromInt(text_height),
    };
}
