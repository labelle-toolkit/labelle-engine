//! GUI Element Types
//!
//! Common types for declarative GUI elements. Backend-agnostic definitions
//! that can be rendered by any GUI backend (raygui, imgui, nuklear, etc.)

const std = @import("std");

/// RGBA color with 0-255 range
pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,

    pub const white = Color{};
    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const red = Color{ .r = 255, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 255, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

/// 2D position in screen space
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Size in pixels
pub const Size = struct {
    width: f32 = 100,
    height: f32 = 30,
};

/// Text label element
pub const Label = struct {
    /// Optional ID for runtime access
    id: []const u8 = "",
    /// Text to display
    text: []const u8 = "",
    /// Screen position
    position: Position = .{},
    /// Font size in pixels
    font_size: f32 = 16,
    /// Text color
    color: Color = .{},
    /// Visibility flag (for conditional rendering)
    visible: bool = true,
};

/// Clickable button element
pub const Button = struct {
    /// Optional ID for runtime access
    id: []const u8 = "",
    /// Button text
    text: []const u8 = "",
    /// Screen position
    position: Position = .{},
    /// Button size
    size: Size = .{ .width = 100, .height = 30 },
    /// Script callback name (called on click)
    on_click: ?[]const u8 = null,
    /// Visibility flag (for conditional rendering)
    visible: bool = true,
};

/// Progress bar element
pub const ProgressBar = struct {
    /// Optional ID for runtime access
    id: []const u8 = "",
    /// Screen position
    position: Position = .{},
    /// Bar size
    size: Size = .{ .width = 200, .height = 20 },
    /// Current value (0.0 to 1.0)
    value: f32 = 0,
    /// Fill color
    color: Color = .{ .r = 0, .g = 200, .b = 0 },
    /// Visibility flag (for conditional rendering)
    visible: bool = true,
};

/// Container panel element
pub const Panel = struct {
    /// Optional ID for runtime access
    id: []const u8 = "",
    /// Screen position
    position: Position = .{},
    /// Panel size
    size: Size = .{ .width = 200, .height = 150 },
    /// Background color
    background_color: Color = .{ .r = 50, .g = 50, .b = 50, .a = 200 },
    /// Child elements (rendered inside panel)
    children: []const GuiElement = &.{},
    /// Visibility flag (for conditional rendering)
    visible: bool = true,
};

/// Image element
pub const Image = struct {
    /// Optional ID for runtime access
    id: []const u8 = "",
    /// Texture/sprite name
    name: []const u8 = "",
    /// Screen position
    position: Position = .{},
    /// Optional size (null = use texture size)
    size: ?Size = null,
    /// Tint color
    tint: Color = .{},
    /// Visibility flag (for conditional rendering)
    visible: bool = true,
};

/// Checkbox element
pub const Checkbox = struct {
    /// Optional ID for runtime access
    id: []const u8 = "",
    /// Label text
    text: []const u8 = "",
    /// Screen position
    position: Position = .{},
    /// Current checked state
    checked: bool = false,
    /// Script callback name (called on toggle)
    on_change: ?[]const u8 = null,
    /// Visibility flag (for conditional rendering)
    visible: bool = true,
};

/// Slider element
pub const Slider = struct {
    /// Optional ID for runtime access
    id: []const u8 = "",
    /// Screen position
    position: Position = .{},
    /// Slider size
    size: Size = .{ .width = 200, .height = 20 },
    /// Current value
    value: f32 = 0,
    /// Minimum value
    min: f32 = 0,
    /// Maximum value
    max: f32 = 1,
    /// Script callback name (called on change)
    on_change: ?[]const u8 = null,
    /// Visibility flag (for conditional rendering)
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

    /// Get the ID of this element (if any)
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

    /// Get the position of this element
    pub fn getPosition(self: GuiElement) Position {
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

    /// Get the visibility of this element
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

    /// Set the visibility of this element
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
