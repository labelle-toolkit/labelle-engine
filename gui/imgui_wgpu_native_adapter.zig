//! ImGui wgpu_native Adapter
//!
//! GUI backend using Dear ImGui with wgpu_native/GLFW+WebGPU rendering.
//! This adapter uses the wgpu_native backend for lower-level WebGPU control.
//!
//! Build with: zig build -Dbackend=wgpu_native -Dgui_backend=imgui
//!
//! TODO: Implement proper ImGui rendering with wgpu_native.
//! Currently a stub implementation.

const std = @import("std");
const types = @import("types.zig");

const Self = @This();

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

pub fn init() Self {
    std.log.info("wgpu_native ImGui adapter: stub initialization", .{});

    return Self{
        .window_counter = 0,
        .panel_depth = 0,
    };
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;
}

pub fn endFrame(self: *Self) void {
    _ = self;
}

pub fn label(self: *Self, lbl: types.Label) void {
    _ = self;
    _ = lbl;
}

pub fn button(self: *Self, btn: types.Button) bool {
    _ = self;
    _ = btn;
    return false;
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    _ = self;
    _ = bar;
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    _ = self;
    _ = panel;
    self.panel_depth += 1;
}

pub fn endPanel(self: *Self) void {
    if (self.panel_depth > 0) {
        self.panel_depth -= 1;
    }
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    _ = self;
    _ = cb;
    return false;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    _ = self;
    return sl.value;
}
