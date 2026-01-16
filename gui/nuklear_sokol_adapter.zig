//! Nuklear Sokol Adapter
//!
//! GUI backend using the Nuklear immediate-mode GUI library with sokol rendering.
//! Uses sokol-gl (sgl) for drawing primitives and sokol-debugtext for text.
//!
//! Build with: zig build -Dbackend=sokol -Dgui_backend=nuklear

const std = @import("std");
const types = @import("types.zig");
const nk = @import("nuklear");
const sokol = @import("sokol");
const sgl = sokol.gl;
const sdtx = sokol.debugtext;
const sapp = sokol.app;
const sg = sokol.gfx;

const Self = @This();

/// Heap-allocated Nuklear state to avoid pointer invalidation on struct move.
const NkState = struct {
    ctx: nk.Context,
    atlas: nk.FontAtlas,
    font: *nk.Font,
    null_tex: nk.NullTexture,
};

// Pointer to heap-allocated nuklear state (stable address)
nk_state: *NkState,

// Font texture for atlas
font_image: sg.Image,
font_sampler: sg.Sampler,

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

// Screen dimensions for coordinate mapping
screen_width: f32,
screen_height: f32,

const platform = @import("../platform.zig");
const allocator = platform.getDefaultAllocator();

pub fn init() Self {
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
    const width = bake_result[1];
    const height = bake_result[2];

    // Create sokol-gfx image from baked atlas
    var img_desc: sg.ImageDesc = .{};
    img_desc.width = @intCast(width);
    img_desc.height = @intCast(height);
    img_desc.pixel_format = .RGBA8;
    img_desc.data.mip_levels[0] = .{
        .ptr = @ptrCast(pixels.ptr),
        .size = @as(usize, width) * @as(usize, height) * 4,
    };
    const font_image = sg.makeImage(img_desc);

    // Create sampler
    var smp_desc: sg.SamplerDesc = .{};
    smp_desc.min_filter = .LINEAR;
    smp_desc.mag_filter = .LINEAR;
    const font_sampler = sg.makeSampler(smp_desc);

    // End atlas baking with texture handle
    nk_state.atlas.end(
        nk.Handle{ .id = @intCast(font_image.id) },
        &nk_state.null_tex,
    );

    // Initialize context with font
    nk_state.ctx = nk.Context.initDefault(nk_state.font.handle());

    // Initialize sokol-debugtext for text rendering
    sdtx.setup(.{
        .fonts = .{
            sdtx.fontKc853(),
            sdtx.fontKc854(),
            sdtx.fontZ1013(),
            sdtx.fontCpc(),
            sdtx.fontC64(),
            sdtx.fontOric(),
            .{}, .{},
        },
        .logger = .{ .func = sokol.log.func },
    });

    return Self{
        .nk_state = nk_state,
        .font_image = font_image,
        .font_sampler = font_sampler,
        .window_counter = 0,
        .panel_depth = 0,
        .screen_width = @floatFromInt(sapp.width()),
        .screen_height = @floatFromInt(sapp.height()),
    };
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    self.nk_state.ctx.free();
    self.nk_state.atlas.clear();
    sg.destroyImage(self.font_image);
    sg.destroySampler(self.font_sampler);
    sdtx.shutdown();
    allocator.destroy(self.nk_state);
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Update screen dimensions
    self.screen_width = @floatFromInt(sapp.width());
    self.screen_height = @floatFromInt(sapp.height());

    // Begin nuklear input
    var input = self.nk_state.ctx.input();

    // Get mouse position from sokol-app
    // Note: In sokol, mouse position is tracked via events, not polling
    // This is handled through the event callback
    // For now, use a simple approach with last known position

    input.end();

    // Setup sokol-debugtext canvas
    sdtx.canvas(self.screen_width / 2.0, self.screen_height / 2.0);
    sdtx.origin(0, 0);
}

pub fn endFrame(self: *Self) void {
    // Set up sokol-gl for 2D rendering
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.loadIdentity();
    sgl.ortho(0, self.screen_width, self.screen_height, 0, -1.0, 1.0);
    sgl.matrixModeModelview();
    sgl.loadIdentity();

    // Render nuklear command buffer
    self.renderCommandBuffer();

    // Clear nuklear context
    self.nk_state.ctx.clear();
}

fn renderCommandBuffer(self: *Self) void {
    var cmd = nk.c.nk__begin(&self.nk_state.ctx.c);
    while (cmd != null) : (cmd = nk.c.nk__next(&self.nk_state.ctx.c, cmd)) {
        switch (cmd.*.type) {
            nk.c.NK_COMMAND_NOP => {},
            nk.c.NK_COMMAND_SCISSOR => {
                const s: *const nk.c.struct_nk_command_scissor = @ptrCast(cmd);
                if (s.w > 0 and s.h > 0) {
                    sgl.scissorRect(s.x, s.y, @intCast(s.w), @intCast(s.h), true);
                }
            },
            nk.c.NK_COMMAND_LINE => {
                const l: *const nk.c.struct_nk_command_line = @ptrCast(cmd);
                self.drawLine(
                    @floatFromInt(l.begin.x),
                    @floatFromInt(l.begin.y),
                    @floatFromInt(l.end.x),
                    @floatFromInt(l.end.y),
                    l.color,
                );
            },
            nk.c.NK_COMMAND_RECT => {
                const r: *const nk.c.struct_nk_command_rect = @ptrCast(cmd);
                self.drawRectLines(
                    @floatFromInt(r.x),
                    @floatFromInt(r.y),
                    @floatFromInt(r.w),
                    @floatFromInt(r.h),
                    r.color,
                );
            },
            nk.c.NK_COMMAND_RECT_FILLED => {
                const r: *const nk.c.struct_nk_command_rect_filled = @ptrCast(cmd);
                self.drawRectFilled(
                    @floatFromInt(r.x),
                    @floatFromInt(r.y),
                    @floatFromInt(r.w),
                    @floatFromInt(r.h),
                    r.color,
                );
            },
            nk.c.NK_COMMAND_CIRCLE => {
                const c: *const nk.c.struct_nk_command_circle = @ptrCast(cmd);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                self.drawCircleLines(
                    @as(f32, @floatFromInt(c.x)) + radius,
                    @as(f32, @floatFromInt(c.y)) + radius,
                    radius,
                    c.color,
                );
            },
            nk.c.NK_COMMAND_CIRCLE_FILLED => {
                const c: *const nk.c.struct_nk_command_circle_filled = @ptrCast(cmd);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                self.drawCircleFilled(
                    @as(f32, @floatFromInt(c.x)) + radius,
                    @as(f32, @floatFromInt(c.y)) + radius,
                    radius,
                    c.color,
                );
            },
            nk.c.NK_COMMAND_TRIANGLE => {
                const t: *const nk.c.struct_nk_command_triangle = @ptrCast(cmd);
                self.drawTriangleLines(
                    @floatFromInt(t.a.x),
                    @floatFromInt(t.a.y),
                    @floatFromInt(t.b.x),
                    @floatFromInt(t.b.y),
                    @floatFromInt(t.c.x),
                    @floatFromInt(t.c.y),
                    t.color,
                );
            },
            nk.c.NK_COMMAND_TRIANGLE_FILLED => {
                const t: *const nk.c.struct_nk_command_triangle_filled = @ptrCast(cmd);
                self.drawTriangleFilled(
                    @floatFromInt(t.a.x),
                    @floatFromInt(t.a.y),
                    @floatFromInt(t.b.x),
                    @floatFromInt(t.b.y),
                    @floatFromInt(t.c.x),
                    @floatFromInt(t.c.y),
                    t.color,
                );
            },
            nk.c.NK_COMMAND_TEXT => {
                const t: *const nk.c.struct_nk_command_text = @ptrCast(cmd);
                self.drawText(t);
            },
            else => {},
        }
    }
}

fn drawLine(_: *Self, x0: f32, y0: f32, x1: f32, y1: f32, color: nk.c.struct_nk_color) void {
    sgl.beginLines();
    sgl.c4b(color.r, color.g, color.b, color.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y1);
    sgl.end();
}

fn drawRectLines(_: *Self, x: f32, y: f32, w: f32, h: f32, color: nk.c.struct_nk_color) void {
    sgl.beginLineStrip();
    sgl.c4b(color.r, color.g, color.b, color.a);
    sgl.v2f(x, y);
    sgl.v2f(x + w, y);
    sgl.v2f(x + w, y + h);
    sgl.v2f(x, y + h);
    sgl.v2f(x, y);
    sgl.end();
}

fn drawRectFilled(_: *Self, x: f32, y: f32, w: f32, h: f32, color: nk.c.struct_nk_color) void {
    sgl.beginQuads();
    sgl.c4b(color.r, color.g, color.b, color.a);
    sgl.v2f(x, y);
    sgl.v2f(x + w, y);
    sgl.v2f(x + w, y + h);
    sgl.v2f(x, y + h);
    sgl.end();
}

fn drawCircleLines(_: *Self, cx: f32, cy: f32, radius: f32, color: nk.c.struct_nk_color) void {
    const segments = 32;
    sgl.beginLineStrip();
    sgl.c4b(color.r, color.g, color.b, color.a);
    for (0..segments + 1) |i| {
        const angle = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, segments);
        sgl.v2f(cx + @cos(angle) * radius, cy + @sin(angle) * radius);
    }
    sgl.end();
}

fn drawCircleFilled(_: *Self, cx: f32, cy: f32, radius: f32, color: nk.c.struct_nk_color) void {
    const segments = 32;
    sgl.beginTriangles();
    sgl.c4b(color.r, color.g, color.b, color.a);
    for (0..segments) |i| {
        const angle1 = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, segments);
        const angle2 = @as(f32, @floatFromInt(i + 1)) * 2.0 * std.math.pi / @as(f32, segments);
        sgl.v2f(cx, cy);
        sgl.v2f(cx + @cos(angle1) * radius, cy + @sin(angle1) * radius);
        sgl.v2f(cx + @cos(angle2) * radius, cy + @sin(angle2) * radius);
    }
    sgl.end();
}

fn drawTriangleLines(_: *Self, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, color: nk.c.struct_nk_color) void {
    sgl.beginLineStrip();
    sgl.c4b(color.r, color.g, color.b, color.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x2, y2);
    sgl.v2f(x0, y0);
    sgl.end();
}

fn drawTriangleFilled(_: *Self, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, color: nk.c.struct_nk_color) void {
    sgl.beginTriangles();
    sgl.c4b(color.r, color.g, color.b, color.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x2, y2);
    sgl.end();
}

fn drawText(self: *Self, t: *const nk.c.struct_nk_command_text) void {
    // Use sokol-debugtext for text rendering
    const text_ptr: [*]const u8 = @ptrCast(&t.string);
    const text_len: usize = @intCast(t.length);

    // Position text in character grid coordinates (8x8 pixels per character)
    const char_x = @as(f32, @floatFromInt(t.x)) / 8.0;
    const char_y = @as(f32, @floatFromInt(t.y)) / 8.0;

    sdtx.pos(char_x, char_y);
    sdtx.color4b(t.foreground.r, t.foreground.g, t.foreground.b, t.foreground.a);

    // Output each character
    for (0..text_len) |i| {
        sdtx.putc(text_ptr[i]);
    }

    _ = self;
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
    // TODO: Implement image rendering
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
