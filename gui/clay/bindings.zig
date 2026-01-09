//! Clay C Bindings
//!
//! Low-level bindings to the Clay UI C library.
//! Clay is a single-header C library for UI layout.
//!
//! Reference: https://github.com/nicbarker/clay

const std = @import("std");

// Clay will be linked as a C library
// These are placeholder types until we integrate the actual Clay header

/// Clay initialization configuration
pub const ClayConfig = extern struct {
    arena_capacity: u32,
    max_element_count: u32,
};

/// Clay dimensions
pub const ClayDimensions = extern struct {
    width: f32,
    height: f32,
};

/// Clay RGBA color
pub const ClayColor = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Clay layout configuration
pub const ClayLayoutConfig = extern struct {
    sizing_width: u32, // Clay sizing mode
    sizing_height: u32,
    padding: ClayPadding,
    gap: f32,
};

/// Clay padding
pub const ClayPadding = extern struct {
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
};

/// Clay rectangle configuration
pub const ClayRectangleConfig = extern struct {
    color: ClayColor,
    corner_radius: f32,
};

/// Clay text configuration
pub const ClayTextConfig = extern struct {
    text_color: ClayColor,
    font_size: f32,
};

// TODO: Add extern function declarations when Clay C library is integrated
// Example:
// pub extern fn Clay_Initialize(config: ClayConfig) void;
// pub extern fn Clay_BeginLayout() void;
// pub extern fn Clay_EndLayout() void;
// pub extern fn Clay_Rectangle(config: *const ClayRectangleConfig) void;
// pub extern fn Clay_Text(text: [*:0]const u8, config: *const ClayTextConfig) void;

// Placeholder stubs for now
pub fn Clay_Initialize(config: ClayConfig) void {
    _ = config;
    std.log.info("[Clay] Initialize called (stub)", .{});
}

pub fn Clay_BeginLayout() void {
    std.log.info("[Clay] BeginLayout called (stub)", .{});
}

pub fn Clay_EndLayout() void {
    std.log.info("[Clay] EndLayout called (stub)", .{});
}

pub fn Clay_Rectangle(config: *const ClayRectangleConfig) void {
    _ = config;
    // std.log.info("[Clay] Rectangle called (stub)", .{});
}

pub fn Clay_Text(text: [*:0]const u8, config: *const ClayTextConfig) void {
    _ = text;
    _ = config;
    // std.log.info("[Clay] Text called (stub)", .{});
}
