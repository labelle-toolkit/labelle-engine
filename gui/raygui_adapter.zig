//! Raygui Adapter
//!
//! GUI backend using raylib's drawing primitives.
//! Renders basic GUI elements without external dependencies.

const std = @import("std");
const rl = @import("raylib");
const types = @import("types.zig");

const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn beginFrame(self: *Self) void {
    _ = self;
}

pub fn endFrame(self: *Self) void {
    _ = self;
}

pub fn label(self: *Self, lbl: types.Label) void {
    _ = self;
    // Text from .zon literals is null-terminated
    const text: [:0]const u8 = @ptrCast(lbl.text[0..lbl.text.len :0]);
    rl.drawText(
        text,
        @intFromFloat(lbl.position.x),
        @intFromFloat(lbl.position.y),
        @intFromFloat(lbl.font_size),
        toRaylibColor(lbl.color),
    );
}

pub fn button(self: *Self, btn: types.Button) bool {
    _ = self;
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
    const bg_color: rl.Color = if (hover)
        .{ .r = 100, .g = 100, .b = 100, .a = 255 }
    else
        .{ .r = 80, .g = 80, .b = 80, .a = 255 };
    rl.drawRectangleRec(rect, bg_color);

    // Draw border
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 200, .g = 200, .b = 200, .a = 255 });

    // Draw text centered
    const font_size: i32 = 16;
    const text: [:0]const u8 = @ptrCast(btn.text[0..btn.text.len :0]);
    const text_width = rl.measureText(text, font_size);
    const text_x = @as(i32, @intFromFloat(btn.position.x + btn.size.width / 2)) - @divFloor(text_width, 2);
    const text_y = @as(i32, @intFromFloat(btn.position.y + btn.size.height / 2)) - @divFloor(font_size, 2);
    rl.drawText(text, text_x, text_y, font_size, rl.Color.white);

    return clicked;
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    _ = self;
    const rect = rl.Rectangle{
        .x = bar.position.x,
        .y = bar.position.y,
        .width = bar.size.width,
        .height = bar.size.height,
    };

    // Background
    rl.drawRectangleRec(rect, .{ .r = 40, .g = 40, .b = 40, .a = 255 });

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
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 150, .g = 150, .b = 150, .a = 255 });
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    _ = self;
    const rect = rl.Rectangle{
        .x = panel.position.x,
        .y = panel.position.y,
        .width = panel.size.width,
        .height = panel.size.height,
    };
    rl.drawRectangleRec(rect, toRaylibColor(panel.background_color));
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 100, .g = 100, .b = 100, .a = 255 });
}

pub fn endPanel(self: *Self) void {
    _ = self;
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
    // TODO: Image rendering requires texture loading integration
    // For now, draw a placeholder rectangle
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    _ = self;
    const box_size: f32 = 20;
    const rect = rl.Rectangle{
        .x = cb.position.x,
        .y = cb.position.y,
        .width = box_size,
        .height = box_size,
    };

    const mouse_pos = rl.getMousePosition();
    const hover = rl.checkCollisionPointRec(mouse_pos, rect);
    const clicked = hover and rl.isMouseButtonPressed(.left);

    // Draw checkbox background
    const bg_color: rl.Color = if (hover)
        .{ .r = 80, .g = 80, .b = 80, .a = 255 }
    else
        .{ .r = 60, .g = 60, .b = 60, .a = 255 };
    rl.drawRectangleRec(rect, bg_color);
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 150, .g = 150, .b = 150, .a = 255 });

    // Draw checkmark if checked
    if (cb.checked) {
        const padding: f32 = 4;
        const inner_rect = rl.Rectangle{
            .x = cb.position.x + padding,
            .y = cb.position.y + padding,
            .width = box_size - padding * 2,
            .height = box_size - padding * 2,
        };
        rl.drawRectangleRec(inner_rect, .{ .r = 0, .g = 200, .b = 0, .a = 255 });
    }

    // Draw label
    if (cb.text.len > 0) {
        const text: [:0]const u8 = @ptrCast(cb.text[0..cb.text.len :0]);
        rl.drawText(
            text,
            @intFromFloat(cb.position.x + box_size + 8),
            @intFromFloat(cb.position.y + 2),
            16,
            rl.Color.white,
        );
    }

    return clicked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    _ = self;
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
    rl.drawRectangleRec(rect, .{ .r = 40, .g = 40, .b = 40, .a = 255 });

    // Draw filled portion (handle division by zero when min == max)
    const normalized_value = if (has_range) (current_value - sl.min) / range else 0;
    const fill_width = sl.size.width * normalized_value;
    if (fill_width > 0) {
        rl.drawRectangle(
            @intFromFloat(sl.position.x),
            @intFromFloat(sl.position.y),
            @intFromFloat(fill_width),
            @intFromFloat(sl.size.height),
            .{ .r = 0, .g = 150, .b = 200, .a = 255 },
        );
    }

    // Draw border
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 150, .g = 150, .b = 150, .a = 255 });

    // Draw handle
    const handle_x = sl.position.x + fill_width - 4;
    const handle_rect = rl.Rectangle{
        .x = @max(sl.position.x, handle_x),
        .y = sl.position.y - 2,
        .width = 8,
        .height = sl.size.height + 4,
    };
    const handle_color: rl.Color = if (hover or dragging)
        .{ .r = 255, .g = 255, .b = 255, .a = 255 }
    else
        .{ .r = 200, .g = 200, .b = 200, .a = 255 };
    rl.drawRectangleRec(handle_rect, handle_color);

    return current_value;
}

/// Convert GUI color to raylib color
fn toRaylibColor(color: types.Color) rl.Color {
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    };
}
