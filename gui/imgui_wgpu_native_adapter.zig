//! ImGui wgpu_native Adapter
//!
//! GUI backend using Dear ImGui with wgpu_native/GLFW+WebGPU rendering.
//! This adapter uses the wgpu_native backend for lower-level WebGPU control.
//!
//! Build with: zig build -Dbackend=wgpu_native -Dgui_backend=imgui

const std = @import("std");
const types = @import("types.zig");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const wgpu = @import("wgpu");
const labelle = @import("labelle");

const WgpuNativeBackend = labelle.WgpuNativeBackend;

// Import C backend functions from imgui_impl_wgpu.cpp and imgui_impl_glfw.cpp
// These are compiled separately with IMGUI_IMPL_WEBGPU_BACKEND_WGPU define
const c = @cImport({
    @cDefine("IMGUI_IMPL_WEBGPU_BACKEND_WGPU", "1");
    @cInclude("imgui_impl_glfw.h");
    @cInclude("imgui_impl_wgpu.h");
});

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
    const allocator = @import("../platform.zig").getDefaultAllocator();

    // Initialize zgui core (not the backend yet - that needs wgpu context)
    zgui.init(allocator);

    std.log.info("wgpu_native ImGui adapter: initialized", .{});

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

    // Get device and window from labelle-gfx WgpuNativeBackend
    const device = WgpuNativeBackend.getDevice() orelse {
        std.log.debug("imgui_wgpu_native: device not ready yet", .{});
        return;
    };
    const window = WgpuNativeBackend.getWindow() orelse {
        std.log.debug("imgui_wgpu_native: window not ready yet", .{});
        return;
    };

    // Get swapchain format (required for render pipeline)
    // Check this BEFORE initializing GLFW to avoid double-init on retry
    const swapchain_format = WgpuNativeBackend.getSwapchainFormat() orelse {
        std.log.debug("imgui_wgpu_native: swapchain format not ready yet", .{});
        return;
    };

    // Get framebuffer size from window
    const fb_size = window.getFramebufferSize();
    self.fb_width = @intCast(fb_size[0]);
    self.fb_height = @intCast(fb_size[1]);

    // Initialize GLFW backend for input handling
    // The last parameter (install_callbacks) should be true to handle input
    _ = c.ImGui_ImplGlfw_InitForOther(@ptrCast(window), true);

    // Initialize WebGPU backend for rendering
    var init_info = c.ImGui_ImplWGPU_InitInfo{
        .Device = @ptrCast(device),
        .NumFramesInFlight = 3,
        .RenderTargetFormat = @intFromEnum(swapchain_format),
        .DepthStencilFormat = @intFromEnum(wgpu.TextureFormat.undefined),
        .PipelineMultisampleState = .{
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alphaToCoverageEnabled = false,
        },
    };
    if (!c.ImGui_ImplWGPU_Init(&init_info)) {
        std.log.err("imgui_wgpu_native: failed to initialize WebGPU backend", .{});
        // Clean up GLFW backend that was already initialized
        c.ImGui_ImplGlfw_Shutdown();
        return;
    }

    // Register render callback with the backend
    WgpuNativeBackend.registerGuiRenderCallback(guiRenderCallback);

    self.backend_initialized = true;
    std.log.info("imgui_wgpu_native: backend initialized ({}x{})", .{ self.fb_width, self.fb_height });
}

/// Render callback invoked by WgpuNativeBackend during endDrawing()
fn guiRenderCallback(render_pass: *wgpu.RenderPassEncoder) void {
    // Render ImGui draw data into the render pass
    c.ImGui_ImplWGPU_RenderDrawData(zgui.getDrawData(), @ptrCast(render_pass));
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    if (self.backend_initialized) {
        WgpuNativeBackend.unregisterGuiRenderCallback();
        c.ImGui_ImplWGPU_Shutdown();
        c.ImGui_ImplGlfw_Shutdown();
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

    // Update framebuffer size if window changed
    if (WgpuNativeBackend.getWindow()) |window| {
        const fb_size = window.getFramebufferSize();
        self.fb_width = @intCast(fb_size[0]);
        self.fb_height = @intCast(fb_size[1]);
    }

    // Start new ImGui frame with backend
    c.ImGui_ImplWGPU_NewFrame();
    c.ImGui_ImplGlfw_NewFrame();
    zgui.newFrame();
}

pub fn endFrame(self: *const Self) void {
    if (!self.backend_initialized) return;

    // Finalize ImGui frame - prepares draw data
    // Actual rendering happens in guiRenderCallback when WgpuNativeBackend
    // calls it during its endDrawing() with the active render pass
    zgui.render();
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
    // TODO: Implement image rendering with wgpu_native textures
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    if (!self.backend_initialized) return false;

    var checked = cb.checked;
    var changed = false;

    // Convert text to null-terminated
    var text_buf: [256]u8 = undefined;
    const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{cb.text}) catch return false;

    if (self.panel_depth > 0) {
        changed = zgui.checkbox(text_z, .{ .v = &checked });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

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
            changed = zgui.checkbox(text_z, .{ .v = &checked });
        }
        zgui.end();
    }

    return changed;
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
