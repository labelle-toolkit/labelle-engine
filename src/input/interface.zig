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

/// Graphics backend selection (enum type)
pub const Backend = build_options.@"build.Backend";

/// The current graphics backend (enum value)
pub const backend: Backend = build_options.backend;

// Select input backend based on graphics backend
pub const Input = switch (backend) {
    .raylib => @import("raylib_input.zig"),
    .sokol => @import("sokol_input.zig"),
};

/// Comptime interface validation
/// Ensures the selected backend implements all required methods.
fn validateInputInterface(comptime Impl: type) void {
    comptime {
        // Required initialization methods
        if (!@hasDecl(Impl, "init")) @compileError("Input backend must have init method");
        if (!@hasDecl(Impl, "deinit")) @compileError("Input backend must have deinit method");
        if (!@hasDecl(Impl, "beginFrame")) @compileError("Input backend must have beginFrame method");

        // Required keyboard methods
        if (!@hasDecl(Impl, "isKeyDown")) @compileError("Input backend must have isKeyDown method");
        if (!@hasDecl(Impl, "isKeyPressed")) @compileError("Input backend must have isKeyPressed method");
        if (!@hasDecl(Impl, "isKeyReleased")) @compileError("Input backend must have isKeyReleased method");

        // Required mouse methods
        if (!@hasDecl(Impl, "isMouseButtonDown")) @compileError("Input backend must have isMouseButtonDown method");
        if (!@hasDecl(Impl, "isMouseButtonPressed")) @compileError("Input backend must have isMouseButtonPressed method");
        if (!@hasDecl(Impl, "isMouseButtonReleased")) @compileError("Input backend must have isMouseButtonReleased method");
        if (!@hasDecl(Impl, "getMousePosition")) @compileError("Input backend must have getMousePosition method");
        if (!@hasDecl(Impl, "getMouseWheelMove")) @compileError("Input backend must have getMouseWheelMove method");
    }
}

// Validate at comptime
comptime {
    validateInputInterface(Input);
}
