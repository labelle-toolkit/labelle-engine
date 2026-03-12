//! GUI Element Types
//!
//! Backend-agnostic definitions for declarative GUI elements.
//! Can be rendered by any GUI backend (raygui, imgui, nuklear, etc.)

const std = @import("std");

/// RGBA color with 0-255 range
pub const GuiColor = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,

    pub const white = GuiColor{};
    pub const black = GuiColor{ .r = 0, .g = 0, .b = 0 };
    pub const red = GuiColor{ .r = 255, .g = 0, .b = 0 };
    pub const green = GuiColor{ .r = 0, .g = 255, .b = 0 };
    pub const blue = GuiColor{ .r = 0, .g = 0, .b = 255 };
    pub const transparent = GuiColor{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

/// 2D position in screen space
pub const GuiPosition = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Size in pixels
pub const GuiSize = struct {
    width: f32 = 100,
    height: f32 = 30,
};

pub const Label = struct {
    id: []const u8 = "",
    text: []const u8 = "",
    position: GuiPosition = .{},
    font_size: f32 = 16,
    color: GuiColor = .{},
    visible: bool = true,
};

pub const Button = struct {
    id: []const u8 = "",
    text: []const u8 = "",
    position: GuiPosition = .{},
    size: GuiSize = .{ .width = 100, .height = 30 },
    on_click: ?[]const u8 = null,
    visible: bool = true,
};

pub const ProgressBar = struct {
    id: []const u8 = "",
    position: GuiPosition = .{},
    size: GuiSize = .{ .width = 200, .height = 20 },
    value: f32 = 0,
    color: GuiColor = .{ .r = 0, .g = 200, .b = 0 },
    visible: bool = true,
};

pub const Panel = struct {
    id: []const u8 = "",
    position: GuiPosition = .{},
    size: GuiSize = .{ .width = 200, .height = 150 },
    background_color: GuiColor = .{ .r = 50, .g = 50, .b = 50, .a = 200 },
    children: []const GuiElement = &.{},
    visible: bool = true,
};

pub const Image = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    position: GuiPosition = .{},
    size: ?GuiSize = null,
    tint: GuiColor = .{},
    visible: bool = true,
};

pub const Checkbox = struct {
    id: []const u8 = "",
    text: []const u8 = "",
    position: GuiPosition = .{},
    checked: bool = false,
    on_change: ?[]const u8 = null,
    visible: bool = true,
};

pub const Slider = struct {
    id: []const u8 = "",
    position: GuiPosition = .{},
    size: GuiSize = .{ .width = 200, .height = 20 },
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
    on_change: ?[]const u8 = null,
    visible: bool = true,
};

/// Union of all GUI element types
pub const GuiElement = union(enum) {
    Label: Label,
    Button: Button,
    ProgressBar: ProgressBar,
    Panel: Panel,
    Image: Image,
    Checkbox: Checkbox,
    Slider: Slider,

    pub fn getId(self: GuiElement) []const u8 {
        return switch (self) {
            .Label => |e| e.id,
            .Button => |e| e.id,
            .ProgressBar => |e| e.id,
            .Panel => |e| e.id,
            .Image => |e| e.id,
            .Checkbox => |e| e.id,
            .Slider => |e| e.id,
        };
    }

    pub fn getPosition(self: GuiElement) GuiPosition {
        return switch (self) {
            .Label => |e| e.position,
            .Button => |e| e.position,
            .ProgressBar => |e| e.position,
            .Panel => |e| e.position,
            .Image => |e| e.position,
            .Checkbox => |e| e.position,
            .Slider => |e| e.position,
        };
    }

    pub fn isVisible(self: GuiElement) bool {
        return switch (self) {
            .Label => |e| e.visible,
            .Button => |e| e.visible,
            .ProgressBar => |e| e.visible,
            .Panel => |e| e.visible,
            .Image => |e| e.visible,
            .Checkbox => |e| e.visible,
            .Slider => |e| e.visible,
        };
    }

    pub fn setVisible(self: *GuiElement, visible: bool) void {
        switch (self.*) {
            .Label => |*e| e.visible = visible,
            .Button => |*e| e.visible = visible,
            .ProgressBar => |*e| e.visible = visible,
            .Panel => |*e| e.visible = visible,
            .Image => |*e| e.visible = visible,
            .Checkbox => |*e| e.visible = visible,
            .Slider => |*e| e.visible = visible,
        }
    }
};
