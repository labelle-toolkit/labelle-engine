//! microui Adapter
//!
//! GUI backend using microui's native widgets and rendering.
//! Uses mu_layout_set_next() to support absolute positioning from .zon files
//! while leveraging microui's built-in widget implementations.
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

// Configuration constants
const MOUSE_SCROLL_SENSITIVITY: f32 = -30.0;
const TEXT_BUFFER_SIZE: usize = 256;
const CANVAS_WINDOW_NAME = "##canvas";

// microui context
ctx: mu.mu_Context,
// Track whether scissor mode is active to properly balance begin/end calls
scissor_active: bool = false,
// Track whether canvas window is open
canvas_open: bool = false,
// Screen dimensions for fullscreen canvas
screen_width: c_int = 800,
screen_height: c_int = 600,

// Text width callback for microui
fn textWidth(_: ?*anyopaque, text: [*c]const u8, len: c_int) callconv(.c) c_int {
    const font_size: c_int = 16;
    if (len == -1) {
        const text_slice: [:0]const u8 = std.mem.span(text);
        return @intCast(rl.measureText(text_slice, font_size));
    } else {
        var buf: [TEXT_BUFFER_SIZE]u8 = undefined;
        const actual_len: usize = @intCast(len);
        const copy_len = @min(actual_len, buf.len - 1);
        @memcpy(buf[0..copy_len], text[0..copy_len]);
        buf[copy_len] = 0;
        const sentinel_buf: [:0]const u8 = buf[0..copy_len :0];
        return @intCast(rl.measureText(sentinel_buf, font_size));
    }
}

// Text height callback for microui
fn textHeight(_: ?*anyopaque) callconv(.c) c_int {
    return 16;
}

pub fn init() Self {
    return Self{
        .ctx = undefined,
        .scissor_active = false,
        .canvas_open = false,
        .screen_width = 800,
        .screen_height = 600,
    };
}

/// Initialize the microui context after the struct is in its final memory location.
pub fn fixPointers(self: *Self) void {
    mu.mu_init(&self.ctx);
    self.ctx.text_width = textWidth;
    self.ctx.text_height = textHeight;
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn beginFrame(self: *Self) void {
    // Update screen dimensions
    self.screen_width = rl.getScreenWidth();
    self.screen_height = rl.getScreenHeight();

    // Forward input to microui
    const mouse_pos = rl.getMousePosition();
    mu.mu_input_mousemove(&self.ctx, @intFromFloat(mouse_pos.x), @intFromFloat(mouse_pos.y));

    // Mouse scroll
    const scroll = rl.getMouseWheelMoveV();
    mu.mu_input_scroll(&self.ctx, @intFromFloat(scroll.x * MOUSE_SCROLL_SENSITIVITY), @intFromFloat(scroll.y * MOUSE_SCROLL_SENSITIVITY));

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
    const left_shift_down = rl.isKeyDown(.left_shift);
    const right_shift_down = rl.isKeyDown(.right_shift);
    const left_ctrl_down = rl.isKeyDown(.left_control);
    const right_ctrl_down = rl.isKeyDown(.right_control);

    if (rl.isKeyPressed(.left_shift) or rl.isKeyPressed(.right_shift)) {
        mu.mu_input_keydown(&self.ctx, mu.MU_KEY_SHIFT);
    }
    if (!left_shift_down and !right_shift_down) {
        if (rl.isKeyReleased(.left_shift) or rl.isKeyReleased(.right_shift)) {
            mu.mu_input_keyup(&self.ctx, mu.MU_KEY_SHIFT);
        }
    }

    if (rl.isKeyPressed(.left_control) or rl.isKeyPressed(.right_control)) {
        mu.mu_input_keydown(&self.ctx, mu.MU_KEY_CTRL);
    }
    if (!left_ctrl_down and !right_ctrl_down) {
        if (rl.isKeyReleased(.left_control) or rl.isKeyReleased(.right_control)) {
            mu.mu_input_keyup(&self.ctx, mu.MU_KEY_CTRL);
        }
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

    mu.mu_begin(&self.ctx);

    // Create fullscreen invisible canvas window for absolute positioning
    const canvas_rect = mu.mu_Rect{ .x = 0, .y = 0, .w = self.screen_width, .h = self.screen_height };
    const canvas_opts = mu.MU_OPT_NOFRAME | mu.MU_OPT_NOTITLE | mu.MU_OPT_NOSCROLL | mu.MU_OPT_NORESIZE;

    if (mu.mu_begin_window_ex(&self.ctx, CANVAS_WINDOW_NAME, canvas_rect, canvas_opts) != 0) {
        self.canvas_open = true;
        // Get the window's content container and expand it to full screen
        const cnt = mu.mu_get_current_container(&self.ctx);
        cnt.*.rect = canvas_rect;
        cnt.*.body = canvas_rect;
    } else {
        self.canvas_open = false;
    }
}

pub fn endFrame(self: *Self) void {
    // Close canvas window if it was opened
    if (self.canvas_open) {
        mu.mu_end_window(&self.ctx);
        self.canvas_open = false;
    }

    mu.mu_end(&self.ctx);

    // Render microui draw commands
    var cmd: [*c]mu.mu_Command = null;
    while (mu.mu_next_command(&self.ctx, &cmd) != 0) {
        switch (cmd.*.type) {
            mu.MU_COMMAND_TEXT => {
                const text_cmd: *mu.mu_TextCommand = @ptrCast(@alignCast(cmd));
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
                const rect_cmd: *mu.mu_RectCommand = @ptrCast(@alignCast(cmd));
                rl.drawRectangle(
                    rect_cmd.rect.x,
                    rect_cmd.rect.y,
                    rect_cmd.rect.w,
                    rect_cmd.rect.h,
                    muColorToRl(rect_cmd.color),
                );
            },
            mu.MU_COMMAND_ICON => {
                const icon_cmd: *mu.mu_IconCommand = @ptrCast(@alignCast(cmd));
                drawIcon(icon_cmd);
            },
            mu.MU_COMMAND_CLIP => {
                const clip_cmd: *mu.mu_ClipCommand = @ptrCast(@alignCast(cmd));
                if (self.scissor_active) {
                    rl.endScissorMode();
                    self.scissor_active = false;
                }
                if (clip_cmd.rect.w > 0 and clip_cmd.rect.h > 0) {
                    rl.beginScissorMode(
                        clip_cmd.rect.x,
                        clip_cmd.rect.y,
                        clip_cmd.rect.w,
                        clip_cmd.rect.h,
                    );
                    self.scissor_active = true;
                }
            },
            else => {},
        }
    }

    if (self.scissor_active) {
        rl.endScissorMode();
        self.scissor_active = false;
    }
}

fn drawIcon(icon_cmd: *mu.mu_IconCommand) void {
    const color = muColorToRl(icon_cmd.color);
    const cx = icon_cmd.rect.x + @divTrunc(icon_cmd.rect.w, 2);
    const cy = icon_cmd.rect.y + @divTrunc(icon_cmd.rect.h, 2);
    const r: c_int = 4;

    switch (icon_cmd.id) {
        mu.MU_ICON_CLOSE => {
            rl.drawLine(cx - r, cy - r, cx + r, cy + r, color);
            rl.drawLine(cx + r, cy - r, cx - r, cy + r, color);
        },
        mu.MU_ICON_CHECK => {
            rl.drawLine(cx - r, cy, cx - r / 2, cy + r, color);
            rl.drawLine(cx - r / 2, cy + r, cx + r, cy - r, color);
        },
        mu.MU_ICON_COLLAPSED => {
            rl.drawTriangle(
                .{ .x = @floatFromInt(cx - r), .y = @floatFromInt(cy - r) },
                .{ .x = @floatFromInt(cx - r), .y = @floatFromInt(cy + r) },
                .{ .x = @floatFromInt(cx + r), .y = @floatFromInt(cy) },
                color,
            );
        },
        mu.MU_ICON_EXPANDED => {
            rl.drawTriangle(
                .{ .x = @floatFromInt(cx - r), .y = @floatFromInt(cy - r) },
                .{ .x = @floatFromInt(cx + r), .y = @floatFromInt(cy - r) },
                .{ .x = @floatFromInt(cx), .y = @floatFromInt(cy + r) },
                color,
            );
        },
        else => {},
    }
}

fn muColorToRl(c: mu.mu_Color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// Helper to set absolute position for next widget
fn setNextRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
    mu.mu_layout_set_next(&self.ctx, .{
        .x = @intFromFloat(x),
        .y = @intFromFloat(y),
        .w = @intFromFloat(w),
        .h = @intFromFloat(h),
    }, 0); // 0 = absolute positioning
}

/// Helper to convert text to null-terminated C string
fn toCString(text: []const u8, buf: *[TEXT_BUFFER_SIZE]u8) [*c]const u8 {
    const copy_len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..copy_len], text[0..copy_len]);
    buf[copy_len] = 0;
    return @ptrCast(buf);
}

pub fn label(self: *Self, lbl: types.Label) void {
    if (!self.canvas_open) return;

    // Use font_size for height, estimate width from text
    const font_size: c_int = @intFromFloat(lbl.font_size);
    var buf: [TEXT_BUFFER_SIZE]u8 = undefined;
    const text_c = toCString(lbl.text, &buf);
    // Use context's text_width callback to measure text
    const text_width = self.ctx.text_width.?(self.ctx.style.*.font, text_c, -1);

    self.setNextRect(lbl.position.x, lbl.position.y, @floatFromInt(text_width), @floatFromInt(font_size));

    // Set text color temporarily
    const old_color = self.ctx.style.*.colors[mu.MU_COLOR_TEXT];
    self.ctx.style.*.colors[mu.MU_COLOR_TEXT] = .{ .r = lbl.color.r, .g = lbl.color.g, .b = lbl.color.b, .a = lbl.color.a };

    mu.mu_label(&self.ctx, text_c);

    self.ctx.style.*.colors[mu.MU_COLOR_TEXT] = old_color;
}

pub fn button(self: *Self, btn: types.Button) bool {
    if (!self.canvas_open) return false;

    self.setNextRect(btn.position.x, btn.position.y, btn.size.width, btn.size.height);

    var buf: [TEXT_BUFFER_SIZE]u8 = undefined;
    const text_c = toCString(btn.text, &buf);

    return mu.mu_button(&self.ctx, text_c) != 0;
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    if (!self.canvas_open) return;

    // microui doesn't have a native progress bar, so draw manually
    const x: c_int = @intFromFloat(bar.position.x);
    const y: c_int = @intFromFloat(bar.position.y);
    const w: c_int = @intFromFloat(bar.size.width);
    const h: c_int = @intFromFloat(bar.size.height);

    // Background
    mu.mu_draw_rect(&self.ctx, .{ .x = x, .y = y, .w = w, .h = h }, self.ctx.style.*.colors[mu.MU_COLOR_BASE]);

    // Fill
    const fill_w: c_int = @intFromFloat(bar.size.width * std.math.clamp(bar.value, 0, 1));
    if (fill_w > 0) {
        mu.mu_draw_rect(&self.ctx, .{ .x = x, .y = y, .w = fill_w, .h = h }, .{ .r = bar.color.r, .g = bar.color.g, .b = bar.color.b, .a = bar.color.a });
    }

    // Border
    mu.mu_draw_box(&self.ctx, .{ .x = x, .y = y, .w = w, .h = h }, self.ctx.style.*.colors[mu.MU_COLOR_BORDER]);
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    if (!self.canvas_open) return;

    self.setNextRect(panel.position.x, panel.position.y, panel.size.width, panel.size.height);

    // Draw panel background manually since mu_begin_panel uses relative positioning
    const x: c_int = @intFromFloat(panel.position.x);
    const y: c_int = @intFromFloat(panel.position.y);
    const w: c_int = @intFromFloat(panel.size.width);
    const h: c_int = @intFromFloat(panel.size.height);

    mu.mu_draw_rect(&self.ctx, .{ .x = x, .y = y, .w = w, .h = h }, .{
        .r = panel.background_color.r,
        .g = panel.background_color.g,
        .b = panel.background_color.b,
        .a = panel.background_color.a,
    });
    mu.mu_draw_box(&self.ctx, .{ .x = x, .y = y, .w = w, .h = h }, self.ctx.style.*.colors[mu.MU_COLOR_BORDER]);
}

pub fn endPanel(self: *Self) void {
    _ = self;
}

pub fn image(self: *Self, img: types.Image) void {
    if (!self.canvas_open) return;

    // Draw placeholder rectangle (actual image rendering requires texture integration)
    if (img.size) |size| {
        const x: c_int = @intFromFloat(img.position.x);
        const y: c_int = @intFromFloat(img.position.y);
        const w: c_int = @intFromFloat(size.width);
        const h: c_int = @intFromFloat(size.height);
        mu.mu_draw_rect(&self.ctx, .{ .x = x, .y = y, .w = w, .h = h }, .{ .r = img.tint.r, .g = img.tint.g, .b = img.tint.b, .a = img.tint.a });
    }
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    if (!self.canvas_open) return false;

    // Estimate checkbox width: box + spacing + text
    var buf: [TEXT_BUFFER_SIZE]u8 = undefined;
    const text_c = toCString(cb.text, &buf);
    // Use context's text_width callback to measure text
    const text_width = self.ctx.text_width.?(self.ctx.style.*.font, text_c, -1);
    const checkbox_size = self.ctx.style.*.size.y;
    const total_width = checkbox_size + self.ctx.style.*.padding + text_width;

    self.setNextRect(cb.position.x, cb.position.y, @floatFromInt(total_width), @floatFromInt(checkbox_size));

    var state: c_int = if (cb.checked) 1 else 0;
    const result = mu.mu_checkbox(&self.ctx, text_c, &state);

    // Return true if clicked (state changed)
    return result != 0;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    if (!self.canvas_open) return sl.value;

    self.setNextRect(sl.position.x, sl.position.y, sl.size.width, sl.size.height);

    var value: mu.mu_Real = sl.value;
    _ = mu.mu_slider_ex(&self.ctx, &value, sl.min, sl.max, 0, "%.2f", mu.MU_OPT_ALIGNCENTER);

    return value;
}
