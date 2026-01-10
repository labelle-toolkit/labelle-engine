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
pub const TouchPhase = types.TouchPhase;
pub const Touch = types.Touch;
pub const MAX_TOUCHES = types.MAX_TOUCHES;

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

// Touch state tracking
touches: [MAX_TOUCHES]Touch = [_]Touch{.{}} ** MAX_TOUCHES,
touch_count: u32 = 0,

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

    // Remove ended/cancelled touches from previous frame
    var i: u32 = 0;
    while (i < self.touch_count) {
        if (self.touches[i].phase == .ended or self.touches[i].phase == .cancelled) {
            // Remove this touch by shifting remaining touches
            var j = i;
            while (j + 1 < self.touch_count) : (j += 1) {
                self.touches[j] = self.touches[j + 1];
            }
            self.touch_count -= 1;
        } else {
            i += 1;
        }
    }
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
            // Accumulate scroll events within a frame
            self.mouse_wheel += event.scroll_y;
        },
        // Touch events (iOS/Android/touch screens)
        .TOUCHES_BEGAN => self.handleTouchEvent(event, .began),
        .TOUCHES_MOVED => self.handleTouchEvent(event, .moved),
        .TOUCHES_ENDED => self.handleTouchEvent(event, .ended),
        .TOUCHES_CANCELLED => self.handleTouchEvent(event, .cancelled),
        else => {},
    }
}

/// Handle touch events from sokol
fn handleTouchEvent(self: *Self, event: *const sapp.Event, phase: TouchPhase) void {
    // Process each touch point in the event
    var i: u32 = 0;
    while (i < event.num_touches) : (i += 1) {
        const sokol_touch = event.touches[i];
        if (!sokol_touch.changed) continue;

        const touch = Touch{
            .id = sokol_touch.identifier,
            .x = sokol_touch.pos_x,
            .y = sokol_touch.pos_y,
            .phase = phase,
        };

        // Find existing touch with same ID and update it
        var found = false;
        for (self.touches[0..self.touch_count]) |*existing| {
            if (existing.id == touch.id) {
                existing.* = touch;
                found = true;
                break;
            }
        }

        // Add new touch if not found and we have room
        if (!found and self.touch_count < MAX_TOUCHES) {
            self.touches[self.touch_count] = touch;
            self.touch_count += 1;
        }
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
    if (mouseButtonToIndex(button)) |idx| {
        return self.mouse_states[idx].down;
    }
    return false;
}

/// Check if a mouse button was pressed this frame
pub fn isMouseButtonPressed(self: *const Self, button: MouseButton) bool {
    if (mouseButtonToIndex(button)) |idx| {
        return self.mouse_states[idx].pressed;
    }
    return false;
}

/// Check if a mouse button was released this frame
pub fn isMouseButtonReleased(self: *const Self, button: MouseButton) bool {
    if (mouseButtonToIndex(button)) |idx| {
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

// ==================== Touch Input ====================

/// Get the number of active touches
pub fn getTouchCount(self: *const Self) u32 {
    return self.touch_count;
}

/// Get touch at index (0 to getTouchCount()-1)
/// Returns null if index is out of bounds
pub fn getTouch(self: *const Self, index: u32) ?Touch {
    if (index < self.touch_count) {
        return self.touches[index];
    }
    return null;
}

// ==================== Internal Helpers ====================

/// Convert KeyboardKey enum to array index
fn keyToIndex(key: KeyboardKey) ?usize {
    const val = @intFromEnum(key);
    if (val < MAX_KEYS) {
        return @intCast(val);
    }
    return null;
}

/// Convert MouseButton enum to array index
fn mouseButtonToIndex(button: MouseButton) ?usize {
    const val = @intFromEnum(button);
    if (val < MAX_MOUSE_BUTTONS) {
        return @intCast(val);
    }
    return null;
}

/// Convert sokol keycode to our index
/// Sokol keycodes match GLFW/raylib values, so we can use them directly
fn sokolToKeyIndex(keycode: sapp.Keycode) ?usize {
    const val = @intFromEnum(keycode);
    if (val < MAX_KEYS) {
        return @intCast(val);
    }
    return null;
}

/// Convert sokol mouse button to our index
fn sokolToMouseIndex(button: sapp.Mousebutton) ?usize {
    const val = @intFromEnum(button);
    if (val < MAX_MOUSE_BUTTONS) {
        return @intCast(val);
    }
    return null;
}
