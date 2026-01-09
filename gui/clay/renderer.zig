//! Clay Renderer Interface
//!
//! Defines the rendering interface between Clay's layout engine
//! and labelle-gfx rendering backends.
//!
//! Clay calculates layouts and produces render commands, which we
//! translate to labelle-gfx draw calls.

const std = @import("std");

/// Clay render command types
pub const RenderCommandType = enum {
    rectangle,
    text,
    image,
    scissor_start,
    scissor_end,
};

/// Rectangle render command
pub const RenderRectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: [4]f32, // RGBA 0-1 range
    corner_radius: f32 = 0,
};

/// Text render command
pub const RenderText = struct {
    x: f32,
    y: f32,
    text: []const u8,
    font_size: f32,
    color: [4]f32, // RGBA 0-1 range
};

/// Image render command
pub const RenderImage = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    texture_id: u32,
    tint: [4]f32, // RGBA 0-1 range
};

/// Scissor (clipping) command
pub const RenderScissor = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Union of all render commands
pub const RenderCommand = union(RenderCommandType) {
    rectangle: RenderRectangle,
    text: RenderText,
    image: RenderImage,
    scissor_start: RenderScissor,
    scissor_end: void,
};

/// Renderer interface that backends must implement
pub const Renderer = struct {
    const Self = @This();

    /// Begin a frame
    beginFn: *const fn (*Self) void,
    /// End a frame
    endFn: *const fn (*Self) void,
    /// Render a command
    renderFn: *const fn (*Self, RenderCommand) void,

    pub fn begin(self: *Self) void {
        self.beginFn(self);
    }

    pub fn end(self: *Self) void {
        self.endFn(self);
    }

    pub fn render(self: *Self, cmd: RenderCommand) void {
        self.renderFn(self, cmd);
    }
};
