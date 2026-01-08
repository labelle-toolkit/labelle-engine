//! microui Adapter
//!
//! GUI backend using microui - a tiny immediate-mode UI library (~1000 LOC).
//! microui generates draw commands that we render using raylib primitives.
//!
//! Build with: zig build -Dgui_backend=microui

const std = @import("std");
const rl = @import("raylib");
const types = @import("types.zig");

// Import microui C library
const mu = @cImport({
    @cInclude("microui.h");
});

const Self = @This();

// microui context
ctx: mu.mu_Context,

// Text width callback for microui (uses raylib's default font)
// mu_Font is typedef'd to void*, so we use ?*anyopaque
fn textWidth(_: ?*anyopaque, text: [*c]const u8, len: c_int) callconv(.c) c_int {
    if (len == -1) {
        // Null-terminated string - convert C string to sentinel-terminated slice
        const text_slice: [:0]const u8 = std.mem.span(text);
        return @intCast(rl.measureText(text_slice, 16));
    } else {
        // Use a temporary buffer for non-null-terminated strings
        var buf: [256]u8 = undefined;
        const actual_len: usize = @intCast(len);
        const copy_len = @min(actual_len, buf.len - 1);
        @memcpy(buf[0..copy_len], text[0..copy_len]);
        buf[copy_len] = 0;
        const sentinel_buf: [:0]const u8 = buf[0..copy_len :0];
        return @intCast(rl.measureText(sentinel_buf, 16));
    }
}

// Text height callback for microui
fn textHeight(_: ?*anyopaque) callconv(.c) c_int {
    return 16; // Default font height
}

pub fn init() Self {
    // Just return with undefined context - it will be properly initialized
    // in fixPointers() after the struct is in its final memory location.
    // This avoids issues with self-referential pointers being invalidated
    // when the struct is copied on return.
    return Self{
        .ctx = undefined,
    };
}

/// Initialize the microui context after the struct is in its final memory location.
/// mu_Context has internal self-referential pointers (style -> _style) that become
/// invalid when the struct is copied. By initializing here, we ensure all pointers
/// are valid.
pub fn fixPointers(self: *Self) void {
    // Initialize microui context now that we're in our final location
    mu.mu_init(&self.ctx);
    self.ctx.text_width = textWidth;
    self.ctx.text_height = textHeight;
}

pub fn deinit(self: *Self) void {
    _ = self;
    // microui doesn't require explicit cleanup
}

pub fn beginFrame(self: *Self) void {
    // Forward input to microui

    // Mouse position
    const mouse_pos = rl.getMousePosition();
    mu.mu_input_mousemove(&self.ctx, @intFromFloat(mouse_pos.x), @intFromFloat(mouse_pos.y));

    // Mouse scroll
    const scroll = rl.getMouseWheelMoveV();
    mu.mu_input_scroll(&self.ctx, @intFromFloat(scroll.x * -30), @intFromFloat(scroll.y * -30));

    // Mouse buttons
    if (rl.isMouseButtonPressed(.left)) {
        mu.mu_input_mousedown(&self.ctx, @intFromFloat(mouse_pos.x), @intFromFloat(mouse_pos.y), mu.MU_MOUSE_LEFT);
    }
    if (rl.isMouseButtonReleased(.left)) {
        mu.mu_input_mouseup(&self.ctx, @intFromFloat(mouse_pos.x), @intFromFloat(mouse_pos.y), mu.MU_MOUSE_LEFT);
    }
    if (rl.isMouseButtonPressed(.right)) {
        mu.mu_input_mousedown(&self.ctx, @intFromFloat(mouse_pos.x), @intFromFloat(mouse_pos.y), mu.MU_MOUSE_RIGHT);
    }
    if (rl.isMouseButtonReleased(.right)) {
        mu.mu_input_mouseup(&self.ctx, @intFromFloat(mouse_pos.x), @intFromFloat(mouse_pos.y), mu.MU_MOUSE_RIGHT);
    }

    // Keyboard modifiers
    if (rl.isKeyPressed(.left_shift) or rl.isKeyPressed(.right_shift)) {
        mu.mu_input_keydown(&self.ctx, mu.MU_KEY_SHIFT);
    }
    if (rl.isKeyReleased(.left_shift) or rl.isKeyReleased(.right_shift)) {
        mu.mu_input_keyup(&self.ctx, mu.MU_KEY_SHIFT);
    }
    if (rl.isKeyPressed(.left_control) or rl.isKeyPressed(.right_control)) {
        mu.mu_input_keydown(&self.ctx, mu.MU_KEY_CTRL);
    }
    if (rl.isKeyReleased(.left_control) or rl.isKeyReleased(.right_control)) {
        mu.mu_input_keyup(&self.ctx, mu.MU_KEY_CTRL);
    }
    if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) {
        mu.mu_input_keydown(&self.ctx, mu.MU_KEY_RETURN);
    }
    if (rl.isKeyReleased(.enter) or rl.isKeyReleased(.kp_enter)) {
        mu.mu_input_keyup(&self.ctx, mu.MU_KEY_RETURN);
    }
    if (rl.isKeyPressed(.backspace)) {
        mu.mu_input_keydown(&self.ctx, mu.MU_KEY_BACKSPACE);
    }
    if (rl.isKeyReleased(.backspace)) {
        mu.mu_input_keyup(&self.ctx, mu.MU_KEY_BACKSPACE);
    }

    // Text input
    var char = rl.getCharPressed();
    while (char != 0) {
        var buf: [5]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(char), &buf) catch 0;
        if (len > 0) {
            buf[len] = 0;
            mu.mu_input_text(&self.ctx, &buf);
        }
        char = rl.getCharPressed();
    }

    // microui doesn't have mu_input_end - just start the frame
    mu.mu_begin(&self.ctx);
}

pub fn endFrame(self: *Self) void {
    mu.mu_end(&self.ctx);

    // Render microui draw commands using raylib
    // cmd must be NULL initially for mu_next_command to work correctly
    var cmd: [*c]mu.mu_Command = null;
    while (mu.mu_next_command(&self.ctx, &cmd) != 0) {
        switch (cmd.*.type) {
            mu.MU_COMMAND_TEXT => {
                const text_cmd = @as(*mu.mu_TextCommand, @ptrCast(cmd));
                // Convert C char array to sentinel-terminated slice for raylib
                // Get a pointer to the C string array, cast to sentinel-terminated pointer, then span it
                const c_str: [*:0]const u8 = @ptrCast(&text_cmd.str);
                const text_slice: [:0]const u8 = std.mem.span(c_str);
                rl.drawText(
                    text_slice,
                    text_cmd.pos.x,
                    text_cmd.pos.y,
                    16,
                    muColorToRl(text_cmd.color),
                );
            },
            mu.MU_COMMAND_RECT => {
                const rect_cmd = @as(*mu.mu_RectCommand, @ptrCast(cmd));
                rl.drawRectangle(
                    rect_cmd.rect.x,
                    rect_cmd.rect.y,
                    rect_cmd.rect.w,
                    rect_cmd.rect.h,
                    muColorToRl(rect_cmd.color),
                );
            },
            mu.MU_COMMAND_ICON => {
                const icon_cmd = @as(*mu.mu_IconCommand, @ptrCast(cmd));
                // Draw icons as simple shapes
                const x = icon_cmd.rect.x + @divTrunc(icon_cmd.rect.w, 2);
                const y = icon_cmd.rect.y + @divTrunc(icon_cmd.rect.h, 2);
                const color = muColorToRl(icon_cmd.color);

                switch (icon_cmd.id) {
                    mu.MU_ICON_CLOSE => {
                        // X mark
                        rl.drawLine(icon_cmd.rect.x + 4, icon_cmd.rect.y + 4, icon_cmd.rect.x + icon_cmd.rect.w - 4, icon_cmd.rect.y + icon_cmd.rect.h - 4, color);
                        rl.drawLine(icon_cmd.rect.x + icon_cmd.rect.w - 4, icon_cmd.rect.y + 4, icon_cmd.rect.x + 4, icon_cmd.rect.y + icon_cmd.rect.h - 4, color);
                    },
                    mu.MU_ICON_CHECK => {
                        // Checkmark
                        rl.drawLine(icon_cmd.rect.x + 4, y, x - 2, icon_cmd.rect.y + icon_cmd.rect.h - 6, color);
                        rl.drawLine(x - 2, icon_cmd.rect.y + icon_cmd.rect.h - 6, icon_cmd.rect.x + icon_cmd.rect.w - 4, icon_cmd.rect.y + 4, color);
                    },
                    mu.MU_ICON_COLLAPSED => {
                        // Right arrow
                        rl.drawTriangle(
                            .{ .x = @floatFromInt(icon_cmd.rect.x + 4), .y = @floatFromInt(icon_cmd.rect.y + 4) },
                            .{ .x = @floatFromInt(icon_cmd.rect.x + 4), .y = @floatFromInt(icon_cmd.rect.y + icon_cmd.rect.h - 4) },
                            .{ .x = @floatFromInt(icon_cmd.rect.x + icon_cmd.rect.w - 4), .y = @floatFromInt(y) },
                            color,
                        );
                    },
                    mu.MU_ICON_EXPANDED => {
                        // Down arrow
                        rl.drawTriangle(
                            .{ .x = @floatFromInt(icon_cmd.rect.x + 4), .y = @floatFromInt(icon_cmd.rect.y + 4) },
                            .{ .x = @floatFromInt(icon_cmd.rect.x + icon_cmd.rect.w - 4), .y = @floatFromInt(icon_cmd.rect.y + 4) },
                            .{ .x = @floatFromInt(x), .y = @floatFromInt(icon_cmd.rect.y + icon_cmd.rect.h - 4) },
                            color,
                        );
                    },
                    else => {},
                }
            },
            mu.MU_COMMAND_CLIP => {
                const clip_cmd = @as(*mu.mu_ClipCommand, @ptrCast(cmd));
                rl.beginScissorMode(
                    clip_cmd.rect.x,
                    clip_cmd.rect.y,
                    clip_cmd.rect.w,
                    clip_cmd.rect.h,
                );
            },
            mu.MU_COMMAND_JUMP => {
                // Jump commands are handled internally by mu_next_command
            },
            else => {},
        }
    }

    // Reset scissor mode
    rl.endScissorMode();
}

// Convert microui color to raylib color
fn muColorToRl(c: mu.mu_Color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

pub fn label(self: *Self, lbl: types.Label) void {
    _ = self;
    // Render labels directly with raylib (not using microui's layout system)
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

    // Draw button background manually for positioned buttons
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

    // Draw text centered - need to ensure null-termination for raylib
    // btn.text is already a Zig slice, use it directly if it's sentinel-terminated
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
