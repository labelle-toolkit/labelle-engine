//! Stub Input Backend
//!
//! A no-op input implementation for backends that handle input
//! directly in their main loop (like bgfx with GLFW).
//!
//! This stub implements all required methods but returns "no input".
//! The actual input handling happens in the generated main.zig template.

const types = @import("types.zig");

pub const KeyboardKey = types.KeyboardKey;
pub const MouseButton = types.MouseButton;
pub const MousePosition = types.MousePosition;

const Self = @This();

/// Initialize the input system (no-op)
pub fn init() Self {
    return .{};
}

/// Clean up the input system (no-op)
pub fn deinit(self: *Self) void {
    _ = self;
}

/// Called at the start of each frame (no-op)
pub fn beginFrame(self: *Self) void {
    _ = self;
}

/// Check if a key is currently held down (always false)
pub fn isKeyDown(self: *const Self, key: KeyboardKey) bool {
    _ = self;
    _ = key;
    return false;
}

/// Check if a key was pressed this frame (always false)
pub fn isKeyPressed(self: *const Self, key: KeyboardKey) bool {
    _ = self;
    _ = key;
    return false;
}

/// Check if a key was released this frame (always false)
pub fn isKeyReleased(self: *const Self, key: KeyboardKey) bool {
    _ = self;
    _ = key;
    return false;
}

/// Check if a mouse button is currently held down (always false)
pub fn isMouseButtonDown(self: *const Self, button: MouseButton) bool {
    _ = self;
    _ = button;
    return false;
}

/// Check if a mouse button was pressed this frame (always false)
pub fn isMouseButtonPressed(self: *const Self, button: MouseButton) bool {
    _ = self;
    _ = button;
    return false;
}

/// Check if a mouse button was released this frame (always false)
pub fn isMouseButtonReleased(self: *const Self, button: MouseButton) bool {
    _ = self;
    _ = button;
    return false;
}

/// Get the current mouse position (always 0, 0)
pub fn getMousePosition(self: *const Self) MousePosition {
    _ = self;
    return .{ .x = 0, .y = 0 };
}

/// Get the mouse wheel movement (always 0)
pub fn getMouseWheelMove(self: *const Self) f32 {
    _ = self;
    return 0;
}
