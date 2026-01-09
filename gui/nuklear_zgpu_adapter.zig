//! Nuklear ZGPU Adapter
//!
//! GUI backend using the Nuklear immediate-mode GUI library with zgpu (WebGPU) rendering.
//! Uses batched vertex rendering for primitives.
//!
//! Build with: zig build -Dbackend=zgpu -Dgui_backend=nuklear

const std = @import("std");
const types = @import("types.zig");
const nk = @import("nuklear");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const Self = @This();

/// Heap-allocated Nuklear state to avoid pointer invalidation on struct move.
const NkState = struct {
    ctx: nk.Context,
    atlas: nk.FontAtlas,
    font: *nk.Font,
    null_tex: nk.NullTexture,
};

/// Vertex for colored primitives
const ColorVertex = extern struct {
    position: [2]f32,
    color: u32,

    fn init(x: f32, y: f32, color: u32) ColorVertex {
        return .{ .position = .{ x, y }, .color = color };
    }
};

// Pointer to heap-allocated nuklear state
nk_state: *NkState,

// Font texture
font_texture: ?wgpu.Texture,
font_texture_view: ?wgpu.TextureView,

// Vertex and index buffers for batched rendering
vertices: std.ArrayList(ColorVertex),
indices: std.ArrayList(u32),

// GPU buffers
vertex_buffer: ?wgpu.Buffer,
index_buffer: ?wgpu.Buffer,
vertex_buffer_size: usize,
index_buffer_size: usize,

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

// Graphics context reference
gctx: ?*zgpu.GraphicsContext,

const allocator = std.heap.page_allocator;

pub fn init() Self {
    // Allocate nuklear state on the heap
    const nk_state = allocator.create(NkState) catch @panic("Failed to allocate nuklear state");

    // Initialize font atlas
    nk_state.atlas = nk.FontAtlas.initDefault();
    nk_state.atlas.begin();

    // Add default font
    nk_state.font = nk_state.atlas.addDefault(18.0, null);

    // Bake font atlas - texture will be created when graphics context is available
    const bake_result = nk_state.atlas.bake(.rgba32);
    _ = bake_result;

    // End atlas baking with null texture handle for now
    nk_state.atlas.end(
        nk.Handle{ .id = 0 },
        &nk_state.null_tex,
    );

    // Initialize context with font
    nk_state.ctx = nk.Context.initDefault(nk_state.font.handle());

    return Self{
        .nk_state = nk_state,
        .font_texture = null,
        .font_texture_view = null,
        .vertices = std.ArrayList(ColorVertex).init(allocator),
        .indices = std.ArrayList(u32).init(allocator),
        .vertex_buffer = null,
        .index_buffer = null,
        .vertex_buffer_size = 0,
        .index_buffer_size = 0,
        .window_counter = 0,
        .panel_depth = 0,
        .gctx = null,
    };
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    self.nk_state.ctx.free();
    self.nk_state.atlas.clear();

    if (self.font_texture_view) |view| view.release();
    if (self.font_texture) |tex| tex.release();
    if (self.vertex_buffer) |buf| buf.release();
    if (self.index_buffer) |buf| buf.release();

    self.vertices.deinit();
    self.indices.deinit();
    allocator.destroy(self.nk_state);
}

/// Set the graphics context for rendering
pub fn setGraphicsContext(self: *Self, gctx: *zgpu.GraphicsContext) void {
    self.gctx = gctx;
    self.createFontTexture();
}

fn createFontTexture(self: *Self) void {
    const gctx = self.gctx orelse return;

    // Re-bake atlas to get pixel data
    const bake_result = self.nk_state.atlas.bake(.rgba32);
    const pixels = bake_result[0];
    const width: u32 = @intCast(bake_result[1]);
    const height: u32 = @intCast(bake_result[2]);

    // Create texture
    self.font_texture = gctx.device.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .mip_level_count = 1,
        .sample_count = 1,
    });

    if (self.font_texture) |tex| {
        // Upload pixel data
        gctx.queue.writeTexture(
            .{ .texture = tex },
            pixels,
            .{ .bytes_per_row = width * 4, .rows_per_image = height },
            .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        );

        // Create texture view
        self.font_texture_view = tex.createView(&.{});
    }
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Clear vertex/index buffers
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();

    // Begin nuklear input
    var input = self.nk_state.ctx.input();
    input.end();
}

pub fn endFrame(self: *Self) void {
    // Render nuklear command buffer to vertex/index lists
    self.renderCommandBuffer();

    // Upload to GPU if we have vertices
    if (self.vertices.items.len > 0) {
        self.uploadBuffers();
    }

    // Clear nuklear context
    self.nk_state.ctx.clear();
}

fn renderCommandBuffer(self: *Self) void {
    var cmd = nk.c.nk__begin(&self.nk_state.ctx.c);
    while (cmd != null) : (cmd = nk.c.nk__next(&self.nk_state.ctx.c, cmd)) {
        switch (cmd.*.type) {
            nk.c.NK_COMMAND_NOP => {},
            nk.c.NK_COMMAND_SCISSOR => {
                // Scissor would require render pass management
            },
            nk.c.NK_COMMAND_LINE => {
                const l: *const nk.c.struct_nk_command_line = @ptrCast(cmd);
                const color = toAbgr(l.color);
                self.addLine(
                    @floatFromInt(l.begin.x),
                    @floatFromInt(l.begin.y),
                    @floatFromInt(l.end.x),
                    @floatFromInt(l.end.y),
                    @floatFromInt(l.line_thickness),
                    color,
                );
            },
            nk.c.NK_COMMAND_RECT => {
                const r: *const nk.c.struct_nk_command_rect = @ptrCast(cmd);
                const color = toAbgr(r.color);
                self.addRectangleLines(
                    @floatFromInt(r.x),
                    @floatFromInt(r.y),
                    @floatFromInt(r.w),
                    @floatFromInt(r.h),
                    color,
                );
            },
            nk.c.NK_COMMAND_RECT_FILLED => {
                const r: *const nk.c.struct_nk_command_rect_filled = @ptrCast(cmd);
                const color = toAbgr(r.color);
                self.addRectangle(
                    @floatFromInt(r.x),
                    @floatFromInt(r.y),
                    @floatFromInt(r.w),
                    @floatFromInt(r.h),
                    color,
                );
            },
            nk.c.NK_COMMAND_CIRCLE => {
                const c: *const nk.c.struct_nk_command_circle = @ptrCast(cmd);
                const color = toAbgr(c.color);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                const cx: f32 = @as(f32, @floatFromInt(c.x)) + radius;
                const cy: f32 = @as(f32, @floatFromInt(c.y)) + radius;
                self.addCircleLines(cx, cy, radius, color);
            },
            nk.c.NK_COMMAND_CIRCLE_FILLED => {
                const c: *const nk.c.struct_nk_command_circle_filled = @ptrCast(cmd);
                const color = toAbgr(c.color);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                const cx: f32 = @as(f32, @floatFromInt(c.x)) + radius;
                const cy: f32 = @as(f32, @floatFromInt(c.y)) + radius;
                self.addCircle(cx, cy, radius, color);
            },
            nk.c.NK_COMMAND_TRIANGLE => {
                const t: *const nk.c.struct_nk_command_triangle = @ptrCast(cmd);
                const color = toAbgr(t.color);
                self.addTriangleLines(
                    @floatFromInt(t.a.x),
                    @floatFromInt(t.a.y),
                    @floatFromInt(t.b.x),
                    @floatFromInt(t.b.y),
                    @floatFromInt(t.c.x),
                    @floatFromInt(t.c.y),
                    color,
                );
            },
            nk.c.NK_COMMAND_TRIANGLE_FILLED => {
                const t: *const nk.c.struct_nk_command_triangle_filled = @ptrCast(cmd);
                const color = toAbgr(t.color);
                self.addTriangle(
                    @floatFromInt(t.a.x),
                    @floatFromInt(t.a.y),
                    @floatFromInt(t.b.x),
                    @floatFromInt(t.b.y),
                    @floatFromInt(t.c.x),
                    @floatFromInt(t.c.y),
                    color,
                );
            },
            nk.c.NK_COMMAND_TEXT => {
                // Text rendering requires font atlas texture binding
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

fn addRectangle(self: *Self, x: f32, y: f32, w: f32, h: f32, color: u32) void {
    const base_idx: u32 = @intCast(self.vertices.items.len);

    // Add 4 vertices for rectangle
    self.vertices.append(ColorVertex.init(x, y, color)) catch return;
    self.vertices.append(ColorVertex.init(x + w, y, color)) catch return;
    self.vertices.append(ColorVertex.init(x + w, y + h, color)) catch return;
    self.vertices.append(ColorVertex.init(x, y + h, color)) catch return;

    // Add 6 indices for 2 triangles
    self.indices.append(base_idx + 0) catch return;
    self.indices.append(base_idx + 1) catch return;
    self.indices.append(base_idx + 2) catch return;
    self.indices.append(base_idx + 0) catch return;
    self.indices.append(base_idx + 2) catch return;
    self.indices.append(base_idx + 3) catch return;
}

fn addRectangleLines(self: *Self, x: f32, y: f32, w: f32, h: f32, color: u32) void {
    self.addLine(x, y, x + w, y, 1, color);
    self.addLine(x + w, y, x + w, y + h, 1, color);
    self.addLine(x + w, y + h, x, y + h, 1, color);
    self.addLine(x, y + h, x, y, 1, color);
}

fn addLine(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, color: u32) void {
    // Calculate perpendicular for line thickness
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;

    const half_thick = @max(thickness, 1.0) / 2.0;
    const nx = -dy / len * half_thick;
    const ny = dx / len * half_thick;

    const base_idx: u32 = @intCast(self.vertices.items.len);

    // Add 4 vertices for thick line quad
    self.vertices.append(ColorVertex.init(x1 + nx, y1 + ny, color)) catch return;
    self.vertices.append(ColorVertex.init(x1 - nx, y1 - ny, color)) catch return;
    self.vertices.append(ColorVertex.init(x2 - nx, y2 - ny, color)) catch return;
    self.vertices.append(ColorVertex.init(x2 + nx, y2 + ny, color)) catch return;

    // Add 6 indices for 2 triangles
    self.indices.append(base_idx + 0) catch return;
    self.indices.append(base_idx + 1) catch return;
    self.indices.append(base_idx + 2) catch return;
    self.indices.append(base_idx + 0) catch return;
    self.indices.append(base_idx + 2) catch return;
    self.indices.append(base_idx + 3) catch return;
}

fn addCircle(self: *Self, cx: f32, cy: f32, radius: f32, color: u32) void {
    const segments: u32 = 32;
    const center_idx: u32 = @intCast(self.vertices.items.len);

    // Add center vertex
    self.vertices.append(ColorVertex.init(cx, cy, color)) catch return;

    // Add perimeter vertices
    for (0..segments) |i| {
        const angle = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, segments);
        const px = cx + @cos(angle) * radius;
        const py = cy + @sin(angle) * radius;
        self.vertices.append(ColorVertex.init(px, py, color)) catch return;
    }

    // Add triangles (fan from center)
    for (0..segments) |i| {
        const idx1: u32 = @intCast(i);
        const idx2: u32 = @intCast((i + 1) % segments);
        self.indices.append(center_idx) catch return;
        self.indices.append(center_idx + 1 + idx1) catch return;
        self.indices.append(center_idx + 1 + idx2) catch return;
    }
}

fn addCircleLines(self: *Self, cx: f32, cy: f32, radius: f32, color: u32) void {
    const segments: u32 = 32;

    for (0..segments) |i| {
        const angle1 = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, segments);
        const angle2 = @as(f32, @floatFromInt(i + 1)) * 2.0 * std.math.pi / @as(f32, segments);
        const x1 = cx + @cos(angle1) * radius;
        const y1 = cy + @sin(angle1) * radius;
        const x2 = cx + @cos(angle2) * radius;
        const y2 = cy + @sin(angle2) * radius;
        self.addLine(x1, y1, x2, y2, 1, color);
    }
}

fn addTriangle(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, color: u32) void {
    const base_idx: u32 = @intCast(self.vertices.items.len);

    self.vertices.append(ColorVertex.init(x1, y1, color)) catch return;
    self.vertices.append(ColorVertex.init(x2, y2, color)) catch return;
    self.vertices.append(ColorVertex.init(x3, y3, color)) catch return;

    self.indices.append(base_idx + 0) catch return;
    self.indices.append(base_idx + 1) catch return;
    self.indices.append(base_idx + 2) catch return;
}

fn addTriangleLines(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, color: u32) void {
    self.addLine(x1, y1, x2, y2, 1, color);
    self.addLine(x2, y2, x3, y3, 1, color);
    self.addLine(x3, y3, x1, y1, 1, color);
}

fn uploadBuffers(self: *Self) void {
    const gctx = self.gctx orelse return;

    const vertex_size = self.vertices.items.len * @sizeOf(ColorVertex);
    const index_size = self.indices.items.len * @sizeOf(u32);

    // Recreate vertex buffer if needed
    if (self.vertex_buffer == null or self.vertex_buffer_size < vertex_size) {
        if (self.vertex_buffer) |buf| buf.release();
        self.vertex_buffer = gctx.device.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @max(vertex_size, 1024 * @sizeOf(ColorVertex)),
        });
        self.vertex_buffer_size = @max(vertex_size, 1024 * @sizeOf(ColorVertex));
    }

    // Recreate index buffer if needed
    if (self.index_buffer == null or self.index_buffer_size < index_size) {
        if (self.index_buffer) |buf| buf.release();
        self.index_buffer = gctx.device.createBuffer(.{
            .usage = .{ .index = true, .copy_dst = true },
            .size = @max(index_size, 4096 * @sizeOf(u32)),
        });
        self.index_buffer_size = @max(index_size, 4096 * @sizeOf(u32));
    }

    // Upload data
    if (self.vertex_buffer) |buf| {
        gctx.queue.writeBuffer(buf, 0, ColorVertex, self.vertices.items);
    }
    if (self.index_buffer) |buf| {
        gctx.queue.writeBuffer(buf, 0, u32, self.indices.items);
    }
}

/// Get vertex buffer for rendering
pub fn getVertexBuffer(self: *Self) ?wgpu.Buffer {
    return self.vertex_buffer;
}

/// Get index buffer for rendering
pub fn getIndexBuffer(self: *Self) ?wgpu.Buffer {
    return self.index_buffer;
}

/// Get index count for rendering
pub fn getIndexCount(self: *Self) u32 {
    return @intCast(self.indices.items.len);
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
