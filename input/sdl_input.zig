//! SDL Input Backend
//!
//! Stateful input implementation for SDL's event-based input system.
//! Since SDL uses event polling, we maintain internal state arrays
//! to track key and mouse button states across frames.

const sdl = @import("sdl2");
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

/// Called at the start of each frame to clear per-frame flags and poll events
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

    // Poll SDL events
    while (sdl.pollEvent()) |event| {
        self.processEvent(event);
    }
}

/// Process a single SDL event (internal - called by beginFrame)
fn processEvent(self: *Self, event: sdl.Event) void {
    switch (event) {
        .key_down => |key| {
            const idx = sdlScancodeToKeyIndex(key.scancode);
            if (idx) |i| {
                if (!self.key_states[i].down) {
                    self.key_states[i].pressed = true;
                }
                self.key_states[i].down = true;
            }
        },
        .key_up => |key| {
            const idx = sdlScancodeToKeyIndex(key.scancode);
            if (idx) |i| {
                self.key_states[i].down = false;
                self.key_states[i].released = true;
            }
        },
        .mouse_button_down => |btn| {
            const idx = sdlMouseButtonToIndex(btn.button);
            if (idx) |i| {
                if (!self.mouse_states[i].down) {
                    self.mouse_states[i].pressed = true;
                }
                self.mouse_states[i].down = true;
            }
        },
        .mouse_button_up => |btn| {
            const idx = sdlMouseButtonToIndex(btn.button);
            if (idx) |i| {
                self.mouse_states[i].down = false;
                self.mouse_states[i].released = true;
            }
        },
        .mouse_motion => |motion| {
            self.mouse_x = @floatFromInt(motion.x);
            self.mouse_y = @floatFromInt(motion.y);
        },
        .mouse_wheel => |wheel| {
            // Accumulate scroll events within a frame
            self.mouse_wheel += @floatFromInt(wheel.delta_y);
        },
        // Touch events - SDL uses finger events
        .finger_down => |finger| {
            self.handleFingerEvent(finger, .began);
        },
        .finger_motion => |finger| {
            self.handleFingerEvent(finger, .moved);
        },
        .finger_up => |finger| {
            self.handleFingerEvent(finger, .ended);
        },
        else => {},
    }
}

/// Handle SDL finger/touch events
fn handleFingerEvent(self: *Self, finger: sdl.FingerEvent, phase: TouchPhase) void {
    // SDL finger coordinates are normalized (0-1), convert to screen coords
    // Note: SDL requires window dimensions for proper conversion, for now use raw coords
    const touch = Touch{
        .id = finger.finger_id,
        .x = finger.x,
        .y = finger.y,
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

/// Convert SDL scancode to our KeyboardKey index
/// SDL scancodes need to be mapped to GLFW/raylib keycodes
fn sdlScancodeToKeyIndex(scancode: sdl.Scancode) ?usize {
    // Map SDL scancodes to GLFW/raylib key values
    const mapped: ?c_int = switch (scancode) {
        // Letters (SDL A-Z map to ASCII 65-90)
        .a => 65,
        .b => 66,
        .c => 67,
        .d => 68,
        .e => 69,
        .f => 70,
        .g => 71,
        .h => 72,
        .i => 73,
        .j => 74,
        .k => 75,
        .l => 76,
        .m => 77,
        .n => 78,
        .o => 79,
        .p => 80,
        .q => 81,
        .r => 82,
        .s => 83,
        .t => 84,
        .u => 85,
        .v => 86,
        .w => 87,
        .x => 88,
        .y => 89,
        .z => 90,

        // Numbers (SDL 0-9 map to ASCII 48-57)
        .@"0" => 48,
        .@"1" => 49,
        .@"2" => 50,
        .@"3" => 51,
        .@"4" => 52,
        .@"5" => 53,
        .@"6" => 54,
        .@"7" => 55,
        .@"8" => 56,
        .@"9" => 57,

        // Function keys (GLFW uses 290-301 for F1-F12)
        .f1 => 290,
        .f2 => 291,
        .f3 => 292,
        .f4 => 293,
        .f5 => 294,
        .f6 => 295,
        .f7 => 296,
        .f8 => 297,
        .f9 => 298,
        .f10 => 299,
        .f11 => 300,
        .f12 => 301,

        // Special keys
        .space => 32,
        .apostrophe => 39,
        .comma => 44,
        .minus => 45,
        .period => 46,
        .slash => 47,
        .semicolon => 59,
        .equals => 61,

        // Navigation keys (GLFW values)
        .escape => 256,
        .@"return" => 257,
        .tab => 258,
        .backspace => 259,
        .insert => 260,
        .delete => 261,
        .right => 262,
        .left => 263,
        .down => 264,
        .up => 265,
        .page_up => 266,
        .page_down => 267,
        .home => 268,
        .end => 269,

        // Lock keys
        .caps_lock => 280,
        .scroll_lock => 281,
        .num_lock_clear => 282,
        .print_screen => 283,
        .pause => 284,

        // Modifier keys (GLFW values)
        .left_shift => 340,
        .left_control => 341,
        .left_alt => 342,
        .left_gui => 343,
        .right_shift => 344,
        .right_control => 345,
        .right_alt => 346,
        .right_gui => 347,
        .application => 348,

        // Keypad
        .keypad_0 => 320,
        .keypad_1 => 321,
        .keypad_2 => 322,
        .keypad_3 => 323,
        .keypad_4 => 324,
        .keypad_5 => 325,
        .keypad_6 => 326,
        .keypad_7 => 327,
        .keypad_8 => 328,
        .keypad_9 => 329,
        .keypad_period => 330,
        .keypad_divide => 331,
        .keypad_multiply => 332,
        .keypad_minus => 333,
        .keypad_plus => 334,
        .keypad_enter => 335,
        .keypad_equals => 336,

        else => null,
    };

    if (mapped) |val| {
        if (val < MAX_KEYS) {
            return @intCast(val);
        }
    }
    return null;
}

/// Convert SDL mouse button to our index
fn sdlMouseButtonToIndex(button: sdl.MouseButton) ?usize {
    const mapped: ?usize = switch (button) {
        .left => @intFromEnum(types.MouseButton.left),
        .right => @intFromEnum(types.MouseButton.right),
        .middle => @intFromEnum(types.MouseButton.middle),
        .extra_1 => @intFromEnum(types.MouseButton.back), // SDL X1 = Back button
        .extra_2 => @intFromEnum(types.MouseButton.forward), // SDL X2 = Forward button
    };
    return mapped;
}
