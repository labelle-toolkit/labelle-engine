//! ImGui Sokol Adapter
//!
//! GUI backend using Dear ImGui with sokol rendering.
//! Uses dcimgui (cimgui) for ImGui API and sokol_imgui for rendering.
//!
//! Build with: zig build -Dbackend=sokol -Dgui_backend=imgui

const std = @import("std");
const types = @import("types.zig");
const cimgui = @import("cimgui");
const simgui = @import("sokol_imgui.zig");

const Self = @This();

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

// Track if backend is initialized
backend_initialized: bool,

// Screen dimensions for frame setup
width: i32,
height: i32,

pub fn init() Self {
    return Self{
        .window_counter = 0,
        .panel_depth = 0,
        .backend_initialized = false,
        .width = 800,
        .height = 600,
    };
}

fn initBackend(self: *Self) void {
    if (self.backend_initialized) return;

    // Check if sokol_gfx is ready before initializing sokol_imgui
    // sokol_imgui requires sokol_gfx to be initialized first
    if (!simgui.isGfxValid()) {
        std.log.debug("imgui_sokol: waiting for sokol_gfx to be ready", .{});
        return;
    }

    // Check if sokol_app is in valid state (required for Metal backend)
    // sokol_app's _sapp.valid is only true during callbacks (init/frame/cleanup)
    if (!simgui.isAppValid()) {
        std.log.debug("imgui_sokol: waiting for sokol_app to be in valid callback state", .{});
        return;
    }

    // Initialize sokol_imgui (creates ImGui context internally)
    simgui.setup(.{});

    self.backend_initialized = true;
    std.log.info("imgui_sokol: backend initialized with sokol_imgui + dcimgui", .{});
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    if (self.backend_initialized) {
        simgui.shutdown();
    }
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Lazy init backend on first frame
    if (!self.backend_initialized) {
        self.initBackend();
    }

    if (!self.backend_initialized) return;

    // Start new ImGui frame via sokol_imgui
    simgui.newFrame(.{
        .width = self.width,
        .height = self.height,
        .delta_time = 1.0 / 60.0, // TODO: get actual delta time from sokol_app
    });
}

pub fn endFrame(self: *Self) void {
    if (!self.backend_initialized) return;

    // Render ImGui via sokol_imgui
    simgui.render();
}

/// Set screen dimensions (should be called when window resizes)
pub fn setScreenSize(self: *Self, width: i32, height: i32) void {
    self.width = width;
    self.height = height;
}

fn nextWindowName(self: *Self, buf: []u8) [*:0]const u8 {
    self.window_counter += 1;
    const result = std.fmt.bufPrintZ(buf, "##w{d}", .{self.window_counter}) catch {
        buf[0] = '#';
        buf[1] = '#';
        buf[2] = 'w';
        buf[3] = 0;
        return @ptrCast(&buf[0]);
    };
    return result.ptr;
}

pub fn label(self: *Self, lbl: types.Label) void {
    if (!self.backend_initialized) return;

    const color = cimgui.ImVec4{
        .x = @as(f32, @floatFromInt(lbl.color.r)) / 255.0,
        .y = @as(f32, @floatFromInt(lbl.color.g)) / 255.0,
        .z = @as(f32, @floatFromInt(lbl.color.b)) / 255.0,
        .w = @as(f32, @floatFromInt(lbl.color.a)) / 255.0,
    };

    if (self.panel_depth > 0) {
        cimgui.igTextColored(color, "%s", lbl.text.ptr);
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        cimgui.igSetNextWindowPos(.{ .x = lbl.position.x, .y = lbl.position.y }, 0);
        cimgui.igSetNextWindowSize(.{ .x = @floatFromInt(lbl.text.len * 10), .y = lbl.font_size + 8 }, 0);

        const flags = cimgui.ImGuiWindowFlags_NoTitleBar |
            cimgui.ImGuiWindowFlags_NoResize |
            cimgui.ImGuiWindowFlags_NoMove |
            cimgui.ImGuiWindowFlags_NoScrollbar |
            cimgui.ImGuiWindowFlags_NoBackground |
            cimgui.ImGuiWindowFlags_NoMouseInputs;

        if (cimgui.igBegin(name, null, flags)) {
            cimgui.igTextColored(color, "%s", lbl.text.ptr);
        }
        cimgui.igEnd();
    }
}

pub fn button(self: *Self, btn: types.Button) bool {
    if (!self.backend_initialized) return false;

    // Convert text to null-terminated
    var text_buf: [256]u8 = undefined;
    const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{btn.text}) catch return false;

    if (self.panel_depth > 0) {
        // dcimgui's igButton only takes label (no size parameter)
        return cimgui.igButton(text_z.ptr);
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        cimgui.igSetNextWindowPos(.{ .x = btn.position.x, .y = btn.position.y }, 0);
        cimgui.igSetNextWindowSize(.{ .x = btn.size.width + 16, .y = btn.size.height + 16 }, 0);

        var clicked = false;
        const flags = cimgui.ImGuiWindowFlags_NoTitleBar |
            cimgui.ImGuiWindowFlags_NoResize |
            cimgui.ImGuiWindowFlags_NoMove |
            cimgui.ImGuiWindowFlags_NoScrollbar |
            cimgui.ImGuiWindowFlags_NoBackground;

        if (cimgui.igBegin(name, null, flags)) {
            clicked = cimgui.igButton(text_z.ptr);
        }
        cimgui.igEnd();

        return clicked;
    }
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    if (!self.backend_initialized) return;

    if (self.panel_depth > 0) {
        cimgui.igProgressBar(bar.value, .{ .x = bar.size.width, .y = bar.size.height }, null);
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        cimgui.igSetNextWindowPos(.{ .x = bar.position.x, .y = bar.position.y }, 0);
        cimgui.igSetNextWindowSize(.{ .x = bar.size.width + 16, .y = bar.size.height + 16 }, 0);

        const flags = cimgui.ImGuiWindowFlags_NoTitleBar |
            cimgui.ImGuiWindowFlags_NoResize |
            cimgui.ImGuiWindowFlags_NoMove |
            cimgui.ImGuiWindowFlags_NoScrollbar |
            cimgui.ImGuiWindowFlags_NoBackground;

        if (cimgui.igBegin(name, null, flags)) {
            cimgui.igProgressBar(bar.value, .{ .x = bar.size.width, .y = bar.size.height }, null);
        }
        cimgui.igEnd();
    }
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    if (!self.backend_initialized) return;

    var name_buf: [32]u8 = undefined;
    const name = self.nextWindowName(&name_buf);

    cimgui.igSetNextWindowPos(.{ .x = panel.position.x, .y = panel.position.y }, 0);
    cimgui.igSetNextWindowSize(.{ .x = panel.size.width, .y = panel.size.height }, 0);

    const flags = cimgui.ImGuiWindowFlags_NoResize |
        cimgui.ImGuiWindowFlags_NoMove |
        cimgui.ImGuiWindowFlags_NoCollapse;

    _ = cimgui.igBegin(name, null, flags);
    self.panel_depth += 1;
}

pub fn endPanel(self: *Self) void {
    if (!self.backend_initialized) return;

    self.panel_depth -= 1;
    cimgui.igEnd();
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
    // TODO: Implement image rendering with sokol textures
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    if (!self.backend_initialized) return cb.checked;

    var checked = cb.checked;

    // Convert text to null-terminated
    var text_buf: [256]u8 = undefined;
    const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{cb.text}) catch return checked;

    if (self.panel_depth > 0) {
        _ = cimgui.igCheckbox(text_z.ptr, &checked);
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const text_len: usize = cb.text.len;
        cimgui.igSetNextWindowPos(.{ .x = cb.position.x, .y = cb.position.y }, 0);
        cimgui.igSetNextWindowSize(.{ .x = @as(f32, @floatFromInt(text_len * 8)) + 50, .y = 40 }, 0);

        const flags = cimgui.ImGuiWindowFlags_NoTitleBar |
            cimgui.ImGuiWindowFlags_NoResize |
            cimgui.ImGuiWindowFlags_NoMove |
            cimgui.ImGuiWindowFlags_NoScrollbar |
            cimgui.ImGuiWindowFlags_NoBackground;

        if (cimgui.igBegin(name, null, flags)) {
            _ = cimgui.igCheckbox(text_z.ptr, &checked);
        }
        cimgui.igEnd();
    }

    return checked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    if (!self.backend_initialized) return sl.value;

    var value = sl.value;

    if (self.panel_depth > 0) {
        // dcimgui's igSliderFloat has 4 args: label, v, v_min, v_max
        _ = cimgui.igSliderFloat("##slider", &value, sl.min, sl.max);
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        cimgui.igSetNextWindowPos(.{ .x = sl.position.x, .y = sl.position.y }, 0);
        cimgui.igSetNextWindowSize(.{ .x = sl.size.width + 16, .y = sl.size.height + 16 }, 0);

        const flags = cimgui.ImGuiWindowFlags_NoTitleBar |
            cimgui.ImGuiWindowFlags_NoResize |
            cimgui.ImGuiWindowFlags_NoMove |
            cimgui.ImGuiWindowFlags_NoScrollbar |
            cimgui.ImGuiWindowFlags_NoBackground;

        if (cimgui.igBegin(name, null, flags)) {
            _ = cimgui.igSliderFloat("##slider", &value, sl.min, sl.max);
        }
        cimgui.igEnd();
    }

    return value;
}
