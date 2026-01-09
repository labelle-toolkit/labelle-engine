//! GUI Hook System
//!
//! Type-safe, comptime-based hook system for GUI interactions.
//! Provides rich payloads with full context (mouse position, values, element info).
//!
//! ## Overview
//!
//! The GUI hook system allows games to react to GUI interactions (button clicks,
//! checkbox toggles, slider changes) using the same comptime hook pattern as
//! engine lifecycle events.
//!
//! ## Usage
//!
//! Define a hook handler struct with functions matching hook names:
//!
//! ```zig
//! const GuiHandlers = struct {
//!     pub fn button_clicked(payload: gui.GuiHookPayload) void {
//!         const info = payload.button_clicked;
//!         std.log.info("Button clicked: {s}", .{info.element.id});
//!     }
//!
//!     pub fn slider_changed(payload: gui.GuiHookPayload) void {
//!         const info = payload.slider_changed;
//!         std.log.info("Slider changed: {s} = {d}", .{info.element.id, info.new_value});
//!     }
//! };
//!
//! // Create a dispatcher
//! const Dispatcher = gui.GuiHookDispatcher(GuiHandlers);
//!
//! // Emit events (typically done by GUI backends)
//! Dispatcher.emit(.{
//!     .button_clicked = .{
//!         .element = button,
//!         .mouse_pos = .{ .x = 100, .y = 200 },
//!     }
//! });
//! ```

const std = @import("std");
const types = @import("types.zig");
const hooks = @import("../hooks/mod.zig");

/// GUI interaction hook types
pub const GuiHook = enum {
    button_clicked,
    checkbox_changed,
    slider_changed,
};

/// Mouse position information
pub const MousePosition = struct {
    x: f32,
    y: f32,
};

/// Button click payload
pub const ButtonClickedInfo = struct {
    /// The button element that was clicked
    element: types.Button,
    /// Mouse position when clicked
    mouse_pos: MousePosition,
    /// Frame number when clicked
    frame_number: u64 = 0,
};

/// Checkbox change payload
pub const CheckboxChangedInfo = struct {
    /// The checkbox element
    element: types.Checkbox,
    /// New checked state
    new_value: bool,
    /// Previous checked state
    old_value: bool,
    /// Mouse position when toggled
    mouse_pos: MousePosition,
    /// Frame number when changed
    frame_number: u64 = 0,
};

/// Slider change payload
pub const SliderChangedInfo = struct {
    /// The slider element
    element: types.Slider,
    /// New slider value
    new_value: f32,
    /// Previous slider value
    old_value: f32,
    /// Mouse position when changed
    mouse_pos: MousePosition,
    /// Frame number when changed
    frame_number: u64 = 0,
};

/// Type-safe payload union for GUI hooks.
/// Each hook type has its corresponding payload type with rich context.
pub const GuiHookPayload = union(GuiHook) {
    button_clicked: ButtonClickedInfo,
    checkbox_changed: CheckboxChangedInfo,
    slider_changed: SliderChangedInfo,
};

/// Convenience type for creating a GUI hook dispatcher.
/// Equivalent to `hooks.HookDispatcher(GuiHook, GuiHookPayload, HookMap)`.
pub fn GuiHookDispatcher(comptime HookMap: type) type {
    return hooks.HookDispatcher(GuiHook, GuiHookPayload, HookMap);
}

/// Convenience type for merging multiple GUI hook handler structs.
/// Equivalent to `hooks.MergeHooks(GuiHook, GuiHookPayload, handler_structs)`.
///
/// Example:
/// ```zig
/// const AllGuiHooks = MergeGuiHooks(.{ FormHandlers, DebugHandlers });
/// const Dispatcher = GuiHookDispatcher(AllGuiHooks);
/// ```
pub fn MergeGuiHooks(comptime handler_structs: anytype) type {
    return hooks.MergeHooks(GuiHook, GuiHookPayload, handler_structs);
}

/// An empty GUI hook dispatcher with no handlers.
/// Useful as a default when no GUI hooks are needed.
pub const EmptyGuiDispatcher = hooks.EmptyDispatcher(GuiHook, GuiHookPayload);
