//! Clay UI Adapter
//!
//! GUI backend using Clay UI layout engine.
//! Clay provides a declarative, high-performance UI layout system.
//!
//! Architecture:
//! - Clay handles layout calculation and spatial hierarchy
//! - labelle-engine types are converted to Clay elements
//! - Render commands are processed by renderer.zig
//! - Rendering is delegated to labelle-gfx backends (raylib)
//!
//! Note: This is a minimal implementation that establishes the interface.
//! Full Clay integration requires adapting labelle-engine's immediate-mode
//! GUI API to Clay's declarative scope-based API.

const std = @import("std");
const types = @import("../types.zig");
const clay = @import("bindings.zig").clay;

const Self = @This();

// Clay memory and context
memory: []u8 = &.{},
allocator: std.mem.Allocator = undefined,
initialized: bool = false,

pub fn init() Self {
    return .{
        .initialized = false,
    };
}

pub fn fixPointers(_: *Self) void {
    // Clay manages pointers internally
}

pub fn deinit(self: *Self) void {
    if (self.initialized and self.memory.len > 0) {
        self.allocator.free(self.memory);
        self.initialized = false;
    }
}

pub fn beginFrame(_: *Self) void {
    // Clay layout initialization would go here
    // For now, this is a stub
}

pub fn endFrame(_: *Self) void {
    // Clay layout finalization and rendering would go here
    // For now, this is a stub
}

pub fn label(_: *Self, lbl: types.Label) void {
    _ = lbl;
    // TODO: Implement Clay text element
}

pub fn button(_: *Self, btn: types.Button) bool {
    _ = btn;
    // TODO: Implement Clay button with hover/click detection
    return false;
}

pub fn progressBar(_: *Self, bar: types.ProgressBar) void {
    _ = bar;
    // TODO: Implement Clay progress bar
}

pub fn beginPanel(_: *Self, panel: types.Panel) void {
    _ = panel;
    // TODO: Implement Clay panel container
}

pub fn endPanel(_: *Self) void {
    // TODO: Close Clay panel scope
}

pub fn image(_: *Self, img: types.Image) void {
    _ = img;
    // TODO: Implement Clay image element
}

pub fn checkbox(_: *Self, cb: types.Checkbox) bool {
    // TODO: Implement Clay checkbox
    return cb.checked;
}

pub fn slider(_: *Self, sl: types.Slider) f32 {
    // TODO: Implement Clay slider
    return sl.value;
}
