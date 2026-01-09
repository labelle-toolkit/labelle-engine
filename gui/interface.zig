//! GUI Backend Interface
//!
//! Provides a comptime-validated interface for GUI backends.
//! The selected backend is determined at build time via the -Dgui_backend option.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");

pub const GuiBackend = build_options.GuiBackend;
pub const GraphicsBackend = build_options.Backend;
const gui_backend = build_options.gui_backend;
const gfx_backend = build_options.backend;

/// Comptime interface validation for GUI backends.
/// Ensures all required methods are implemented.
pub fn GuiInterface(comptime Impl: type) type {
    comptime {
        // Required lifecycle methods
        if (!@hasDecl(Impl, "init")) @compileError("GUI backend must have init()");
        if (!@hasDecl(Impl, "fixPointers")) @compileError("GUI backend must have fixPointers()");
        if (!@hasDecl(Impl, "deinit")) @compileError("GUI backend must have deinit()");
        if (!@hasDecl(Impl, "beginFrame")) @compileError("GUI backend must have beginFrame()");
        if (!@hasDecl(Impl, "endFrame")) @compileError("GUI backend must have endFrame()");

        // Required element methods
        if (!@hasDecl(Impl, "label")) @compileError("GUI backend must have label()");
        if (!@hasDecl(Impl, "button")) @compileError("GUI backend must have button()");
        if (!@hasDecl(Impl, "progressBar")) @compileError("GUI backend must have progressBar()");
        if (!@hasDecl(Impl, "beginPanel")) @compileError("GUI backend must have beginPanel()");
        if (!@hasDecl(Impl, "endPanel")) @compileError("GUI backend must have endPanel()");
        if (!@hasDecl(Impl, "image")) @compileError("GUI backend must have image()");
        if (!@hasDecl(Impl, "checkbox")) @compileError("GUI backend must have checkbox()");
        if (!@hasDecl(Impl, "slider")) @compileError("GUI backend must have slider()");
    }
    return Impl;
}

/// Select nuklear adapter based on graphics backend
fn selectNuklearAdapter() type {
    return switch (gfx_backend) {
        .sokol => @import("nuklear_sokol_adapter.zig"),
        .sdl => @import("nuklear_sdl_adapter.zig"),
        .bgfx => @import("nuklear_bgfx_adapter.zig"),
        .zgpu => @import("nuklear_zgpu_adapter.zig"),
        else => @import("nuklear_adapter.zig"), // raylib (default)
    };
}

/// Backend implementation selected at build time
const BackendImpl = switch (gui_backend) {
    .raygui => @import("raygui_adapter.zig"),
    .microui => @import("microui_adapter.zig"),
    .nuklear => selectNuklearAdapter(),
    .none => @import("stub_adapter.zig"),
};

/// The selected GUI backend
pub const Gui = GuiInterface(BackendImpl);

// Re-export types for convenience
pub const GuiElement = types.GuiElement;
pub const Label = types.Label;
pub const Button = types.Button;
pub const ProgressBar = types.ProgressBar;
pub const Panel = types.Panel;
pub const Image = types.Image;
pub const Checkbox = types.Checkbox;
pub const Slider = types.Slider;
pub const Color = types.Color;
pub const Position = types.Position;
pub const Size = types.Size;
