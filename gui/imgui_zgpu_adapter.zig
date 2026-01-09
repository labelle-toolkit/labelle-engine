//! ImGui zgpu/WebGPU Adapter
//!
//! GUI backend using Dear ImGui with zgpu/GLFW+WebGPU rendering.
//! Uses zgui for Zig bindings to ImGui and integrates with ZgpuBackend's
//! GUI render callback system for proper render pass access.
//!
//! Build with: zig build -Dbackend=zgpu -Dgui_backend=imgui

const std = @import("std");
const types = @import("types.zig");
const zgui = @import("zgui");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const labelle = @import("labelle");
const zglfw = @import("zglfw");

const ZgpuBackend = labelle.ZgpuBackend;

// Module-level flag for callback to check if ImGui is ready
var imgui_ready: bool = false;

/// GUI render callback that gets called by ZgpuBackend with an active render pass.
/// This allows ImGui to render into the same render pass as the game graphics.
fn guiRenderCallback(render_pass: wgpu.RenderPassEncoder) void {
    if (!imgui_ready) return;

    // Draw ImGui using the provided render pass
    zgui.backend.draw(@ptrCast(&render_pass));
}

const Self = @This();

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

// Allocator for zgui
allocator: std.mem.Allocator,

// Track if backend is initialized
backend_initialized: bool,

// Framebuffer size
fb_width: u32,
fb_height: u32,

pub fn init() Self {
    const allocator = std.heap.page_allocator;

    // Initialize zgui core (not the backend yet - that needs zgpu context)
    zgui.init(allocator);

    return Self{
        .window_counter = 0,
        .panel_depth = 0,
        .allocator = allocator,
        .backend_initialized = false,
        .fb_width = 800,
        .fb_height = 600,
    };
}

fn initBackend(self: *Self) void {
    if (self.backend_initialized) return;

    // Get zgpu graphics context from labelle-gfx
    const gctx = ZgpuBackend.getGraphicsContext() orelse {
        return;
    };

    // Get GLFW window from the window provider
    const window_ptr = gctx.window_provider.window;

    // Get framebuffer size from the window provider
    const fb_size = gctx.window_provider.fn_getFramebufferSize(window_ptr);
    self.fb_width = fb_size[0];
    self.fb_height = fb_size[1];

    // Get swapchain format
    const swapchain_format: u32 = @intFromEnum(zgpu.GraphicsContext.swapchain_format);

    // Initialize zgui backend with GLFW + WebGPU
    zgui.backend.init(
        window_ptr, // GLFW window (as *anyopaque)
        @ptrCast(gctx.device), // WGPU device (opaque pointer)
        swapchain_format, // Swapchain format
        0, // No depth format (2D GUI)
    );

    // Register our render callback with ZgpuBackend
    ZgpuBackend.registerGuiRenderCallback(guiRenderCallback);

    self.backend_initialized = true;
    std.log.info("imgui_zgpu: backend initialized with render callback", .{});
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    // Disable rendering first
    imgui_ready = false;

    if (self.backend_initialized) {
        // Unregister the render callback
        ZgpuBackend.unregisterGuiRenderCallback();
        zgui.backend.deinit();
    }
    zgui.deinit();
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Lazy init backend on first frame
    if (!self.backend_initialized) {
        self.initBackend();
    }

    if (!self.backend_initialized) return;

    // Update framebuffer size
    if (ZgpuBackend.getGraphicsContext()) |gctx| {
        const fb_size = gctx.window_provider.fn_getFramebufferSize(gctx.window_provider.window);
        self.fb_width = fb_size[0];
        self.fb_height = fb_size[1];
    }

    // Start new ImGui frame
    zgui.backend.newFrame(self.fb_width, self.fb_height);
    zgui.newFrame();
}

pub fn endFrame(self: *Self) void {
    if (!self.backend_initialized) return;

    // Finalize ImGui frame - prepares draw lists
    zgui.render();

    // Signal that ImGui is ready for rendering
    // The actual rendering happens in guiRenderCallback when ZgpuBackend
    // calls it with an active render pass during endDrawing()
    imgui_ready = true;
}

fn nextWindowName(self: *Self, buf: []u8) [:0]const u8 {
    self.window_counter += 1;
    const result = std.fmt.bufPrintZ(buf, "##w{d}", .{self.window_counter}) catch {
        buf[0] = '#';
        buf[1] = '#';
        buf[2] = 'w';
        buf[3] = 0;
        return buf[0..3 :0];
    };
    return result;
}

pub fn label(self: *Self, lbl: types.Label) void {
    if (!self.backend_initialized) return;

    if (self.panel_depth > 0) {
        zgui.textColored(
            .{ @as(f32, @floatFromInt(lbl.color.r)) / 255.0, @as(f32, @floatFromInt(lbl.color.g)) / 255.0, @as(f32, @floatFromInt(lbl.color.b)) / 255.0, @as(f32, @floatFromInt(lbl.color.a)) / 255.0 },
            "{s}",
            .{lbl.text},
        );
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = lbl.position.x, .y = lbl.position.y });
        const text_size = zgui.calcTextSize(lbl.text, .{});
        zgui.setNextWindowSize(.{ .w = text_size[0] + 16, .h = lbl.font_size + 8 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
                .no_mouse_inputs = true,
            },
        })) {
            zgui.textColored(
                .{ @as(f32, @floatFromInt(lbl.color.r)) / 255.0, @as(f32, @floatFromInt(lbl.color.g)) / 255.0, @as(f32, @floatFromInt(lbl.color.b)) / 255.0, @as(f32, @floatFromInt(lbl.color.a)) / 255.0 },
                "{s}",
                .{lbl.text},
            );
        }
        zgui.end();
    }
}

pub fn button(self: *Self, btn: types.Button) bool {
    if (!self.backend_initialized) return false;

    // Convert text to null-terminated
    var text_buf: [256]u8 = undefined;
    const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{btn.text}) catch return false;

    if (self.panel_depth > 0) {
        return zgui.button(text_z, .{ .w = btn.size.width, .h = btn.size.height });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = btn.position.x, .y = btn.position.y });
        zgui.setNextWindowSize(.{ .w = btn.size.width + 16, .h = btn.size.height + 16 });

        var clicked = false;
        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            clicked = zgui.button(text_z, .{ .w = btn.size.width, .h = btn.size.height });
        }
        zgui.end();

        return clicked;
    }
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    if (!self.backend_initialized) return;

    if (self.panel_depth > 0) {
        zgui.progressBar(.{
            .fraction = bar.value,
            .overlay = "",
            .w = bar.size.width,
            .h = bar.size.height,
        });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = bar.position.x, .y = bar.position.y });
        zgui.setNextWindowSize(.{ .w = bar.size.width + 16, .h = bar.size.height + 16 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            zgui.progressBar(.{
                .fraction = bar.value,
                .overlay = "",
                .w = bar.size.width,
                .h = bar.size.height,
            });
        }
        zgui.end();
    }
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    if (!self.backend_initialized) return;

    var name_buf: [32]u8 = undefined;
    const name = self.nextWindowName(&name_buf);

    zgui.setNextWindowPos(.{ .x = panel.position.x, .y = panel.position.y });
    zgui.setNextWindowSize(.{ .w = panel.size.width, .h = panel.size.height });

    _ = zgui.begin(name, .{
        .flags = .{
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
        },
    });
    self.panel_depth += 1;
}

pub fn endPanel(self: *Self) void {
    if (!self.backend_initialized) return;

    self.panel_depth -= 1;
    zgui.end();
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    if (!self.backend_initialized) return cb.checked;

    var checked = cb.checked;

    // Convert text to null-terminated
    var text_buf: [256]u8 = undefined;
    const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{cb.text}) catch return checked;

    if (self.panel_depth > 0) {
        _ = zgui.checkbox(text_z, .{ .v = &checked });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const text_len: usize = cb.text.len;
        zgui.setNextWindowPos(.{ .x = cb.position.x, .y = cb.position.y });
        const text_size = zgui.calcTextSize(cb.text, .{});
        zgui.setNextWindowSize(.{ .w = text_size[0] + 50, .h = 40 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            _ = zgui.checkbox(text_z, .{ .v = &checked });
        }
        zgui.end();
    }

    return checked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    if (!self.backend_initialized) return sl.value;

    var value = sl.value;

    if (self.panel_depth > 0) {
        _ = zgui.sliderFloat("##slider", .{
            .v = &value,
            .min = sl.min,
            .max = sl.max,
        });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = sl.position.x, .y = sl.position.y });
        zgui.setNextWindowSize(.{ .w = sl.size.width + 16, .h = sl.size.height + 16 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            _ = zgui.sliderFloat("##slider", .{
                .v = &value,
                .min = sl.min,
                .max = sl.max,
            });
        }
        zgui.end();
    }

    return value;
}
