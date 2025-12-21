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
            self.mouse_wheel = @floatFromInt(wheel.delta_y);
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
        .num_lock => 282,
        .print_screen => 283,
        .pause => 284,

        // Modifier keys (GLFW values)
        .left_shift => 340,
        .left_ctrl => 341,
        .left_alt => 342,
        .left_gui => 343,
        .right_shift => 344,
        .right_ctrl => 345,
        .right_alt => 346,
        .right_gui => 347,
        .menu => 348,

        // Keypad
        .kp_0 => 320,
        .kp_1 => 321,
        .kp_2 => 322,
        .kp_3 => 323,
        .kp_4 => 324,
        .kp_5 => 325,
        .kp_6 => 326,
        .kp_7 => 327,
        .kp_8 => 328,
        .kp_9 => 329,
        .kp_period => 330,
        .kp_divide => 331,
        .kp_multiply => 332,
        .kp_minus => 333,
        .kp_plus => 334,
        .kp_enter => 335,
        .kp_equals => 336,

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
        .x1 => @intFromEnum(types.MouseButton.back), // SDL X1 = Back button
        .x2 => @intFromEnum(types.MouseButton.forward), // SDL X2 = Forward button
    };
    return mapped;
}
