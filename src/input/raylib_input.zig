//! Raylib Input Backend
//!
//! Stateless input implementation that wraps raylib input functions.
//! Raylib uses polling-based input, so all functions directly delegate to raylib.

const rl = @import("raylib");
const types = @import("types.zig");

pub const KeyboardKey = types.KeyboardKey;
pub const MouseButton = types.MouseButton;
pub const MousePosition = types.MousePosition;

const Self = @This();

/// Initialize the input system (no-op for raylib)
pub fn init() Self {
    return .{};
}

/// Clean up the input system (no-op for raylib)
pub fn deinit(self: *Self) void {
    _ = self;
}

/// Called at the start of each frame (no-op for raylib)
pub fn beginFrame(self: *Self) void {
    _ = self;
}

/// Check if a key is currently held down
pub fn isKeyDown(self: *const Self, key: KeyboardKey) bool {
    _ = self;
    return rl.isKeyDown(@enumFromInt(@intFromEnum(key)));
}

/// Check if a key was pressed this frame
pub fn isKeyPressed(self: *const Self, key: KeyboardKey) bool {
    _ = self;
    return rl.isKeyPressed(@enumFromInt(@intFromEnum(key)));
}

/// Check if a key was released this frame
pub fn isKeyReleased(self: *const Self, key: KeyboardKey) bool {
    _ = self;
    return rl.isKeyReleased(@enumFromInt(@intFromEnum(key)));
}

/// Check if a mouse button is currently held down
pub fn isMouseButtonDown(self: *const Self, button: MouseButton) bool {
    _ = self;
    return rl.isMouseButtonDown(@enumFromInt(@intFromEnum(button)));
}

/// Check if a mouse button was pressed this frame
pub fn isMouseButtonPressed(self: *const Self, button: MouseButton) bool {
    _ = self;
    return rl.isMouseButtonPressed(@enumFromInt(@intFromEnum(button)));
}

/// Check if a mouse button was released this frame
pub fn isMouseButtonReleased(self: *const Self, button: MouseButton) bool {
    _ = self;
    return rl.isMouseButtonReleased(@enumFromInt(@intFromEnum(button)));
}

/// Get the current mouse position
pub fn getMousePosition(self: *const Self) MousePosition {
    _ = self;
    const pos = rl.getMousePosition();
    return .{ .x = pos.x, .y = pos.y };
}

/// Get the mouse wheel movement (vertical)
pub fn getMouseWheelMove(self: *const Self) f32 {
    _ = self;
    return rl.getMouseWheelMove();
}
