//! Nuklear SDL Adapter
//!
//! GUI backend using the Nuklear immediate-mode GUI library with SDL2 rendering.
//! Uses SDL_Renderer for drawing primitives.
//!
//! Build with: zig build -Dbackend=sdl -Dgui_backend=nuklear

const std = @import("std");
const types = @import("types.zig");
const nk = @import("nuklear");
const sdl = @import("sdl2");

const Self = @This();

/// Heap-allocated Nuklear state to avoid pointer invalidation on struct move.
const NkState = struct {
    ctx: nk.Context,
    atlas: nk.FontAtlas,
    font: *nk.Font,
    null_tex: nk.NullTexture,
    // Track if atlas.end() has been called (required before using font)
    atlas_finalized: bool,
};

// Pointer to heap-allocated nuklear state
nk_state: *NkState,

// SDL texture for font atlas
font_texture: ?sdl.Texture,

// SDL renderer reference (borrowed from game)
renderer: ?sdl.Renderer,

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

const allocator = std.heap.page_allocator;

pub fn init() Self {
    // Allocate nuklear state on the heap
    const nk_state = allocator.create(NkState) catch @panic("Failed to allocate nuklear state");

    // Initialize font atlas
    nk_state.atlas = nk.FontAtlas.initDefault();
    nk_state.atlas.begin();

    // Add default font
    nk_state.font = nk_state.atlas.addDefault(18.0, null);

    // Bake font atlas to RGBA texture
    // NOTE: Do NOT call atlas.end() here - it invalidates the baked pixel data
    // We defer atlas.end() and context init to createFontTexture() when renderer is available
    _ = nk_state.atlas.bake(.rgba32);
    nk_state.atlas_finalized = false;

    // Context will be initialized in createFontTexture() after atlas.end()
    nk_state.ctx = undefined;

    return Self{
        .nk_state = nk_state,
        .font_texture = null,
        .renderer = null,
        .window_counter = 0,
        .panel_depth = 0,
    };
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    if (self.nk_state.atlas_finalized) {
        self.nk_state.ctx.free();
    }
    self.nk_state.atlas.clear();
    if (self.font_texture) |tex| {
        tex.destroy();
    }
    allocator.destroy(self.nk_state);
}

/// Set the SDL renderer (called by game after window creation)
pub fn setRenderer(self: *Self, renderer: sdl.Renderer) void {
    self.renderer = renderer;
    // Create font texture now that we have a renderer
    self.createFontTexture();
}

fn createFontTexture(self: *Self) void {
    if (self.nk_state.atlas_finalized) return;

    const renderer = self.renderer orelse return;

    // Get baked atlas data (atlas.end() not yet called, so data is still valid)
    const bake_result = self.nk_state.atlas.bake(.rgba32);
    const pixels = bake_result[0];
    const width: usize = @intCast(bake_result[1]);
    const height: usize = @intCast(bake_result[2]);

    // Create SDL texture using wrapper API
    const tex = sdl.createTexture(renderer, .abgr8888, .static, width, height) catch return;
    tex.update(pixels, width * 4, null) catch {};
    tex.setBlendMode(.blend) catch {};
    self.font_texture = tex;

    // Now finalize the atlas - this invalidates baked pixel data
    self.nk_state.atlas.end(
        nk.Handle{ .id = 0 }, // SDL textures don't need nuklear handle
        &self.nk_state.null_tex,
    );

    // Initialize nuklear context with font (must be after atlas.end())
    self.nk_state.ctx = nk.Context.initDefault(self.nk_state.font.handle());
    self.nk_state.atlas_finalized = true;
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Skip if context not initialized yet
    if (!self.nk_state.atlas_finalized) return;

    // Begin nuklear input
    var input = self.nk_state.ctx.input();

    // SDL input is handled through event polling
    // Mouse position and button state should be passed through events

    input.end();
}

pub fn endFrame(self: *Self) void {
    // Skip if context not initialized yet
    if (!self.nk_state.atlas_finalized) return;

    if (self.renderer == null) {
        self.nk_state.ctx.clear();
        return;
    }

    // Render nuklear command buffer
    self.renderCommandBuffer();

    // Clear nuklear context
    self.nk_state.ctx.clear();
}

fn renderCommandBuffer(self: *Self) void {
    const renderer = self.renderer orelse return;

    var cmd = nk.c.nk__begin(&self.nk_state.ctx.c);
    while (cmd != null) : (cmd = nk.c.nk__next(&self.nk_state.ctx.c, cmd)) {
        switch (cmd.*.type) {
            nk.c.NK_COMMAND_NOP => {},
            nk.c.NK_COMMAND_SCISSOR => {
                const s: *const nk.c.struct_nk_command_scissor = @ptrCast(cmd);
                const rect = sdl.Rectangle{
                    .x = s.x,
                    .y = s.y,
                    .width = @intCast(s.w),
                    .height = @intCast(s.h),
                };
                renderer.setClipRect(rect) catch {};
            },
            nk.c.NK_COMMAND_LINE => {
                const l: *const nk.c.struct_nk_command_line = @ptrCast(cmd);
                renderer.setColor(.{ .r = l.color.r, .g = l.color.g, .b = l.color.b, .a = l.color.a }) catch {};
                renderer.drawLine(l.begin.x, l.begin.y, l.end.x, l.end.y) catch {};
            },
            nk.c.NK_COMMAND_RECT => {
                const r: *const nk.c.struct_nk_command_rect = @ptrCast(cmd);
                renderer.setColor(.{ .r = r.color.r, .g = r.color.g, .b = r.color.b, .a = r.color.a }) catch {};
                const rect = sdl.Rectangle{
                    .x = r.x,
                    .y = r.y,
                    .width = @intCast(r.w),
                    .height = @intCast(r.h),
                };
                renderer.drawRect(rect) catch {};
            },
            nk.c.NK_COMMAND_RECT_FILLED => {
                const r: *const nk.c.struct_nk_command_rect_filled = @ptrCast(cmd);
                renderer.setColor(.{ .r = r.color.r, .g = r.color.g, .b = r.color.b, .a = r.color.a }) catch {};
                const rect = sdl.Rectangle{
                    .x = r.x,
                    .y = r.y,
                    .width = @intCast(r.w),
                    .height = @intCast(r.h),
                };
                renderer.fillRect(rect) catch {};
            },
            nk.c.NK_COMMAND_CIRCLE => {
                const c: *const nk.c.struct_nk_command_circle = @ptrCast(cmd);
                renderer.setColor(.{ .r = c.color.r, .g = c.color.g, .b = c.color.b, .a = c.color.a }) catch {};
                const radius: i32 = @intCast(@divTrunc(c.w, 2));
                const cx: i32 = c.x + radius;
                const cy: i32 = c.y + radius;
                self.drawCircleLines(renderer, cx, cy, radius);
            },
            nk.c.NK_COMMAND_CIRCLE_FILLED => {
                const c: *const nk.c.struct_nk_command_circle_filled = @ptrCast(cmd);
                renderer.setColor(.{ .r = c.color.r, .g = c.color.g, .b = c.color.b, .a = c.color.a }) catch {};
                const radius: i32 = @intCast(@divTrunc(c.w, 2));
                const cx: i32 = c.x + radius;
                const cy: i32 = c.y + radius;
                self.drawCircleFilled(renderer, cx, cy, radius);
            },
            nk.c.NK_COMMAND_TRIANGLE => {
                const t: *const nk.c.struct_nk_command_triangle = @ptrCast(cmd);
                renderer.setColor(.{ .r = t.color.r, .g = t.color.g, .b = t.color.b, .a = t.color.a }) catch {};
                renderer.drawLine(t.a.x, t.a.y, t.b.x, t.b.y) catch {};
                renderer.drawLine(t.b.x, t.b.y, t.c.x, t.c.y) catch {};
                renderer.drawLine(t.c.x, t.c.y, t.a.x, t.a.y) catch {};
            },
            nk.c.NK_COMMAND_TRIANGLE_FILLED => {
                const t: *const nk.c.struct_nk_command_triangle_filled = @ptrCast(cmd);
                renderer.setColor(.{ .r = t.color.r, .g = t.color.g, .b = t.color.b, .a = t.color.a }) catch {};
                // SDL doesn't have built-in triangle fill, so use lines for now
                renderer.drawLine(t.a.x, t.a.y, t.b.x, t.b.y) catch {};
                renderer.drawLine(t.b.x, t.b.y, t.c.x, t.c.y) catch {};
                renderer.drawLine(t.c.x, t.c.y, t.a.x, t.a.y) catch {};
            },
            nk.c.NK_COMMAND_TEXT => {
                // SDL2 text rendering requires SDL_ttf
                // For now, skip text or use basic placeholder
                // TODO: Integrate SDL_ttf for proper text rendering
            },
            else => {},
        }
    }

    // Reset clip rect
    renderer.setClipRect(null) catch {};
}

fn drawCircleLines(_: *Self, renderer: sdl.Renderer, cx: i32, cy: i32, radius: i32) void {
    // Midpoint circle algorithm for outline
    var x: i32 = radius;
    var y: i32 = 0;
    var err: i32 = 0;

    while (x >= y) {
        renderer.drawPoint(cx + x, cy + y) catch {};
        renderer.drawPoint(cx + y, cy + x) catch {};
        renderer.drawPoint(cx - y, cy + x) catch {};
        renderer.drawPoint(cx - x, cy + y) catch {};
        renderer.drawPoint(cx - x, cy - y) catch {};
        renderer.drawPoint(cx - y, cy - x) catch {};
        renderer.drawPoint(cx + y, cy - x) catch {};
        renderer.drawPoint(cx + x, cy - y) catch {};

        y += 1;
        err += 1 + 2 * y;
        if (2 * (err - x) + 1 > 0) {
            x -= 1;
            err += 1 - 2 * x;
        }
    }
}

fn drawCircleFilled(_: *Self, renderer: sdl.Renderer, cx: i32, cy: i32, radius: i32) void {
    // Draw filled circle using horizontal lines
    var y_off: i32 = -radius;
    while (y_off <= radius) : (y_off += 1) {
        const x_off: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(radius * radius - y_off * y_off))));
        renderer.drawLine(cx - x_off, cy + y_off, cx + x_off, cy + y_off) catch {};
    }
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
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, lbl.font_size, 1);
        nk.c.nk_text_colored(
            &self.nk_state.ctx.c,
            lbl.text.ptr,
            @intCast(lbl.text.len),
            nk.c.NK_TEXT_LEFT,
            nk.c.nk_rgba(lbl.color.r, lbl.color.g, lbl.color.b, lbl.color.a),
        );
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const rect = nk.Rect{
            .x = lbl.position.x,
            .y = lbl.position.y,
            .w = @floatFromInt(lbl.text.len * 8),
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
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, btn.size.height - 8, 1);
        return nk.c.nk_button_text(&self.nk_state.ctx.c, btn.text.ptr, @intCast(btn.text.len));
    } else {
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
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, bar.size.height - 8, 1);
        var value: nk.c.nk_size = @intFromFloat(bar.value * 100);
        _ = nk.c.nk_progress(&self.nk_state.ctx.c, &value, 100, false);
    } else {
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

    _ = self.nk_state.ctx.begin(name, rect, .{ .title = true, .border = true, .movable = false, .no_scrollbar = true });
    self.panel_depth += 1;
}

pub fn endPanel(self: *Self) void {
    self.panel_depth -= 1;
    nk.c.nk_end(&self.nk_state.ctx.c);
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    var checked = cb.checked;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, 22, 1);
        var active: bool = checked;
        if (nk.c.nk_checkbox_label(&self.nk_state.ctx.c, cb.text.ptr, &active)) {
            checked = active;
        }
    } else {
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
            var active: bool = checked;
            if (nk.c.nk_checkbox_label(&self.nk_state.ctx.c, cb.text.ptr, &active)) {
                checked = active;
            }
            win.end();
        }
    }

    return checked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    var value = sl.value;
    const range = sl.max - sl.min;
    const step = range / 100.0;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, sl.size.height - 8, 1);
        value = nk.c.nk_slide_float(&self.nk_state.ctx.c, sl.min, value, sl.max, step);
    } else {
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
