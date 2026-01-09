//! Nuklear WGPU Native Adapter
//!
//! Stub implementation for nuklear with wgpu_native backend.
//! TODO: Implement proper nuklear rendering with wgpu_native.

const types = @import("types.zig");

const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn beginFrame(self: *Self) void {
    _ = self;
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
}

pub fn endPanel(self: *Self) void {
    _ = self;
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
