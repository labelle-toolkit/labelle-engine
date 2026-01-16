//! ImGui bgfx Adapter
//!
//! GUI backend using Dear ImGui with bgfx rendering.
//! Uses zgui for Zig bindings to ImGui and zbgfx's imgui_backend for rendering.
//!
//! Build with: zig build -Dbackend=bgfx -Dgui_backend=imgui

const std = @import("std");
const types = @import("types.zig");
const zgui = @import("zgui");
const zbgfx = @import("zbgfx");
const labelle = @import("labelle");

const BgfxBackend = labelle.BgfxBackend;

const Self = @This();

// View ID for ImGui rendering (use a dedicated view to not conflict with main rendering)
const IMGUI_VIEW_ID: zbgfx.bgfx.ViewId = 255;

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
    // Emscripten requires c_allocator (page_allocator fails silently in WASM)
    const allocator = if (@import("builtin").os.tag == .emscripten)
        std.heap.c_allocator
    else
        std.heap.page_allocator;

    // Initialize zgui core (backend initialized lazily when window is available)
    zgui.init(allocator);

    std.log.info("bgfx ImGui adapter: initialized", .{});

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

    // Get GLFW window from labelle-gfx BgfxBackend
    const window = BgfxBackend.getGlfwWindow() orelse {
        std.log.debug("imgui_bgfx: GLFW window not ready yet", .{});
        return;
    };

    // Initialize zgui's GLFW backend for input handling
    zgui.backend.init(@ptrCast(window));

    // Initialize zbgfx's ImGui rendering backend
    zbgfx.imgui_backend.init();

    // Register render callback with the backend
    BgfxBackend.registerGuiRenderCallback(guiRenderCallback);

    self.backend_initialized = true;
    std.log.info("imgui_bgfx: backend initialized", .{});
}

/// Render callback invoked by BgfxBackend during endDrawing()
fn guiRenderCallback() void {
    // Render ImGui draw data using zbgfx's backend
    zbgfx.imgui_backend.draw();
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    if (self.backend_initialized) {
        BgfxBackend.unregisterGuiRenderCallback();
        zbgfx.imgui_backend.deinit();
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

    // Start new ImGui frame
    zbgfx.imgui_backend.newFrame(IMGUI_VIEW_ID);
    zgui.backend.newFrame();
    zgui.newFrame();
}

pub fn endFrame(self: *const Self) void {
    if (!self.backend_initialized) return;

    // Finalize ImGui frame - prepares draw data
    // Actual rendering happens in guiRenderCallback when BgfxBackend calls it
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
    // TODO: Implement image rendering with bgfx textures
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

        const text_size = zgui.calcTextSize(cb.text, .{});
        zgui.setNextWindowPos(.{ .x = cb.position.x, .y = cb.position.y });
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
