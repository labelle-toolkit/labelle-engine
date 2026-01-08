//! microui Adapter
//!
//! GUI backend using microui for input handling and raylib for rendering.
//! microui's command buffer has alignment issues when compiled with Zig,
//! so we render widgets directly with raylib instead of using microui's
//! native widget functions.
//!
//! Build with: zig build -Dgui_backend=microui

const std = @import("std");
const rl = @import("raylib");
const types = @import("types.zig");

const Self = @This();

pub fn init() Self {
    return Self{};
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
    const text_z: [:0]const u8 = @ptrCast(lbl.text);
    rl.drawText(
        text_z,
        @intFromFloat(lbl.position.x),
        @intFromFloat(lbl.position.y),
        @intFromFloat(lbl.font_size),
        rl.Color{ .r = lbl.color.r, .g = lbl.color.g, .b = lbl.color.b, .a = lbl.color.a },
    );
}

pub fn button(self: *Self, btn: types.Button) bool {
    _ = self;

    const x: c_int = @intFromFloat(btn.position.x);
    const y: c_int = @intFromFloat(btn.position.y);
    const w: c_int = @intFromFloat(btn.size.width);
    const h: c_int = @intFromFloat(btn.size.height);

    const mouse_pos = rl.getMousePosition();
    const rect = rl.Rectangle{
        .x = btn.position.x,
        .y = btn.position.y,
        .width = btn.size.width,
        .height = btn.size.height,
    };

    const hover = rl.checkCollisionPointRec(mouse_pos, rect);
    const clicked = hover and rl.isMouseButtonPressed(.left);

    // Draw button
    const bg_color = if (hover) rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 } else rl.Color{ .r = 75, .g = 75, .b = 75, .a = 255 };
    rl.drawRectangle(x, y, w, h, bg_color);
    rl.drawRectangleLines(x, y, w, h, rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 });

    // Draw text centered
    const text_z: [:0]const u8 = @ptrCast(btn.text);
    const text_width = rl.measureText(text_z, 16);
    const text_x = x + @divTrunc(w, 2) - @divTrunc(text_width, 2);
    const text_y = y + @divTrunc(h, 2) - 8;
    rl.drawText(text_z, text_x, text_y, 16, rl.Color.white);

    return clicked;
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    _ = self;

    const x: c_int = @intFromFloat(bar.position.x);
    const y: c_int = @intFromFloat(bar.position.y);
    const w: c_int = @intFromFloat(bar.size.width);
    const h: c_int = @intFromFloat(bar.size.height);

    // Background
    rl.drawRectangle(x, y, w, h, rl.Color{ .r = 40, .g = 40, .b = 40, .a = 255 });

    // Fill
    const fill_width: c_int = @intFromFloat(bar.size.width * std.math.clamp(bar.value, 0, 1));
    rl.drawRectangle(x, y, fill_width, h, rl.Color{ .r = bar.color.r, .g = bar.color.g, .b = bar.color.b, .a = bar.color.a });

    // Border
    rl.drawRectangleLines(x, y, w, h, rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    _ = self;

    const x: c_int = @intFromFloat(panel.position.x);
    const y: c_int = @intFromFloat(panel.position.y);
    const w: c_int = @intFromFloat(panel.size.width);
    const h: c_int = @intFromFloat(panel.size.height);

    // Draw panel background
    rl.drawRectangle(x, y, w, h, rl.Color{
        .r = panel.background_color.r,
        .g = panel.background_color.g,
        .b = panel.background_color.b,
        .a = panel.background_color.a,
    });
}

pub fn endPanel(self: *Self) void {
    _ = self;
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    // Image rendering would require texture loading - not implemented
    // For now, draw a placeholder rectangle
    if (img.size) |size| {
        const x: c_int = @intFromFloat(img.position.x);
        const y: c_int = @intFromFloat(img.position.y);
        const w: c_int = @intFromFloat(size.width);
        const h: c_int = @intFromFloat(size.height);
        rl.drawRectangle(x, y, w, h, rl.Color{ .r = img.tint.r, .g = img.tint.g, .b = img.tint.b, .a = img.tint.a });
    }
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    _ = self;

    const x: c_int = @intFromFloat(cb.position.x);
    const y: c_int = @intFromFloat(cb.position.y);
    const size: c_int = 16;

    // Check box area
    const box_rect = rl.Rectangle{
        .x = cb.position.x,
        .y = cb.position.y,
        .width = @floatFromInt(size),
        .height = @floatFromInt(size),
    };

    const mouse_pos = rl.getMousePosition();
    const hover = rl.checkCollisionPointRec(mouse_pos, box_rect);
    const clicked = hover and rl.isMouseButtonPressed(.left);

    // Draw checkbox
    const bg_color = if (hover) rl.Color{ .r = 80, .g = 80, .b = 80, .a = 255 } else rl.Color{ .r = 60, .g = 60, .b = 60, .a = 255 };
    rl.drawRectangle(x, y, size, size, bg_color);
    rl.drawRectangleLines(x, y, size, size, rl.Color{ .r = 180, .g = 180, .b = 180, .a = 255 });

    // Draw check mark if checked
    if (cb.checked) {
        rl.drawLine(x + 3, y + 8, x + 6, y + 12, rl.Color.white);
        rl.drawLine(x + 6, y + 12, x + 13, y + 3, rl.Color.white);
    }

    // Draw label
    const text_z: [:0]const u8 = @ptrCast(cb.text);
    rl.drawText(text_z, x + size + 6, y + 1, 16, rl.Color.white);

    return clicked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    _ = self;

    const x: c_int = @intFromFloat(sl.position.x);
    const y: c_int = @intFromFloat(sl.position.y);
    const w: c_int = @intFromFloat(sl.size.width);
    const h: c_int = @intFromFloat(sl.size.height);

    // Slider track
    const track_rect = rl.Rectangle{
        .x = sl.position.x,
        .y = sl.position.y,
        .width = sl.size.width,
        .height = sl.size.height,
    };

    const mouse_pos = rl.getMousePosition();
    const hover = rl.checkCollisionPointRec(mouse_pos, track_rect);

    // Draw track
    rl.drawRectangle(x, y, w, h, rl.Color{ .r = 50, .g = 50, .b = 50, .a = 255 });

    // Calculate thumb position
    const range = sl.max - sl.min;
    const normalized = if (range > 0) (sl.value - sl.min) / range else 0;
    const thumb_w: c_int = 10;
    const usable_width = if (sl.size.width > 10) sl.size.width - 10 else 0;
    const thumb_x: c_int = x + @as(c_int, @intFromFloat(normalized * usable_width));

    // Handle input
    var new_value = sl.value;
    if (hover and rl.isMouseButtonDown(.left)) {
        const relative_x = mouse_pos.x - sl.position.x;
        const new_normalized = std.math.clamp(relative_x / sl.size.width, 0, 1);
        new_value = sl.min + new_normalized * range;
    }

    // Draw thumb
    rl.drawRectangle(thumb_x, y, thumb_w, h, rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });

    // Border
    rl.drawRectangleLines(x, y, w, h, rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 });

    return new_value;
}
