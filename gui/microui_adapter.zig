//! microui Adapter
//!
//! GUI backend using microui - a tiny immediate-mode UI library (~1000 LOC).
//! microui generates draw commands that we render using raylib primitives.
//!
//! ## Design Decision: Absolute Positioning
//!
//! This adapter intentionally bypasses microui's built-in layout and widget system.
//! Our GUI system uses absolute positioning defined in .zon files, not microui's
//! immediate-mode layout. We use microui primarily for:
//! - Input handling infrastructure (mouse, keyboard, text input)
//! - The command buffer pattern for deferred rendering
//!
//! Widget rendering is delegated to the shared widget_renderer module, which uses
//! raylib primitives directly. This ensures consistent appearance across backends.
//!
//! Build with: zig build -Dgui_backend=microui

const std = @import("std");
const rl = @import("raylib");
const types = @import("types.zig");
const widget = @import("widget_renderer.zig");

// Import microui C library
const mu = @cImport({
    @cInclude("microui.h");
});

const Self = @This();

// Configuration constants
const MOUSE_SCROLL_SENSITIVITY: f32 = -30.0;
const ICON_PADDING: c_int = 4;

// microui context
ctx: mu.mu_Context,
// Track whether scissor mode is active to properly balance begin/end calls
scissor_active: bool = false,

// Text width callback for microui (uses raylib's default font)
// mu_Font is typedef'd to void*, so we use ?*anyopaque
fn textWidth(_: ?*anyopaque, text: [*c]const u8, len: c_int) callconv(.c) c_int {
    if (len == -1) {
        // Null-terminated string - convert C string to sentinel-terminated slice
        const text_slice: [:0]const u8 = std.mem.span(text);
        return @intCast(rl.measureText(text_slice, widget.DEFAULT_FONT_SIZE));
    } else {
        // Use a buffer for non-null-terminated strings
        var buf: [widget.TEXT_BUFFER_SIZE]u8 = undefined;
        const actual_len: usize = @intCast(len);
        if (actual_len >= buf.len) {
            // For extremely long strings, measure in chunks and sum
            var total_width: c_int = 0;
            var remaining = actual_len;
            var offset: usize = 0;
            while (remaining > 0) {
                const chunk_len = @min(remaining, buf.len - 1);
                @memcpy(buf[0..chunk_len], text[offset..][0..chunk_len]);
                buf[chunk_len] = 0;
                const sentinel_buf: [:0]const u8 = buf[0..chunk_len :0];
                total_width += @intCast(rl.measureText(sentinel_buf, widget.DEFAULT_FONT_SIZE));
                offset += chunk_len;
                remaining -= chunk_len;
            }
            return total_width;
        }
        const copy_len = actual_len;
        @memcpy(buf[0..copy_len], text[0..copy_len]);
        buf[copy_len] = 0;
        const sentinel_buf: [:0]const u8 = buf[0..copy_len :0];
        return @intCast(rl.measureText(sentinel_buf, widget.DEFAULT_FONT_SIZE));
    }
}

// Text height callback for microui
fn textHeight(_: ?*anyopaque) callconv(.c) c_int {
    return widget.DEFAULT_FONT_SIZE;
}

pub fn init() Self {
    // Just return with undefined context - it will be properly initialized
    // in fixPointers() after the struct is in its final memory location.
    // This avoids issues with self-referential pointers being invalidated
    // when the struct is copied on return.
    return Self{
        .ctx = undefined,
        .scissor_active = false,
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

    // Keyboard modifiers - only send keyup when BOTH left and right are released
    // to handle the case where user holds both modifier keys
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
                const text_cmd: *mu.mu_TextCommand = @ptrCast(@alignCast(cmd));
                // Convert C char array to sentinel-terminated slice for raylib
                const c_str: [*:0]const u8 = @ptrCast(&text_cmd.str);
                const text_slice: [:0]const u8 = std.mem.span(c_str);
                rl.drawText(
                    text_slice,
                    text_cmd.pos.x,
                    text_cmd.pos.y,
                    widget.DEFAULT_FONT_SIZE,
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
                // Draw icons as simple shapes
                const center_x = icon_cmd.rect.x + @divTrunc(icon_cmd.rect.w, 2);
                const center_y = icon_cmd.rect.y + @divTrunc(icon_cmd.rect.h, 2);
                const color = muColorToRl(icon_cmd.color);

                const left = icon_cmd.rect.x + ICON_PADDING;
                const right = icon_cmd.rect.x + icon_cmd.rect.w - ICON_PADDING;
                const top = icon_cmd.rect.y + ICON_PADDING;
                const bottom = icon_cmd.rect.y + icon_cmd.rect.h - ICON_PADDING;

                switch (icon_cmd.id) {
                    mu.MU_ICON_CLOSE => {
                        // X mark
                        rl.drawLine(left, top, right, bottom, color);
                        rl.drawLine(right, top, left, bottom, color);
                    },
                    mu.MU_ICON_CHECK => {
                        // Checkmark
                        const check_mid_x = center_x - 2;
                        const check_bottom = bottom - 2;
                        rl.drawLine(left, center_y, check_mid_x, check_bottom, color);
                        rl.drawLine(check_mid_x, check_bottom, right, top, color);
                    },
                    mu.MU_ICON_COLLAPSED => {
                        // Right arrow
                        rl.drawTriangle(
                            .{ .x = @floatFromInt(left), .y = @floatFromInt(top) },
                            .{ .x = @floatFromInt(left), .y = @floatFromInt(bottom) },
                            .{ .x = @floatFromInt(right), .y = @floatFromInt(center_y) },
                            color,
                        );
                    },
                    mu.MU_ICON_EXPANDED => {
                        // Down arrow
                        rl.drawTriangle(
                            .{ .x = @floatFromInt(left), .y = @floatFromInt(top) },
                            .{ .x = @floatFromInt(right), .y = @floatFromInt(top) },
                            .{ .x = @floatFromInt(center_x), .y = @floatFromInt(bottom) },
                            color,
                        );
                    },
                    else => {},
                }
            },
            mu.MU_COMMAND_CLIP => {
                const clip_cmd: *mu.mu_ClipCommand = @ptrCast(@alignCast(cmd));
                // End any existing scissor mode before beginning a new one
                if (self.scissor_active) {
                    rl.endScissorMode();
                    self.scissor_active = false;
                }
                // microui uses zero-sized clip rect to disable clipping
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
            mu.MU_COMMAND_JUMP => {
                // Jump commands are handled internally by mu_next_command
            },
            else => {},
        }
    }

    // Reset scissor mode only if it was activated
    if (self.scissor_active) {
        rl.endScissorMode();
        self.scissor_active = false;
    }
}

// Convert microui color to raylib color
fn muColorToRl(c: mu.mu_Color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

pub fn label(self: *Self, lbl: types.Label) void {
    _ = self;
    widget.drawLabel(lbl);
}

pub fn button(self: *Self, btn: types.Button) bool {
    _ = self;
    return widget.drawButton(btn);
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    _ = self;
    widget.drawProgressBar(bar);
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    _ = self;
    widget.drawPanel(panel);
}

pub fn endPanel(self: *Self) void {
    _ = self;
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    widget.drawImage(img);
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    _ = self;
    return widget.drawCheckbox(cb);
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    _ = self;
    return widget.drawSlider(sl);
}
