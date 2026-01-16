//! Nuklear Adapter
//!
//! GUI backend using the Nuklear immediate-mode GUI library with raylib rendering.
//! Uses Nuklear's command buffer mode to render UI elements through raylib's drawing functions.
//!
//! Build with: zig build -Dgui_backend=nuklear

const std = @import("std");
const types = @import("types.zig");
const nk = @import("nuklear");
const rl = @import("raylib");

const Self = @This();

/// Heap-allocated Nuklear state to avoid pointer invalidation on struct move.
/// Nuklear's C structures contain many internal pointers that become invalid
/// if the containing struct is moved (which happens with Zig's value semantics).
const NkState = struct {
    ctx: nk.Context,
    atlas: nk.FontAtlas,
    font: *nk.Font,
    null_tex: nk.NullTexture, // Required for atlas.end()
};

// Pointer to heap-allocated nuklear state (stable address)
nk_state: *NkState,

// Raylib texture for font atlas (safe to move - just an ID)
font_texture: rl.Texture2D,

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level - when > 0, widgets are inside a panel and should not create their own windows
panel_depth: u32,

// Use c_allocator for WASM (emscripten), page_allocator for native
const allocator = if (@import("builtin").os.tag == .emscripten)
    std.heap.c_allocator
else
    std.heap.page_allocator;

pub fn init() Self {
    // Allocate nuklear state on the heap so it won't move
    const nk_state = allocator.create(NkState) catch @panic("Failed to allocate nuklear state");

    // Initialize font atlas
    nk_state.atlas = nk.FontAtlas.initDefault();
    nk_state.atlas.begin();

    // Add default font (ProggyClean)
    nk_state.font = nk_state.atlas.addDefault(18.0, null);

    // Bake font atlas to RGBA texture
    const bake_result = nk_state.atlas.bake(.rgba32);
    const pixels = bake_result[0];
    const width = bake_result[1];
    const height = bake_result[2];

    // Create raylib texture from baked atlas
    const font_image = rl.Image{
        .data = @constCast(@ptrCast(pixels.ptr)),
        .width = @intCast(width),
        .height = @intCast(height),
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    const font_texture = rl.loadTextureFromImage(font_image) catch @panic("Failed to load nuklear font texture");

    // Create texture handle for nuklear
    nk_state.atlas.end(
        nk.Handle{ .id = @intCast(font_texture.id) },
        &nk_state.null_tex,
    );

    // Initialize context with font
    nk_state.ctx = nk.Context.initDefault(nk_state.font.handle());

    return Self{
        .nk_state = nk_state,
        .font_texture = font_texture,
        .window_counter = 0,
        .panel_depth = 0,
    };
}

pub fn fixPointers(self: *Self) void {
    // Nuklear state is heap-allocated, so no pointer fixing needed
    _ = self;
}

pub fn deinit(self: *Self) void {
    self.nk_state.ctx.free();
    self.nk_state.atlas.clear();
    rl.unloadTexture(self.font_texture);
    allocator.destroy(self.nk_state);
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Begin input processing
    var input = self.nk_state.ctx.input();

    // Pass mouse position (clamped to prevent overflow when outside window)
    const mouse_pos = rl.getMousePosition();
    const mx: u31 = @intFromFloat(std.math.clamp(mouse_pos.x, 0.0, 8192.0));
    const my: u31 = @intFromFloat(std.math.clamp(mouse_pos.y, 0.0, 8192.0));
    input.motion(mx, my);

    // Pass mouse buttons
    input.button(.left, mx, my, rl.isMouseButtonDown(.left));
    input.button(.right, mx, my, rl.isMouseButtonDown(.right));
    input.button(.middle, mx, my, rl.isMouseButtonDown(.middle));

    // Pass scroll
    const scroll = rl.getMouseWheelMoveV();
    input.scroll(.{ .x = scroll.x, .y = scroll.y });

    // End input processing
    input.end();
}

pub fn endFrame(self: *Self) void {
    // Use command buffer mode - process high-level draw commands
    self.renderCommandBuffer();

    // Clear nuklear context for next frame
    self.nk_state.ctx.clear();
}

fn renderCommandBuffer(self: *Self) void {
    // Iterate through nuklear's draw commands
    var cmd = nk.c.nk__begin(&self.nk_state.ctx.c);
    while (cmd != null) : (cmd = nk.c.nk__next(&self.nk_state.ctx.c, cmd)) {
        switch (cmd.*.type) {
            nk.c.NK_COMMAND_NOP => {},
            nk.c.NK_COMMAND_SCISSOR => {
                const s: *const nk.c.struct_nk_command_scissor = @ptrCast(cmd);
                if (s.w > 0 and s.h > 0) {
                    rl.beginScissorMode(s.x, s.y, @intCast(s.w), @intCast(s.h));
                }
            },
            nk.c.NK_COMMAND_LINE => {
                const l: *const nk.c.struct_nk_command_line = @ptrCast(cmd);
                const color = nkColorToRaylib(l.color);
                rl.drawLine(l.begin.x, l.begin.y, l.end.x, l.end.y, color);
            },
            nk.c.NK_COMMAND_RECT => {
                const r: *const nk.c.struct_nk_command_rect = @ptrCast(cmd);
                const color = nkColorToRaylib(r.color);
                rl.drawRectangleLines(r.x, r.y, @intCast(r.w), @intCast(r.h), color);
            },
            nk.c.NK_COMMAND_RECT_FILLED => {
                const r: *const nk.c.struct_nk_command_rect_filled = @ptrCast(cmd);
                const color = nkColorToRaylib(r.color);
                rl.drawRectangle(r.x, r.y, @intCast(r.w), @intCast(r.h), color);
            },
            nk.c.NK_COMMAND_CIRCLE => {
                const c: *const nk.c.struct_nk_command_circle = @ptrCast(cmd);
                const color = nkColorToRaylib(c.color);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                rl.drawCircleLines(@intFromFloat(@as(f32, @floatFromInt(c.x)) + radius), @intFromFloat(@as(f32, @floatFromInt(c.y)) + radius), radius, color);
            },
            nk.c.NK_COMMAND_CIRCLE_FILLED => {
                const c: *const nk.c.struct_nk_command_circle_filled = @ptrCast(cmd);
                const color = nkColorToRaylib(c.color);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                rl.drawCircle(@intFromFloat(@as(f32, @floatFromInt(c.x)) + radius), @intFromFloat(@as(f32, @floatFromInt(c.y)) + radius), radius, color);
            },
            nk.c.NK_COMMAND_TRIANGLE => {
                const t: *const nk.c.struct_nk_command_triangle = @ptrCast(cmd);
                const color = nkColorToRaylib(t.color);
                rl.drawTriangleLines(
                    .{ .x = @floatFromInt(t.a.x), .y = @floatFromInt(t.a.y) },
                    .{ .x = @floatFromInt(t.b.x), .y = @floatFromInt(t.b.y) },
                    .{ .x = @floatFromInt(t.c.x), .y = @floatFromInt(t.c.y) },
                    color,
                );
            },
            nk.c.NK_COMMAND_TRIANGLE_FILLED => {
                const t: *const nk.c.struct_nk_command_triangle_filled = @ptrCast(cmd);
                const color = nkColorToRaylib(t.color);
                rl.drawTriangle(
                    .{ .x = @floatFromInt(t.a.x), .y = @floatFromInt(t.a.y) },
                    .{ .x = @floatFromInt(t.b.x), .y = @floatFromInt(t.b.y) },
                    .{ .x = @floatFromInt(t.c.x), .y = @floatFromInt(t.c.y) },
                    color,
                );
            },
            nk.c.NK_COMMAND_TEXT => {
                const t: *const nk.c.struct_nk_command_text = @ptrCast(cmd);
                const color = nkColorToRaylib(t.foreground);
                // Use raylib's default font for text rendering
                const text_ptr: [*]const u8 = @ptrCast(&t.string);
                const text_len: usize = @intCast(t.length);
                // Copy to null-terminated buffer
                var text_buf: [256:0]u8 = undefined;
                const len = @min(text_len, text_buf.len - 1);
                @memcpy(text_buf[0..len], text_ptr[0..len]);
                text_buf[len] = 0;
                const text: [:0]const u8 = text_buf[0..len :0];
                rl.drawText(text, t.x, t.y, @intFromFloat(t.height), color);
            },
            else => {
                // Ignore other commands for now
            },
        }
    }
    rl.endScissorMode();
}

fn nkColorToRaylib(c: nk.c.struct_nk_color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

fn nextWindowName(self: *Self, buf: []u8) [:0]const u8 {
    self.window_counter += 1;
    const result = std.fmt.bufPrintZ(buf, "w{d}", .{self.window_counter}) catch {
        buf[0] = 'w';
        buf[1] = 0;
        return buf[0..1 :0];
    };
    return result;
}

pub fn label(self: *Self, lbl: types.Label) void {
    if (self.panel_depth > 0) {
        // Inside a panel - just add the widget to current layout
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, lbl.font_size, 1);
        nk.c.nk_text_colored(
            &self.nk_state.ctx.c,
            lbl.text.ptr,
            @intCast(lbl.text.len),
            nk.c.NK_TEXT_LEFT,
            nk.c.nk_rgba(lbl.color.r, lbl.color.g, lbl.color.b, lbl.color.a),
        );
    } else {
        // Top-level label - create a mini window
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const rect = nk.Rect{
            .x = lbl.position.x,
            .y = lbl.position.y,
            .w = @floatFromInt(lbl.text.len * 8), // Approximate width
            .h = lbl.font_size + 4,
        };

        if (self.nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true, .no_input = true })) |win| {
            win.layoutRowDynamic(lbl.font_size, 1);
            nk.c.nk_text_colored(
                &self.nk_state.ctx.c,
                lbl.text.ptr,
                @intCast(lbl.text.len),
                nk.c.NK_TEXT_LEFT,
                nk.c.nk_rgba(lbl.color.r, lbl.color.g, lbl.color.b, lbl.color.a),
            );
            win.end();
        }
    }
}

pub fn button(self: *Self, btn: types.Button) bool {
    if (self.panel_depth > 0) {
        // Inside a panel - just add the button to current layout
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, btn.size.height - 8, 1);
        return nk.c.nk_button_text(&self.nk_state.ctx.c, btn.text.ptr, @intCast(btn.text.len));
    } else {
        // Top-level button - create a mini window
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const rect = nk.Rect{
            .x = btn.position.x,
            .y = btn.position.y,
            .w = btn.size.width,
            .h = btn.size.height,
        };

        var clicked = false;
        if (self.nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true })) |win| {
            win.layoutRowDynamic(btn.size.height - 8, 1);
            clicked = win.buttonText(btn.text);
            win.end();
        }

        return clicked;
    }
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    if (self.panel_depth > 0) {
        // Inside a panel - just add the progress bar to current layout
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, bar.size.height - 8, 1);
        var value: nk.c.nk_size = @intFromFloat(bar.value * 100);
        _ = nk.c.nk_progress(&self.nk_state.ctx.c, &value, 100, false);
    } else {
        // Top-level progress bar - create a mini window
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const rect = nk.Rect{
            .x = bar.position.x,
            .y = bar.position.y,
            .w = bar.size.width,
            .h = bar.size.height,
        };

        if (self.nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true, .no_input = true })) |win| {
            win.layoutRowDynamic(bar.size.height - 8, 1);
            var value: nk.c.nk_size = @intFromFloat(bar.value * 100);
            _ = nk.c.nk_progress(&self.nk_state.ctx.c, &value, 100, false);
            win.end();
        }
    }
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    var name_buf: [32]u8 = undefined;
    const name = self.nextWindowName(&name_buf);

    const rect = nk.Rect{
        .x = panel.position.x,
        .y = panel.position.y,
        .w = panel.size.width,
        .h = panel.size.height,
    };

    // Start a window - the window pointer is stored by nuklear internally
    _ = self.nk_state.ctx.begin(name, rect, .{ .title = true, .border = true, .movable = false, .no_scrollbar = true });
    self.panel_depth += 1;
}

pub fn endPanel(self: *Self) void {
    self.panel_depth -= 1;
    // End the current window
    nk.c.nk_end(&self.nk_state.ctx.c);
}

pub fn image(self: *Self, img: types.Image) void {
    // Images require loading textures - for now delegate to widget renderer
    _ = self;
    _ = img;
    // TODO: Implement image rendering through nuklear
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    var changed = false;

    if (self.panel_depth > 0) {
        // Inside a panel - just add the checkbox to current layout
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, 22, 1);
        var active: bool = cb.checked;
        if (nk.c.nk_checkbox_label(&self.nk_state.ctx.c, cb.text.ptr, &active)) {
            changed = true;
        }
    } else {
        // Top-level checkbox - create a mini window
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const text_len: usize = cb.text.len;
        const rect = nk.Rect{
            .x = cb.position.x,
            .y = cb.position.y,
            .w = @as(f32, @floatFromInt(text_len * 8)) + 40,
            .h = 30,
        };

        if (self.nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true })) |win| {
            win.layoutRowDynamic(22, 1);
            var active: bool = cb.checked;
            if (nk.c.nk_checkbox_label(&self.nk_state.ctx.c, cb.text.ptr, &active)) {
                changed = true;
            }
            win.end();
        }
    }

    return changed;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    var value = sl.value;
    const range = sl.max - sl.min;
    const step = range / 100.0;

    if (self.panel_depth > 0) {
        // Inside a panel - just add the slider to current layout
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, sl.size.height - 8, 1);
        value = nk.c.nk_slide_float(&self.nk_state.ctx.c, sl.min, value, sl.max, step);
    } else {
        // Top-level slider - create a mini window
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const rect = nk.Rect{
            .x = sl.position.x,
            .y = sl.position.y,
            .w = sl.size.width,
            .h = sl.size.height,
        };

        if (self.nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true })) |win| {
            win.layoutRowDynamic(sl.size.height - 8, 1);
            value = nk.c.nk_slide_float(&self.nk_state.ctx.c, sl.min, value, sl.max, step);
            win.end();
        }
    }

    return value;
}
