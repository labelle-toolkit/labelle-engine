//! Nuklear BGFX Adapter
//!
//! GUI backend using the Nuklear immediate-mode GUI library with bgfx rendering.
//! Uses debugdraw encoder for drawing primitives.
//!
//! Build with: zig build -Dbackend=bgfx -Dgui_backend=nuklear

const std = @import("std");
const types = @import("types.zig");
const nk = @import("nuklear");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;
const debugdraw = zbgfx.debugdraw;

const Self = @This();

/// Heap-allocated Nuklear state to avoid pointer invalidation on struct move.
const NkState = struct {
    ctx: nk.Context,
    atlas: nk.FontAtlas,
    font: *nk.Font,
    null_tex: nk.NullTexture,
};

// Pointer to heap-allocated nuklear state
nk_state: *NkState,

// Font texture handle
font_texture: bgfx.TextureHandle,

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

// View ID for rendering
view_id: bgfx.ViewId,

// Debug draw encoder
encoder: ?*debugdraw.Encoder,

const allocator = std.heap.page_allocator;

pub fn init() Self {
    // Initialize bgfx debugdraw
    debugdraw.init();

    // Allocate nuklear state on the heap
    const nk_state = allocator.create(NkState) catch @panic("Failed to allocate nuklear state");

    // Initialize font atlas
    nk_state.atlas = nk.FontAtlas.initDefault();
    nk_state.atlas.begin();

    // Add default font
    nk_state.font = nk_state.atlas.addDefault(18.0, null);

    // Bake font atlas to RGBA texture
    const bake_result = nk_state.atlas.bake(.rgba32);
    const pixels = bake_result[0];
    const width: u16 = @intCast(bake_result[1]);
    const height: u16 = @intCast(bake_result[2]);

    // Create bgfx texture from baked atlas
    const mem = bgfx.copy(pixels.ptr, @as(u32, width) * @as(u32, height) * 4);
    // Use UV clamp sampler flags
    const sampler_flags: u64 = bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp;
    const font_texture = bgfx.createTexture2D(width, height, false, 1, .RGBA8, sampler_flags, mem);

    // End atlas baking with texture handle
    nk_state.atlas.end(
        nk.Handle{ .id = @intCast(font_texture.idx) },
        &nk_state.null_tex,
    );

    // Initialize context with font
    nk_state.ctx = nk.Context.initDefault(nk_state.font.handle());

    return Self{
        .nk_state = nk_state,
        .font_texture = font_texture,
        .window_counter = 0,
        .panel_depth = 0,
        .view_id = 0,
        .encoder = null,
    };
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    self.nk_state.ctx.free();
    self.nk_state.atlas.clear();
    bgfx.destroyTexture(self.font_texture);
    allocator.destroy(self.nk_state);
    debugdraw.deinit();
}

/// Set the view ID for rendering
pub fn setViewId(self: *Self, view_id: bgfx.ViewId) void {
    self.view_id = view_id;
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Begin nuklear input
    var input = self.nk_state.ctx.input();
    input.end();

    // Create debug draw encoder
    self.encoder = debugdraw.Encoder.create();
    if (self.encoder) |enc| {
        enc.begin(self.view_id, false, null);
    }
}

pub fn endFrame(self: *Self) void {
    // Render nuklear command buffer
    self.renderCommandBuffer();

    // End debug draw encoder
    if (self.encoder) |enc| {
        enc.end();
        enc.destroy();
    }
    self.encoder = null;

    // Clear nuklear context
    self.nk_state.ctx.clear();
}

fn renderCommandBuffer(self: *Self) void {
    const enc = self.encoder orelse return;

    var cmd = nk.c.nk__begin(&self.nk_state.ctx.c);
    while (cmd != null) : (cmd = nk.c.nk__next(&self.nk_state.ctx.c, cmd)) {
        switch (cmd.*.type) {
            nk.c.NK_COMMAND_NOP => {},
            nk.c.NK_COMMAND_SCISSOR => {
                // bgfx debugdraw doesn't support scissor directly
                // Would need to use bgfx.setScissor on the view
            },
            nk.c.NK_COMMAND_LINE => {
                const l: *const nk.c.struct_nk_command_line = @ptrCast(cmd);
                const color = toAbgr(l.color);
                enc.setColor(color);
                enc.moveTo(.{ @floatFromInt(l.begin.x), @floatFromInt(l.begin.y), 0 });
                enc.lineTo(.{ @floatFromInt(l.end.x), @floatFromInt(l.end.y), 0 });
            },
            nk.c.NK_COMMAND_RECT => {
                const r: *const nk.c.struct_nk_command_rect = @ptrCast(cmd);
                const color = toAbgr(r.color);
                enc.setColor(color);
                self.drawRectLines(enc, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
            },
            nk.c.NK_COMMAND_RECT_FILLED => {
                const r: *const nk.c.struct_nk_command_rect_filled = @ptrCast(cmd);
                const color = toAbgr(r.color);
                enc.setColor(color);
                self.drawRectFilled(enc, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
            },
            nk.c.NK_COMMAND_CIRCLE => {
                const c: *const nk.c.struct_nk_command_circle = @ptrCast(cmd);
                const color = toAbgr(c.color);
                enc.setColor(color);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                const cx: f32 = @as(f32, @floatFromInt(c.x)) + radius;
                const cy: f32 = @as(f32, @floatFromInt(c.y)) + radius;
                enc.drawCircle(.{ 0, 0, 1 }, .{ cx, cy, 0 }, radius, 0.0);
            },
            nk.c.NK_COMMAND_CIRCLE_FILLED => {
                const c: *const nk.c.struct_nk_command_circle_filled = @ptrCast(cmd);
                const color = toAbgr(c.color);
                enc.setColor(color);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                const cx: f32 = @as(f32, @floatFromInt(c.x)) + radius;
                const cy: f32 = @as(f32, @floatFromInt(c.y)) + radius;
                // Use disk for filled circle
                enc.setWireframe(false);
                enc.drawCircle(.{ 0, 0, 1 }, .{ cx, cy, 0 }, radius, 0.0);
            },
            nk.c.NK_COMMAND_TRIANGLE => {
                const t: *const nk.c.struct_nk_command_triangle = @ptrCast(cmd);
                const color = toAbgr(t.color);
                enc.setColor(color);
                enc.setWireframe(true);
                enc.drawTriangle(
                    .{ @floatFromInt(t.a.x), @floatFromInt(t.a.y), 0 },
                    .{ @floatFromInt(t.b.x), @floatFromInt(t.b.y), 0 },
                    .{ @floatFromInt(t.c.x), @floatFromInt(t.c.y), 0 },
                );
            },
            nk.c.NK_COMMAND_TRIANGLE_FILLED => {
                const t: *const nk.c.struct_nk_command_triangle_filled = @ptrCast(cmd);
                const color = toAbgr(t.color);
                enc.setColor(color);
                enc.setWireframe(false);
                enc.drawTriangle(
                    .{ @floatFromInt(t.a.x), @floatFromInt(t.a.y), 0 },
                    .{ @floatFromInt(t.b.x), @floatFromInt(t.b.y), 0 },
                    .{ @floatFromInt(t.c.x), @floatFromInt(t.c.y), 0 },
                );
            },
            nk.c.NK_COMMAND_TEXT => {
                // bgfx debugdraw doesn't have built-in text rendering
                // Would need to use bgfx.dbgTextPrintf or custom font rendering
                // For now, skip text rendering
            },
            else => {},
        }
    }
}

fn toAbgr(color: nk.c.struct_nk_color) u32 {
    return @as(u32, color.a) << 24 |
        @as(u32, color.b) << 16 |
        @as(u32, color.g) << 8 |
        @as(u32, color.r);
}

fn drawRectLines(_: *Self, enc: *debugdraw.Encoder, x: f32, y: f32, w: f32, h: f32) void {
    enc.moveTo(.{ x, y, 0 });
    enc.lineTo(.{ x + w, y, 0 });
    enc.lineTo(.{ x + w, y + h, 0 });
    enc.lineTo(.{ x, y + h, 0 });
    enc.lineTo(.{ x, y, 0 });
}

fn drawRectFilled(_: *Self, enc: *debugdraw.Encoder, x: f32, y: f32, w: f32, h: f32) void {
    // Draw as two triangles
    const vertices = [_]debugdraw.Vertex{
        .{ .x = x, .y = y, .z = 0 },
        .{ .x = x + w, .y = y, .z = 0 },
        .{ .x = x + w, .y = y + h, .z = 0 },
        .{ .x = x, .y = y + h, .z = 0 },
    };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    enc.setWireframe(false);
    enc.drawTriList(4, &vertices, 6, &indices);
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
    var changed = false;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&self.nk_state.ctx.c, 22, 1);
        var active: bool = cb.checked;
        if (nk.c.nk_checkbox_label(&self.nk_state.ctx.c, cb.text.ptr, &active)) {
            changed = true;
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
