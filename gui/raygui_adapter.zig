//! Raygui Adapter
//!
//! GUI backend using raylib's drawing primitives.
//! Delegates widget rendering to the shared widget_renderer module.

const types = @import("types.zig");
const widget = @import("widget_renderer.zig");

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
    widget.drawLabel(lbl);
}

pub fn button(self: *Self, btn: types.Button) bool {
    _ = self;
    return widget.drawButton(btn);
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    _ = self;
    widget.drawProgressBar(bar);
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    _ = self;
    widget.drawPanel(panel);
}

pub fn endPanel(self: *Self) void {
    _ = self;
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    widget.drawImage(img);
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    _ = self;
    return widget.drawCheckbox(cb);
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    _ = self;
    return widget.drawSlider(sl);
}
