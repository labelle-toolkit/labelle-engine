//! Nuklear WGPU Native Adapter
//!
//! GUI backend using the Nuklear immediate-mode GUI library with wgpu_native rendering.
//! Uses Nuklear's command buffer mode to render UI elements through WebGPU.
//!
//! Build with: zig build -Dbackend=wgpu_native -Dgui_backend=nuklear

const std = @import("std");
const types = @import("types.zig");
const nk = @import("nuklear");
const wgpu = @import("wgpu");
const zglfw = @import("zglfw");
const labelle = @import("labelle");

const WgpuNativeBackend = labelle.WgpuNativeBackend;

const Self = @This();

// Global adapter reference for static callback
var g_adapter: ?*Self = null;

/// Heap-allocated Nuklear state to avoid pointer invalidation on struct move.
const NkState = struct {
    ctx: nk.Context,
    atlas: nk.FontAtlas,
    font: *nk.Font,
    null_tex: nk.NullTexture,
    atlas_finalized: bool,
};

/// Vertex format for Nuklear rendering
const NkVertex = extern struct {
    position: [2]f32, // 8 bytes
    uv: [2]f32, // 8 bytes
    color: u32, // 4 bytes (packed ABGR)
};

// Pointer to heap-allocated nuklear state
nk_state: ?*NkState,

// Allocator
allocator: std.mem.Allocator,

// Track if backend is initialized
backend_initialized: bool,

// WGPU resources
font_texture: ?*wgpu.Texture,
font_texture_view: ?*wgpu.TextureView,
font_sampler: ?*wgpu.Sampler,
pipeline: ?*wgpu.RenderPipeline,
bind_group_layout: ?*wgpu.BindGroupLayout,
bind_group: ?*wgpu.BindGroup,
vertex_buffer: ?*wgpu.Buffer,
index_buffer: ?*wgpu.Buffer,
uniform_buffer: ?*wgpu.Buffer,

// Vertex/index data built each frame
vertices: std.ArrayListUnmanaged(NkVertex),
indices: std.ArrayListUnmanaged(u32),

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

// Screen dimensions
screen_width: f32,
screen_height: f32,

// Buffer capacities
vertex_capacity: usize,
index_capacity: usize,

// WGSL shaders
const vertex_shader_wgsl =
    \\struct Uniforms {
    \\    projection: mat4x4<f32>,
    \\}
    \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\struct VertexInput {
    \\    @location(0) position: vec2<f32>,
    \\    @location(1) uv: vec2<f32>,
    \\    @location(2) color: u32,
    \\}
    \\
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\}
    \\
    \\@vertex fn main(in: VertexInput) -> VertexOutput {
    \\    var out: VertexOutput;
    \\    out.position = uniforms.projection * vec4<f32>(in.position, 0.0, 1.0);
    \\    out.uv = in.uv;
    \\    // Unpack ABGR color
    \\    let a = f32((in.color >> 24u) & 0xFFu) / 255.0;
    \\    let b = f32((in.color >> 16u) & 0xFFu) / 255.0;
    \\    let g = f32((in.color >> 8u) & 0xFFu) / 255.0;
    \\    let r = f32(in.color & 0xFFu) / 255.0;
    \\    out.color = vec4<f32>(r, g, b, a);
    \\    return out;
    \\}
;

const fragment_shader_wgsl =
    \\@group(0) @binding(1) var t_font: texture_2d<f32>;
    \\@group(0) @binding(2) var s_font: sampler;
    \\
    \\struct FragmentInput {
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\}
    \\
    \\@fragment fn main(in: FragmentInput) -> @location(0) vec4<f32> {
    \\    let tex_color = textureSample(t_font, s_font, in.uv);
    \\    return tex_color * in.color;
    \\}
;

pub fn init() Self {
    const platform = @import("../platform.zig");
    const allocator = platform.getDefaultAllocator();

    // Allocate nuklear state on the heap
    const nk_state = allocator.create(NkState) catch @panic("Failed to allocate nuklear state");

    // Initialize font atlas
    nk_state.atlas = nk.FontAtlas.initDefault();
    nk_state.atlas.begin();

    // Add default font (ProggyClean)
    nk_state.font = nk_state.atlas.addDefault(18.0, null);

    // Bake font atlas (don't finalize yet - need GPU texture first)
    _ = nk_state.atlas.bake(.rgba32);
    nk_state.atlas_finalized = false;

    std.log.info("wgpu_native Nuklear adapter: initialized", .{});

    return Self{
        .nk_state = nk_state,
        .allocator = allocator,
        .backend_initialized = false,
        .font_texture = null,
        .font_texture_view = null,
        .font_sampler = null,
        .pipeline = null,
        .bind_group_layout = null,
        .bind_group = null,
        .vertex_buffer = null,
        .index_buffer = null,
        .uniform_buffer = null,
        .vertices = .{},
        .indices = .{},
        .window_counter = 0,
        .panel_depth = 0,
        .screen_width = 800,
        .screen_height = 600,
        .vertex_capacity = 0,
        .index_capacity = 0,
    };
}

fn initBackend(self: *Self) void {
    if (self.backend_initialized) return;

    const device = WgpuNativeBackend.getDevice() orelse {
        std.log.debug("nuklear_wgpu_native: device not ready yet", .{});
        return;
    };

    const window = WgpuNativeBackend.getWindow() orelse {
        std.log.debug("nuklear_wgpu_native: window not ready yet", .{});
        return;
    };

    const format = WgpuNativeBackend.getSwapchainFormat() orelse {
        std.log.debug("nuklear_wgpu_native: swapchain format not ready yet", .{});
        return;
    };

    // Get screen size
    const fb_size = window.getFramebufferSize();
    self.screen_width = @floatFromInt(fb_size[0]);
    self.screen_height = @floatFromInt(fb_size[1]);

    // Create font texture
    self.createFontTexture(device);

    // Create render pipeline
    self.createPipeline(device, format);

    // Create initial buffers
    self.createBuffers(device);

    // Register render callback
    WgpuNativeBackend.registerGuiRenderCallback(guiRenderCallback);

    // Store global reference for callback
    g_adapter = self;

    self.backend_initialized = true;
    std.log.info("nuklear_wgpu_native: backend initialized ({}x{})", .{ @as(u32, @intFromFloat(self.screen_width)), @as(u32, @intFromFloat(self.screen_height)) });
}

fn createFontTexture(self: *Self, device: *wgpu.Device) void {
    const nk_state = self.nk_state orelse return;

    // Get baked atlas data
    const bake_result = nk_state.atlas.bake(.rgba32);
    const pixels = bake_result[0];
    const width: u32 = @intCast(bake_result[1]);
    const height: u32 = @intCast(bake_result[2]);

    // Create texture
    self.font_texture = device.createTexture(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Font Atlas"),
        .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
        .dimension = .@"2d",
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .mip_level_count = 1,
        .sample_count = 1,
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create font texture", .{});
        return;
    };

    // Upload pixels
    const queue = device.getQueue() orelse {
        std.log.err("nuklear_wgpu_native: failed to get queue", .{});
        return;
    };
    const pixel_bytes: []const u8 = @as([*]const u8, @ptrCast(pixels.ptr))[0 .. pixels.len * 4];

    queue.writeTexture(
        &.{
            .texture = self.font_texture.?,
            .mip_level = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = .all,
        },
        pixel_bytes.ptr,
        pixel_bytes.len,
        &.{
            .offset = 0,
            .bytes_per_row = width * 4,
            .rows_per_image = height,
        },
        &.{ .width = width, .height = height, .depth_or_array_layers = 1 },
    );

    // Create texture view
    self.font_texture_view = self.font_texture.?.createView(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Font Atlas View"),
        .format = .rgba8_unorm,
        .dimension = .@"2d",
        .base_mip_level = 0,
        .mip_level_count = 1,
        .base_array_layer = 0,
        .array_layer_count = 1,
        .aspect = .all,
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create font texture view", .{});
        return;
    };

    // Create sampler
    self.font_sampler = device.createSampler(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Font Sampler"),
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_filter = .linear,
        .lod_min_clamp = 0.0,
        .lod_max_clamp = 1.0,
        .compare = .undefined,
        .max_anisotropy = 1,
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create sampler", .{});
        return;
    };

    // Finalize atlas with texture handle
    nk_state.atlas.end(
        nk.Handle{ .ptr = @ptrCast(self.font_texture.?) },
        &nk_state.null_tex,
    );

    // Initialize context with font
    nk_state.ctx = nk.Context.initDefault(nk_state.font.handle());
    nk_state.atlas_finalized = true;
}

fn createPipeline(self: *Self, device: *wgpu.Device, format: wgpu.TextureFormat) void {
    // Create shader modules
    const vs_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .label = "Nuklear Vertex Shader",
        .code = vertex_shader_wgsl,
    })) orelse {
        std.log.err("nuklear_wgpu_native: failed to create vertex shader", .{});
        return;
    };
    defer vs_module.release();

    const fs_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .label = "Nuklear Fragment Shader",
        .code = fragment_shader_wgsl,
    })) orelse {
        std.log.err("nuklear_wgpu_native: failed to create fragment shader", .{});
        return;
    };
    defer fs_module.release();

    // Create bind group layout
    self.bind_group_layout = device.createBindGroupLayout(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Bind Group Layout"),
        .entry_count = 3,
        .entries = &[_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.vertex,
                .buffer = .{
                    .type = .uniform,
                    .min_binding_size = 64, // mat4x4<f32>
                },
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{
                    .sample_type = .float,
                    .view_dimension = .@"2d",
                },
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{
                    .type = .filtering,
                },
            },
        },
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create bind group layout", .{});
        return;
    };

    // Create pipeline layout
    const pipeline_layout = device.createPipelineLayout(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Pipeline Layout"),
        .bind_group_layout_count = 1,
        .bind_group_layouts = &[_]*wgpu.BindGroupLayout{self.bind_group_layout.?},
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create pipeline layout", .{});
        return;
    };
    defer pipeline_layout.release();

    // Create render pipeline
    self.pipeline = device.createRenderPipeline(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Pipeline"),
        .layout = pipeline_layout,
        .vertex = .{
            .module = vs_module,
            .entry_point = wgpu.StringView.fromSlice("main"),
            .buffer_count = 1,
            .buffers = &[_]wgpu.VertexBufferLayout{
                .{
                    .array_stride = @sizeOf(NkVertex),
                    .step_mode = .vertex,
                    .attribute_count = 3,
                    .attributes = &[_]wgpu.VertexAttribute{
                        .{ .format = .float32x2, .offset = 0, .shader_location = 0 }, // position
                        .{ .format = .float32x2, .offset = 8, .shader_location = 1 }, // uv
                        .{ .format = .uint32, .offset = 16, .shader_location = 2 }, // color
                    },
                },
            },
        },
        .fragment = &.{
            .module = fs_module,
            .entry_point = wgpu.StringView.fromSlice("main"),
            .target_count = 1,
            .targets = &[_]wgpu.ColorTargetState{
                .{
                    .format = format,
                    .blend = &.{
                        .color = .{
                            .operation = .add,
                            .src_factor = .src_alpha,
                            .dst_factor = .one_minus_src_alpha,
                        },
                        .alpha = .{
                            .operation = .add,
                            .src_factor = .one,
                            .dst_factor = .one_minus_src_alpha,
                        },
                    },
                    .write_mask = wgpu.ColorWriteMasks.all,
                },
            },
        },
        .primitive = .{
            .topology = .triangle_list,
            .strip_index_format = .undefined,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .multisample = .{
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alpha_to_coverage_enabled = 0,
        },
        .depth_stencil = null,
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create pipeline", .{});
        return;
    };
}

fn createBuffers(self: *Self, device: *wgpu.Device) void {
    // Create uniform buffer for projection matrix
    self.uniform_buffer = device.createBuffer(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Uniform Buffer"),
        .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
        .size = 64, // mat4x4<f32>
        .mapped_at_creation = 0,
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create uniform buffer", .{});
        return;
    };

    // Initial vertex/index buffer capacity
    const initial_vertex_capacity: usize = 4096;
    const initial_index_capacity: usize = 8192;

    self.vertex_buffer = device.createBuffer(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Vertex Buffer"),
        .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
        .size = @intCast(initial_vertex_capacity * @sizeOf(NkVertex)),
        .mapped_at_creation = 0,
    });
    self.vertex_capacity = initial_vertex_capacity;

    self.index_buffer = device.createBuffer(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Index Buffer"),
        .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
        .size = @intCast(initial_index_capacity * @sizeOf(u32)),
        .mapped_at_creation = 0,
    });
    self.index_capacity = initial_index_capacity;

    // Create bind group
    self.bind_group = device.createBindGroup(&.{
        .label = wgpu.StringView.fromSlice("Nuklear Bind Group"),
        .layout = self.bind_group_layout.?,
        .entry_count = 3,
        .entries = &[_]wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = self.uniform_buffer.?,
                .offset = 0,
                .size = 64,
                .sampler = null,
                .texture_view = null,
            },
            .{
                .binding = 1,
                .buffer = null,
                .offset = 0,
                .size = 0,
                .sampler = null,
                .texture_view = self.font_texture_view.?,
            },
            .{
                .binding = 2,
                .buffer = null,
                .offset = 0,
                .size = 0,
                .sampler = self.font_sampler.?,
                .texture_view = null,
            },
        },
    }) orelse {
        std.log.err("nuklear_wgpu_native: failed to create bind group", .{});
        return;
    };
}

/// Render callback invoked by WgpuNativeBackend
fn guiRenderCallback(render_pass: *wgpu.RenderPassEncoder) void {
    const self = g_adapter orelse return;
    const nk_state = self.nk_state orelse return;
    if (!nk_state.atlas_finalized) return;

    // Build vertex data from commands
    self.buildVertexData();

    const vertex_count = self.vertices.items.len;
    const index_count = self.indices.items.len;

    if (vertex_count == 0 or index_count == 0) return;

    const device = WgpuNativeBackend.getDevice() orelse return;
    const queue = device.getQueue() orelse return;

    // Resize buffers if needed
    if (vertex_count > self.vertex_capacity) {
        if (self.vertex_buffer) |buf| buf.release();
        self.vertex_capacity = vertex_count * 2;
        self.vertex_buffer = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Nuklear Vertex Buffer"),
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .size = @intCast(self.vertex_capacity * @sizeOf(NkVertex)),
            .mapped_at_creation = 0,
        });
    }

    if (index_count > self.index_capacity) {
        if (self.index_buffer) |buf| buf.release();
        self.index_capacity = index_count * 2;
        self.index_buffer = device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice("Nuklear Index Buffer"),
            .usage = wgpu.BufferUsages.index | wgpu.BufferUsages.copy_dst,
            .size = @intCast(self.index_capacity * @sizeOf(u32)),
            .mapped_at_creation = 0,
        });
    }

    // Update projection matrix
    const projection = orthoProjection(0, self.screen_width, self.screen_height, 0, -1, 1);
    queue.writeBuffer(self.uniform_buffer.?, 0, &projection, @sizeOf([16]f32));

    // Upload vertex data
    queue.writeBuffer(
        self.vertex_buffer.?,
        0,
        @ptrCast(self.vertices.items.ptr),
        vertex_count * @sizeOf(NkVertex),
    );

    // Upload index data
    queue.writeBuffer(
        self.index_buffer.?,
        0,
        @ptrCast(self.indices.items.ptr),
        index_count * @sizeOf(u32),
    );

    // Render
    render_pass.setPipeline(self.pipeline.?);
    render_pass.setBindGroup(0, self.bind_group.?, 0, null);
    render_pass.setVertexBuffer(0, self.vertex_buffer.?, 0, @intCast(vertex_count * @sizeOf(NkVertex)));
    render_pass.setIndexBuffer(self.index_buffer.?, .uint32, 0, @intCast(index_count * @sizeOf(u32)));
    render_pass.drawIndexed(@intCast(index_count), 1, 0, 0, 0);
}

fn orthoProjection(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) [16]f32 {
    const rl = right - left;
    const tb = top - bottom;
    const fn_ = far - near;

    return .{
        2.0 / rl,             0,                    0,                 0,
        0,                    2.0 / tb,             0,                 0,
        0,                    0,                    -2.0 / fn_,        0,
        -(right + left) / rl, -(top + bottom) / tb, -(far + near) / fn_, 1,
    };
}

fn buildVertexData(self: *Self) void {
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();

    const nk_state = self.nk_state orelse return;

    var cmd = nk.c.nk__begin(&nk_state.ctx.c);
    while (cmd != null) : (cmd = nk.c.nk__next(&nk_state.ctx.c, cmd)) {
        switch (cmd.*.type) {
            nk.c.NK_COMMAND_NOP => {},
            nk.c.NK_COMMAND_SCISSOR => {
                // TODO: Handle scissor with multiple draw calls
            },
            nk.c.NK_COMMAND_LINE => {
                const l: *const nk.c.struct_nk_command_line = @ptrCast(cmd);
                self.addLine(
                    @floatFromInt(l.begin.x),
                    @floatFromInt(l.begin.y),
                    @floatFromInt(l.end.x),
                    @floatFromInt(l.end.y),
                    @floatFromInt(l.line_thickness),
                    packColor(l.color),
                );
            },
            nk.c.NK_COMMAND_RECT => {
                const r: *const nk.c.struct_nk_command_rect = @ptrCast(cmd);
                self.addRectOutline(
                    @floatFromInt(r.x),
                    @floatFromInt(r.y),
                    @floatFromInt(r.w),
                    @floatFromInt(r.h),
                    @floatFromInt(r.line_thickness),
                    packColor(r.color),
                );
            },
            nk.c.NK_COMMAND_RECT_FILLED => {
                const r: *const nk.c.struct_nk_command_rect_filled = @ptrCast(cmd);
                self.addQuad(
                    @floatFromInt(r.x),
                    @floatFromInt(r.y),
                    @floatFromInt(r.w),
                    @floatFromInt(r.h),
                    packColor(r.color),
                );
            },
            nk.c.NK_COMMAND_CIRCLE => {
                const c: *const nk.c.struct_nk_command_circle = @ptrCast(cmd);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                self.addCircleOutline(
                    @as(f32, @floatFromInt(c.x)) + radius,
                    @as(f32, @floatFromInt(c.y)) + radius,
                    radius,
                    @floatFromInt(c.line_thickness),
                    packColor(c.color),
                );
            },
            nk.c.NK_COMMAND_CIRCLE_FILLED => {
                const c: *const nk.c.struct_nk_command_circle_filled = @ptrCast(cmd);
                const radius: f32 = @as(f32, @floatFromInt(c.w)) / 2.0;
                self.addCircleFilled(
                    @as(f32, @floatFromInt(c.x)) + radius,
                    @as(f32, @floatFromInt(c.y)) + radius,
                    radius,
                    packColor(c.color),
                );
            },
            nk.c.NK_COMMAND_TRIANGLE => {
                const t: *const nk.c.struct_nk_command_triangle = @ptrCast(cmd);
                self.addTriangleOutline(
                    @floatFromInt(t.a.x),
                    @floatFromInt(t.a.y),
                    @floatFromInt(t.b.x),
                    @floatFromInt(t.b.y),
                    @floatFromInt(t.c.x),
                    @floatFromInt(t.c.y),
                    @floatFromInt(t.line_thickness),
                    packColor(t.color),
                );
            },
            nk.c.NK_COMMAND_TRIANGLE_FILLED => {
                const t: *const nk.c.struct_nk_command_triangle_filled = @ptrCast(cmd);
                self.addTriangle(
                    @floatFromInt(t.a.x),
                    @floatFromInt(t.a.y),
                    @floatFromInt(t.b.x),
                    @floatFromInt(t.b.y),
                    @floatFromInt(t.c.x),
                    @floatFromInt(t.c.y),
                    packColor(t.color),
                );
            },
            nk.c.NK_COMMAND_TEXT => {
                const t: *const nk.c.struct_nk_command_text = @ptrCast(cmd);
                // For text, draw a colored rectangle as placeholder
                // Full text rendering would require glyph atlas lookup
                self.addQuad(
                    @floatFromInt(t.x),
                    @floatFromInt(t.y),
                    @floatFromInt(t.w),
                    @floatFromInt(t.h),
                    packColor(t.foreground),
                );
            },
            else => {},
        }
    }
}

fn packColor(c: nk.c.struct_nk_color) u32 {
    return @as(u32, c.a) << 24 | @as(u32, c.b) << 16 | @as(u32, c.g) << 8 | @as(u32, c.r);
}

fn addQuad(self: *Self, x: f32, y: f32, w: f32, h: f32, color: u32) void {
    const base_idx: u32 = @intCast(self.vertices.items.len);

    // Add vertices (with UV at center of white pixel in font atlas)
    self.vertices.append(self.allocator, .{ .position = .{ x, y }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x + w, y }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x + w, y + h }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x, y + h }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;

    // Add indices (two triangles)
    self.indices.append(self.allocator, base_idx + 0) catch return;
    self.indices.append(self.allocator, base_idx + 1) catch return;
    self.indices.append(self.allocator, base_idx + 2) catch return;
    self.indices.append(self.allocator, base_idx + 0) catch return;
    self.indices.append(self.allocator, base_idx + 2) catch return;
    self.indices.append(self.allocator, base_idx + 3) catch return;
}

fn addLine(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, color: u32) void {
    // Calculate perpendicular offset
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;

    const nx = -dy / len * thickness * 0.5;
    const ny = dx / len * thickness * 0.5;

    const base_idx: u32 = @intCast(self.vertices.items.len);

    self.vertices.append(self.allocator, .{ .position = .{ x1 + nx, y1 + ny }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x2 + nx, y2 + ny }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x2 - nx, y2 - ny }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x1 - nx, y1 - ny }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;

    self.indices.append(self.allocator, base_idx + 0) catch return;
    self.indices.append(self.allocator, base_idx + 1) catch return;
    self.indices.append(self.allocator, base_idx + 2) catch return;
    self.indices.append(self.allocator, base_idx + 0) catch return;
    self.indices.append(self.allocator, base_idx + 2) catch return;
    self.indices.append(self.allocator, base_idx + 3) catch return;
}

fn addRectOutline(self: *Self, x: f32, y: f32, w: f32, h: f32, thickness: f32, color: u32) void {
    // Four lines for rectangle outline
    self.addLine(x, y, x + w, y, thickness, color); // top
    self.addLine(x + w, y, x + w, y + h, thickness, color); // right
    self.addLine(x + w, y + h, x, y + h, thickness, color); // bottom
    self.addLine(x, y + h, x, y, thickness, color); // left
}

fn addTriangle(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, color: u32) void {
    const base_idx: u32 = @intCast(self.vertices.items.len);

    self.vertices.append(self.allocator, .{ .position = .{ x1, y1 }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x2, y2 }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    self.vertices.append(self.allocator, .{ .position = .{ x3, y3 }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;

    self.indices.append(self.allocator, base_idx + 0) catch return;
    self.indices.append(self.allocator, base_idx + 1) catch return;
    self.indices.append(self.allocator, base_idx + 2) catch return;
}

fn addTriangleOutline(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, thickness: f32, color: u32) void {
    self.addLine(x1, y1, x2, y2, thickness, color);
    self.addLine(x2, y2, x3, y3, thickness, color);
    self.addLine(x3, y3, x1, y1, thickness, color);
}

fn addCircleFilled(self: *Self, cx: f32, cy: f32, radius: f32, color: u32) void {
    const segments: usize = 24;
    const base_idx: u32 = @intCast(self.vertices.items.len);

    // Center vertex
    self.vertices.append(self.allocator, .{ .position = .{ cx, cy }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;

    // Perimeter vertices
    for (0..segments) |i| {
        const angle = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(segments));
        const px = cx + @cos(angle) * radius;
        const py = cy + @sin(angle) * radius;
        self.vertices.append(self.allocator, .{ .position = .{ px, py }, .uv = .{ 0.5, 0.5 }, .color = color }) catch return;
    }

    // Triangle fan indices
    for (0..segments) |i| {
        self.indices.append(self.allocator, base_idx) catch return; // center
        self.indices.append(self.allocator, base_idx + 1 + @as(u32, @intCast(i))) catch return;
        self.indices.append(self.allocator, base_idx + 1 + @as(u32, @intCast((i + 1) % segments))) catch return;
    }
}

fn addCircleOutline(self: *Self, cx: f32, cy: f32, radius: f32, thickness: f32, color: u32) void {
    const segments: usize = 24;

    for (0..segments) |i| {
        const angle1 = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(segments));
        const angle2 = @as(f32, @floatFromInt((i + 1) % segments)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(segments));

        const x1 = cx + @cos(angle1) * radius;
        const y1 = cy + @sin(angle1) * radius;
        const x2 = cx + @cos(angle2) * radius;
        const y2 = cy + @sin(angle2) * radius;

        self.addLine(x1, y1, x2, y2, thickness, color);
    }
}

pub fn fixPointers(self: *Self) void {
    // Update global reference after potential move
    g_adapter = self;
}

pub fn deinit(self: *Self) void {
    if (self.backend_initialized) {
        WgpuNativeBackend.unregisterGuiRenderCallback();
    }

    // Release WGPU resources
    if (self.bind_group) |bg| bg.release();
    if (self.vertex_buffer) |buf| buf.release();
    if (self.index_buffer) |buf| buf.release();
    if (self.uniform_buffer) |buf| buf.release();
    if (self.pipeline) |p| p.release();
    if (self.bind_group_layout) |bgl| bgl.release();
    if (self.font_sampler) |s| s.release();
    if (self.font_texture_view) |tv| tv.release();
    if (self.font_texture) |t| t.release();

    // Free vertex/index arrays
    self.vertices.deinit(self.allocator);
    self.indices.deinit(self.allocator);

    // Free Nuklear state
    if (self.nk_state) |nk_state| {
        if (nk_state.atlas_finalized) {
            nk_state.ctx.free();
        }
        nk_state.atlas.clear();
        self.allocator.destroy(nk_state);
    }

    g_adapter = null;
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Lazy init backend
    if (!self.backend_initialized) {
        self.initBackend();
    }

    if (!self.backend_initialized) return;

    const nk_state = self.nk_state orelse return;
    if (!nk_state.atlas_finalized) return;

    // Update screen size
    if (WgpuNativeBackend.getWindow()) |window| {
        const fb_size = window.getFramebufferSize();
        self.screen_width = @floatFromInt(fb_size[0]);
        self.screen_height = @floatFromInt(fb_size[1]);
    }

    // Begin input processing
    var input = nk_state.ctx.input();

    // Get mouse position from GLFW
    if (WgpuNativeBackend.getWindow()) |window| {
        const cursor_pos = window.getCursorPos();
        const mx: u31 = @intFromFloat(std.math.clamp(cursor_pos[0], 0.0, 8192.0));
        const my: u31 = @intFromFloat(std.math.clamp(cursor_pos[1], 0.0, 8192.0));
        input.motion(mx, my);

        // Mouse buttons
        input.button(.left, mx, my, window.getMouseButton(.left) == .press);
        input.button(.right, mx, my, window.getMouseButton(.right) == .press);
        input.button(.middle, mx, my, window.getMouseButton(.middle) == .press);
    }

    input.end();
}

pub fn endFrame(self: *Self) void {
    // Rendering happens in guiRenderCallback
    // Just clear the context for next frame
    if (self.nk_state) |nk_state| {
        if (nk_state.atlas_finalized) {
            nk_state.ctx.clear();
        }
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
    const nk_state = self.nk_state orelse return;
    if (!nk_state.atlas_finalized) return;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&nk_state.ctx.c, lbl.font_size, 1);
        nk.c.nk_text_colored(
            &nk_state.ctx.c,
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

        if (nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true, .no_input = true })) |win| {
            win.layoutRowDynamic(lbl.font_size, 1);
            nk.c.nk_text_colored(
                &nk_state.ctx.c,
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
    const nk_state = self.nk_state orelse return false;
    if (!nk_state.atlas_finalized) return false;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&nk_state.ctx.c, btn.size.height - 8, 1);
        return nk.c.nk_button_text(&nk_state.ctx.c, btn.text.ptr, @intCast(btn.text.len));
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
        if (nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true })) |win| {
            win.layoutRowDynamic(btn.size.height - 8, 1);
            clicked = win.buttonText(btn.text);
            win.end();
        }

        return clicked;
    }
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    const nk_state = self.nk_state orelse return;
    if (!nk_state.atlas_finalized) return;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&nk_state.ctx.c, bar.size.height - 8, 1);
        var value: nk.c.nk_size = @intFromFloat(bar.value * 100);
        _ = nk.c.nk_progress(&nk_state.ctx.c, &value, 100, false);
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const rect = nk.Rect{
            .x = bar.position.x,
            .y = bar.position.y,
            .w = bar.size.width,
            .h = bar.size.height,
        };

        if (nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true, .no_input = true })) |win| {
            win.layoutRowDynamic(bar.size.height - 8, 1);
            var value: nk.c.nk_size = @intFromFloat(bar.value * 100);
            _ = nk.c.nk_progress(&nk_state.ctx.c, &value, 100, false);
            win.end();
        }
    }
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    const nk_state = self.nk_state orelse return;
    if (!nk_state.atlas_finalized) return;

    var name_buf: [32]u8 = undefined;
    const name = self.nextWindowName(&name_buf);

    const rect = nk.Rect{
        .x = panel.position.x,
        .y = panel.position.y,
        .w = panel.size.width,
        .h = panel.size.height,
    };

    _ = nk_state.ctx.begin(name, rect, .{ .title = true, .border = true, .movable = false, .no_scrollbar = true });
    self.panel_depth += 1;
}

pub fn endPanel(self: *Self) void {
    const nk_state = self.nk_state orelse return;
    if (!nk_state.atlas_finalized) return;

    self.panel_depth -= 1;
    nk.c.nk_end(&nk_state.ctx.c);
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
    // TODO: Implement image rendering
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    const nk_state = self.nk_state orelse return false;
    if (!nk_state.atlas_finalized) return false;

    var changed = false;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&nk_state.ctx.c, 22, 1);
        var active: bool = cb.checked;
        if (nk.c.nk_checkbox_label(&nk_state.ctx.c, cb.text.ptr, &active)) {
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

        if (nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true })) |win| {
            win.layoutRowDynamic(22, 1);
            var active: bool = cb.checked;
            if (nk.c.nk_checkbox_label(&nk_state.ctx.c, cb.text.ptr, &active)) {
                changed = true;
            }
            win.end();
        }
    }

    return changed;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    const nk_state = self.nk_state orelse return sl.value;
    if (!nk_state.atlas_finalized) return sl.value;

    var value = sl.value;
    const range = sl.max - sl.min;
    const step = range / 100.0;

    if (self.panel_depth > 0) {
        nk.c.nk_layout_row_dynamic(&nk_state.ctx.c, sl.size.height - 8, 1);
        value = nk.c.nk_slide_float(&nk_state.ctx.c, sl.min, value, sl.max, step);
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const rect = nk.Rect{
            .x = sl.position.x,
            .y = sl.position.y,
            .w = sl.size.width,
            .h = sl.size.height,
        };

        if (nk_state.ctx.begin(name, rect, .{ .no_scrollbar = true, .background = true })) |win| {
            win.layoutRowDynamic(sl.size.height - 8, 1);
            value = nk.c.nk_slide_float(&nk_state.ctx.c, sl.min, value, sl.max, step);
            win.end();
        }
    }

    return value;
}
