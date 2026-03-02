//! Clay UI Stub Adapter
//!
//! No-op implementation for non-raylib graphics backends.
//! Clay GUI currently only supports the raylib graphics backend.
//! This stub allows compilation on other backends without errors.

const std = @import("std");
const types = @import("../types.zig");

const Self = @This();

pub fn init() Self {
    std.log.warn("[clay] Clay GUI is only supported on the raylib graphics backend. GUI will be non-functional.", .{});
    return .{};
}

pub fn fixPointers(_: *Self) void {}

pub fn deinit(_: *Self) void {}

pub fn beginFrame(_: *Self) void {}

pub fn endFrame(_: *Self) void {}

pub fn label(_: *Self, _: types.Label) void {}

pub fn button(_: *Self, _: types.Button) bool {
    return false;
}

pub fn progressBar(_: *Self, _: types.ProgressBar) void {}

pub fn beginPanel(_: *Self, _: types.Panel) void {}

pub fn endPanel(_: *Self) void {}

pub fn image(_: *Self, _: types.Image) void {}

pub fn checkbox(_: *Self, _: types.Checkbox) bool {
    return false;
}

pub fn slider(_: *Self, sl: types.Slider) f32 {
    return sl.value;
}
