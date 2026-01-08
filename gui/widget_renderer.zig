//! Widget Renderer
//!
//! Shared raylib-based widget rendering functions used by all GUI backends.
//! This eliminates code duplication between adapters and provides a single
//! place to maintain widget appearance and behavior.

const std = @import("std");
const rl = @import("raylib");
const types = @import("types.zig");

// Configuration constants
pub const DEFAULT_FONT_SIZE: c_int = 16;
pub const CHECKBOX_SIZE: f32 = 20;
pub const CHECKBOX_PADDING: f32 = 4;
pub const CHECKBOX_LABEL_OFFSET: f32 = 8;
pub const SLIDER_HANDLE_WIDTH: c_int = 8;
pub const SLIDER_HANDLE_OVERFLOW: f32 = 2;
pub const TEXT_BUFFER_SIZE: usize = 4096;

// Color constants for consistent styling
pub const Colors = struct {
    pub const button_bg = rl.Color{ .r = 80, .g = 80, .b = 80, .a = 255 };
    pub const button_bg_hover = rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
    pub const button_border = rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 };

    pub const checkbox_bg = rl.Color{ .r = 60, .g = 60, .b = 60, .a = 255 };
    pub const checkbox_bg_hover = rl.Color{ .r = 80, .g = 80, .b = 80, .a = 255 };
    pub const checkbox_border = rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 };
    pub const checkbox_check = rl.Color{ .r = 0, .g = 200, .b = 0, .a = 255 };

    pub const slider_track = rl.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };
    pub const slider_fill = rl.Color{ .r = 0, .g = 150, .b = 200, .a = 255 };
    pub const slider_border = rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 };
    pub const slider_handle = rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
    pub const slider_handle_active = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

    pub const progress_bg = rl.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };
    pub const progress_border = rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 };

    pub const panel_border = rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
};

/// Convert GUI color to raylib color
pub fn toRaylibColor(color: types.Color) rl.Color {
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    };
}

/// Helper to safely convert a Zig slice to a null-terminated buffer for raylib.
/// Returns a sentinel-terminated slice pointing into the provided buffer.
pub fn toNullTerminated(text: []const u8, buf: *[TEXT_BUFFER_SIZE]u8) [:0]const u8 {
    const copy_len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..copy_len], text[0..copy_len]);
    buf[copy_len] = 0;
    return buf[0..copy_len :0];
}

/// Draw a text label
pub fn drawLabel(lbl: types.Label) void {
    var buf: [TEXT_BUFFER_SIZE]u8 = undefined;
    const text_z = toNullTerminated(lbl.text, &buf);
    rl.drawText(
        text_z,
        @intFromFloat(lbl.position.x),
        @intFromFloat(lbl.position.y),
        @intFromFloat(lbl.font_size),
        toRaylibColor(lbl.color),
    );
}

/// Draw a button and return true if clicked
pub fn drawButton(btn: types.Button) bool {
    const rect = rl.Rectangle{
        .x = btn.position.x,
        .y = btn.position.y,
        .width = btn.size.width,
        .height = btn.size.height,
    };

    const mouse_pos = rl.getMousePosition();
    const hover = rl.checkCollisionPointRec(mouse_pos, rect);
    const clicked = hover and rl.isMouseButtonPressed(.left);

    // Draw button background
    const bg_color = if (hover) Colors.button_bg_hover else Colors.button_bg;
    rl.drawRectangleRec(rect, bg_color);

    // Draw border
    rl.drawRectangleLinesEx(rect, 1, Colors.button_border);

    // Draw text centered
    var buf: [TEXT_BUFFER_SIZE]u8 = undefined;
    const text_z = toNullTerminated(btn.text, &buf);
    const text_width = rl.measureText(text_z, DEFAULT_FONT_SIZE);
    const text_x = @as(i32, @intFromFloat(btn.position.x + btn.size.width / 2)) - @divFloor(text_width, 2);
    const text_y = @as(i32, @intFromFloat(btn.position.y + btn.size.height / 2)) - @divFloor(DEFAULT_FONT_SIZE, 2);
    rl.drawText(text_z, text_x, text_y, DEFAULT_FONT_SIZE, rl.Color.white);

    return clicked;
}

/// Draw a progress bar
pub fn drawProgressBar(bar: types.ProgressBar) void {
    const rect = rl.Rectangle{
        .x = bar.position.x,
        .y = bar.position.y,
        .width = bar.size.width,
        .height = bar.size.height,
    };

    // Background
    rl.drawRectangleRec(rect, Colors.progress_bg);

    // Fill
    const clamped_value = std.math.clamp(bar.value, 0, 1);
    const fill_width = bar.size.width * clamped_value;
    if (fill_width > 0) {
        rl.drawRectangle(
            @intFromFloat(bar.position.x),
            @intFromFloat(bar.position.y),
            @intFromFloat(fill_width),
            @intFromFloat(bar.size.height),
            toRaylibColor(bar.color),
        );
    }

    // Border
    rl.drawRectangleLinesEx(rect, 1, Colors.progress_border);
}

/// Draw a panel background
pub fn drawPanel(panel: types.Panel) void {
    const rect = rl.Rectangle{
        .x = panel.position.x,
        .y = panel.position.y,
        .width = panel.size.width,
        .height = panel.size.height,
    };
    rl.drawRectangleRec(rect, toRaylibColor(panel.background_color));
    rl.drawRectangleLinesEx(rect, 1, Colors.panel_border);
}

/// Draw an image placeholder (actual image rendering requires texture integration)
pub fn drawImage(img: types.Image) void {
    if (img.size) |size| {
        const x: c_int = @intFromFloat(img.position.x);
        const y: c_int = @intFromFloat(img.position.y);
        const w: c_int = @intFromFloat(size.width);
        const h: c_int = @intFromFloat(size.height);
        rl.drawRectangle(x, y, w, h, toRaylibColor(img.tint));
    }
}

/// Draw a checkbox and return true if clicked
pub fn drawCheckbox(cb: types.Checkbox) bool {
    const rect = rl.Rectangle{
        .x = cb.position.x,
        .y = cb.position.y,
        .width = CHECKBOX_SIZE,
        .height = CHECKBOX_SIZE,
    };

    const mouse_pos = rl.getMousePosition();
    const hover = rl.checkCollisionPointRec(mouse_pos, rect);
    const clicked = hover and rl.isMouseButtonPressed(.left);

    // Draw checkbox background
    const bg_color = if (hover) Colors.checkbox_bg_hover else Colors.checkbox_bg;
    rl.drawRectangleRec(rect, bg_color);
    rl.drawRectangleLinesEx(rect, 1, Colors.checkbox_border);

    // Draw checkmark if checked
    if (cb.checked) {
        const inner_rect = rl.Rectangle{
            .x = cb.position.x + CHECKBOX_PADDING,
            .y = cb.position.y + CHECKBOX_PADDING,
            .width = CHECKBOX_SIZE - CHECKBOX_PADDING * 2,
            .height = CHECKBOX_SIZE - CHECKBOX_PADDING * 2,
        };
        rl.drawRectangleRec(inner_rect, Colors.checkbox_check);
    }

    // Draw label
    if (cb.text.len > 0) {
        var buf: [TEXT_BUFFER_SIZE]u8 = undefined;
        const text_z = toNullTerminated(cb.text, &buf);
        rl.drawText(
            text_z,
            @intFromFloat(cb.position.x + CHECKBOX_SIZE + CHECKBOX_LABEL_OFFSET),
            @intFromFloat(cb.position.y + 2),
            DEFAULT_FONT_SIZE,
            rl.Color.white,
        );
    }

    return clicked;
}

/// Draw a slider and return the new value
pub fn drawSlider(sl: types.Slider) f32 {
    const rect = rl.Rectangle{
        .x = sl.position.x,
        .y = sl.position.y,
        .width = sl.size.width,
        .height = sl.size.height,
    };

    const mouse_pos = rl.getMousePosition();
    const hover = rl.checkCollisionPointRec(mouse_pos, rect);
    const dragging = hover and rl.isMouseButtonDown(.left);

    // Calculate range (guard against division by zero)
    const range = sl.max - sl.min;
    const has_range = range > 0;
    const has_width = sl.size.width > 0;

    // Calculate new value if dragging
    var current_value = sl.value;
    if (dragging and has_range and has_width) {
        const relative_x = mouse_pos.x - sl.position.x;
        const normalized = std.math.clamp(relative_x / sl.size.width, 0, 1);
        current_value = sl.min + normalized * range;
    }

    // Draw track background
    rl.drawRectangleRec(rect, Colors.slider_track);

    // Draw filled portion (handle division by zero when min == max)
    const normalized_value = if (has_range) (current_value - sl.min) / range else 0;
    const fill_width = sl.size.width * normalized_value;
    if (fill_width > 0) {
        rl.drawRectangle(
            @intFromFloat(sl.position.x),
            @intFromFloat(sl.position.y),
            @intFromFloat(fill_width),
            @intFromFloat(sl.size.height),
            Colors.slider_fill,
        );
    }

    // Draw border
    rl.drawRectangleLinesEx(rect, 1, Colors.slider_border);

    // Draw handle
    const handle_x = sl.position.x + fill_width - @as(f32, @floatFromInt(@divFloor(SLIDER_HANDLE_WIDTH, 2)));
    const handle_rect = rl.Rectangle{
        .x = @max(sl.position.x, handle_x),
        .y = sl.position.y - SLIDER_HANDLE_OVERFLOW,
        .width = @floatFromInt(SLIDER_HANDLE_WIDTH),
        .height = sl.size.height + SLIDER_HANDLE_OVERFLOW * 2,
    };
    const handle_color = if (hover or dragging) Colors.slider_handle_active else Colors.slider_handle;
    rl.drawRectangleRec(handle_rect, handle_color);

    return current_value;
}
