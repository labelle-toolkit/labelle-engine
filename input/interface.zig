//! Input Interface
//!
//! Provides a unified input API with compile-time backend selection.
//! The backend is chosen at build time based on the graphics backend.
//!
//! Usage:
//!   const input = @import("input");
//!   var inp = input.Input.init();
//!   if (inp.isKeyPressed(.space)) { jump(); }
//!   if (inp.isKeyDown(.left)) { moveLeft(dt); }

const build_options = @import("build_options");

// Re-export types
pub const types = @import("types.zig");
pub const KeyboardKey = types.KeyboardKey;
pub const MouseButton = types.MouseButton;
pub const MousePosition = types.MousePosition;
pub const TouchPhase = types.TouchPhase;
pub const Touch = types.Touch;
pub const MAX_TOUCHES = types.MAX_TOUCHES;

// Gesture recognition
pub const gestures = @import("gestures.zig");
pub const Gestures = gestures.Gestures;
pub const SwipeDirection = gestures.SwipeDirection;
pub const Pinch = gestures.Pinch;
pub const Pan = gestures.Pan;
pub const Swipe = gestures.Swipe;
pub const Tap = gestures.Tap;
pub const DoubleTap = gestures.DoubleTap;
pub const LongPress = gestures.LongPress;
pub const Rotation = gestures.Rotation;

/// Graphics backend selection (enum type)
pub const Backend = build_options.@"build.Backend";

/// The current graphics backend (enum value)
pub const backend: Backend = build_options.backend;

/// Creates a validated input interface from an implementation type.
/// The implementation must provide all required methods.
pub fn InputInterface(comptime Impl: type) type {
    // Compile-time validation: ensure Impl has all required methods
    comptime {
        if (!@hasDecl(Impl, "init")) @compileError("Input backend must have init method");
        if (!@hasDecl(Impl, "deinit")) @compileError("Input backend must have deinit method");
        if (!@hasDecl(Impl, "beginFrame")) @compileError("Input backend must have beginFrame method");
        if (!@hasDecl(Impl, "isKeyDown")) @compileError("Input backend must have isKeyDown method");
        if (!@hasDecl(Impl, "isKeyPressed")) @compileError("Input backend must have isKeyPressed method");
        if (!@hasDecl(Impl, "isKeyReleased")) @compileError("Input backend must have isKeyReleased method");
        if (!@hasDecl(Impl, "isMouseButtonDown")) @compileError("Input backend must have isMouseButtonDown method");
        if (!@hasDecl(Impl, "isMouseButtonPressed")) @compileError("Input backend must have isMouseButtonPressed method");
        if (!@hasDecl(Impl, "isMouseButtonReleased")) @compileError("Input backend must have isMouseButtonReleased method");
        if (!@hasDecl(Impl, "getMousePosition")) @compileError("Input backend must have getMousePosition method");
        if (!@hasDecl(Impl, "getMouseWheelMove")) @compileError("Input backend must have getMouseWheelMove method");
        // Touch input methods (required for all backends, stubs return 0/null)
        if (!@hasDecl(Impl, "getTouchCount")) @compileError("Input backend must have getTouchCount method");
        if (!@hasDecl(Impl, "getTouch")) @compileError("Input backend must have getTouch method");
    }

    return struct {
        const Self = @This();

        /// The underlying implementation type
        pub const Implementation = Impl;

        impl: Impl,

        /// Initialize the input system
        pub fn init() Self {
            return .{ .impl = Impl.init() };
        }

        /// Clean up the input system
        pub fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        /// Called at the start of each frame to clear per-frame state
        pub fn beginFrame(self: *Self) void {
            self.impl.beginFrame();
        }

        /// Check if a key is currently held down
        pub fn isKeyDown(self: *const Self, key: KeyboardKey) bool {
            return self.impl.isKeyDown(key);
        }

        /// Check if a key was pressed this frame
        pub fn isKeyPressed(self: *const Self, key: KeyboardKey) bool {
            return self.impl.isKeyPressed(key);
        }

        /// Check if a key was released this frame
        pub fn isKeyReleased(self: *const Self, key: KeyboardKey) bool {
            return self.impl.isKeyReleased(key);
        }

        /// Check if a mouse button is currently held down
        pub fn isMouseButtonDown(self: *const Self, button: MouseButton) bool {
            return self.impl.isMouseButtonDown(button);
        }

        /// Check if a mouse button was pressed this frame
        pub fn isMouseButtonPressed(self: *const Self, button: MouseButton) bool {
            return self.impl.isMouseButtonPressed(button);
        }

        /// Check if a mouse button was released this frame
        pub fn isMouseButtonReleased(self: *const Self, button: MouseButton) bool {
            return self.impl.isMouseButtonReleased(button);
        }

        /// Get the current mouse position
        pub fn getMousePosition(self: *const Self) MousePosition {
            return self.impl.getMousePosition();
        }

        /// Get the mouse wheel movement (vertical)
        pub fn getMouseWheelMove(self: *const Self) f32 {
            return self.impl.getMouseWheelMove();
        }

        // =============================================
        // Touch Input API
        // =============================================

        /// Get the number of active touches
        pub fn getTouchCount(self: *const Self) u32 {
            return self.impl.getTouchCount();
        }

        /// Get touch at index (0 to getTouchCount()-1)
        /// Returns null if index is out of bounds
        pub fn getTouch(self: *const Self, index: u32) ?Touch {
            return self.impl.getTouch(index);
        }

        /// Process a backend-specific event (only available for sokol backend)
        pub fn processEvent(self: *Self, event: anytype) void {
            if (@hasDecl(Impl, "processEvent")) {
                self.impl.processEvent(event);
            }
        }
    };
}

// Select and validate input backend based on graphics backend
const BackendImpl = switch (backend) {
    .raylib => @import("raylib_input.zig"),
    .sokol => @import("sokol_input.zig"),
    .sdl => @import("sdl_input.zig"),
    .bgfx => @import("stub_input.zig"), // bgfx handles input via GLFW in main loop
    .zgpu => @import("stub_input.zig"), // zgpu handles input via GLFW in main loop
    .wgpu_native => @import("stub_input.zig"), // wgpu_native handles input via GLFW in main loop
};

/// The Input type for the selected backend
pub const Input = InputInterface(BackendImpl);
