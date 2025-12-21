//! Sokol Input Backend
//!
//! Stateful input implementation for sokol's event-based input system.
//! Since sokol uses event callbacks, we maintain internal state arrays
//! to track key and mouse button states across frames.

const sokol = @import("sokol");
const sapp = sokol.app;
const types = @import("types.zig");

pub const KeyboardKey = types.KeyboardKey;
pub const MouseButton = types.MouseButton;
pub const MousePosition = types.MousePosition;

const Self = @This();

// Maximum keycode value we need to track (based on raylib/GLFW keycodes)
const MAX_KEYS = 512;
const MAX_MOUSE_BUTTONS = 7;

/// Key state flags
const KeyState = packed struct {
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
};

/// Internal state for tracking input
key_states: [MAX_KEYS]KeyState = [_]KeyState{.{}} ** MAX_KEYS,
mouse_states: [MAX_MOUSE_BUTTONS]KeyState = [_]KeyState{.{}} ** MAX_MOUSE_BUTTONS,
mouse_x: f32 = 0,
mouse_y: f32 = 0,
mouse_wheel: f32 = 0,

/// Initialize the input system
pub fn init() Self {
    return .{};
}

/// Clean up the input system
pub fn deinit(self: *Self) void {
    _ = self;
}

/// Called at the start of each frame to clear per-frame flags
pub fn beginFrame(self: *Self) void {
    // Clear pressed/released flags for all keys
    for (&self.key_states) |*state| {
        state.pressed = false;
        state.released = false;
    }
    for (&self.mouse_states) |*state| {
        state.pressed = false;
        state.released = false;
    }
    // Clear mouse wheel (it's a per-frame value)
    self.mouse_wheel = 0;
}

/// Process a sokol event. Call this from your sokol_app event callback.
pub fn processEvent(self: *Self, event: *const sapp.Event) void {
    switch (event.type) {
        .KEY_DOWN => {
            const idx = sokolToKeyIndex(event.key_code);
            if (idx) |i| {
                if (!self.key_states[i].down) {
                    self.key_states[i].pressed = true;
                }
                self.key_states[i].down = true;
            }
        },
        .KEY_UP => {
            const idx = sokolToKeyIndex(event.key_code);
            if (idx) |i| {
                self.key_states[i].down = false;
                self.key_states[i].released = true;
            }
        },
        .MOUSE_DOWN => {
            const idx = sokolToMouseIndex(event.mouse_button);
            if (idx) |i| {
                if (!self.mouse_states[i].down) {
                    self.mouse_states[i].pressed = true;
                }
                self.mouse_states[i].down = true;
            }
        },
        .MOUSE_UP => {
            const idx = sokolToMouseIndex(event.mouse_button);
            if (idx) |i| {
                self.mouse_states[i].down = false;
                self.mouse_states[i].released = true;
            }
        },
        .MOUSE_MOVE => {
            self.mouse_x = event.mouse_x;
            self.mouse_y = event.mouse_y;
        },
        .MOUSE_SCROLL => {
            self.mouse_wheel = event.scroll_y;
        },
        else => {},
    }
}

/// Check if a key is currently held down
pub fn isKeyDown(self: *const Self, key: KeyboardKey) bool {
    const idx = keyToIndex(key);
    if (idx) |i| {
        return self.key_states[i].down;
    }
    return false;
}

/// Check if a key was pressed this frame
pub fn isKeyPressed(self: *const Self, key: KeyboardKey) bool {
    const idx = keyToIndex(key);
    if (idx) |i| {
        return self.key_states[i].pressed;
    }
    return false;
}

/// Check if a key was released this frame
pub fn isKeyReleased(self: *const Self, key: KeyboardKey) bool {
    const idx = keyToIndex(key);
    if (idx) |i| {
        return self.key_states[i].released;
    }
    return false;
}

/// Check if a mouse button is currently held down
pub fn isMouseButtonDown(self: *const Self, button: MouseButton) bool {
    const idx = @as(usize, @intCast(@intFromEnum(button)));
    if (idx < MAX_MOUSE_BUTTONS) {
        return self.mouse_states[idx].down;
    }
    return false;
}

/// Check if a mouse button was pressed this frame
pub fn isMouseButtonPressed(self: *const Self, button: MouseButton) bool {
    const idx = @as(usize, @intCast(@intFromEnum(button)));
    if (idx < MAX_MOUSE_BUTTONS) {
        return self.mouse_states[idx].pressed;
    }
    return false;
}

/// Check if a mouse button was released this frame
pub fn isMouseButtonReleased(self: *const Self, button: MouseButton) bool {
    const idx = @as(usize, @intCast(@intFromEnum(button)));
    if (idx < MAX_MOUSE_BUTTONS) {
        return self.mouse_states[idx].released;
    }
    return false;
}

/// Get the current mouse position
pub fn getMousePosition(self: *const Self) MousePosition {
    return .{ .x = self.mouse_x, .y = self.mouse_y };
}

/// Get the mouse wheel movement (vertical)
pub fn getMouseWheelMove(self: *const Self) f32 {
    return self.mouse_wheel;
}

// ==================== Internal Helpers ====================

/// Convert KeyboardKey enum to array index
fn keyToIndex(key: KeyboardKey) ?usize {
    const val = @intFromEnum(key);
    if (val >= 0 and val < MAX_KEYS) {
        return @intCast(val);
    }
    return null;
}

/// Convert sokol keycode to our index
/// Sokol keycodes match GLFW/raylib values, so we can use them directly
fn sokolToKeyIndex(keycode: sapp.Keycode) ?usize {
    const val = @intFromEnum(keycode);
    if (val >= 0 and val < MAX_KEYS) {
        return @intCast(val);
    }
    return null;
}

/// Convert sokol mouse button to our index
fn sokolToMouseIndex(button: sapp.Mousebutton) ?usize {
    const val = @intFromEnum(button);
    if (val >= 0 and val < MAX_MOUSE_BUTTONS) {
        return @intCast(val);
    }
    return null;
}
