//! Raylib Input Backend
//!
//! Stateless input implementation that wraps raylib input functions.
//! Raylib uses polling-based input, so all functions directly delegate to raylib.

const rl = @import("raylib");
const types = @import("types.zig");

pub const KeyboardKey = types.KeyboardKey;
pub const MouseButton = types.MouseButton;
pub const MousePosition = types.MousePosition;
pub const TouchPhase = types.TouchPhase;
pub const Touch = types.Touch;
pub const MAX_TOUCHES = types.MAX_TOUCHES;

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

/// Get the number of active touches
pub fn getTouchCount(self: *const Self) u32 {
    _ = self;
    const count = rl.getTouchPointCount();
    if (count < 0) return 0;
    return @intCast(@min(@as(u32, @intCast(count)), MAX_TOUCHES));
}

/// Get touch at index
/// Note: Raylib polling mode can't distinguish touch phases, so all touches
/// are reported as .moved. For proper touch lifecycle, use sokol backend.
pub fn getTouch(self: *const Self, index: u32) ?Touch {
    _ = self;
    const count = rl.getTouchPointCount();
    if (count < 0 or index >= @as(u32, @intCast(count))) return null;

    const pos = rl.getTouchPosition(@intCast(index));
    const id = rl.getTouchPointId(@intCast(index));

    return Touch{
        .id = if (id >= 0) @intCast(id) else 0,
        .x = pos.x,
        .y = pos.y,
        .phase = .moved, // Raylib polling can't distinguish phases
    };
}
