//! Clay C Bindings
//!
//! Re-exports the zclay Zig bindings for the Clay UI C library.
//! Clay is a single-header C library for high-performance UI layout.
//!
//! Reference: https://github.com/nicbarker/clay
//! Zig Bindings: https://github.com/johan0A/clay-zig-bindings

// Re-export the entire zclay module
pub const clay = @import("zclay");

// For convenience, re-export commonly used types
pub const Color = clay.Color;
pub const Dimensions = clay.Dimensions;
pub const LayoutConfig = clay.LayoutConfig;
pub const TextElementConfig = clay.TextElementConfig;
pub const RenderCommand = clay.RenderCommand;
pub const RenderCommandArray = clay.ClayArray(clay.RenderCommand);
