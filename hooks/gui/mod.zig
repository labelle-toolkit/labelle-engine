//! GUI Hook System
//!
//! Standalone, type-safe hook system for GUI interactions.
//! Self-contained with no external dependencies.
//!
//! ## Overview
//!
//! Provides a simple comptime hook dispatcher for GUI events with rich payloads.
//!
//! ## Usage
//!
//! ```zig
//! const GuiHandlers = struct {
//!     pub fn button_clicked(payload: gui_hooks.GuiHookPayload) void {
//!         const info = payload.button_clicked;
//!         std.log.info("Button: {s}", .{info.element_id});
//!     }
//!
//!     pub fn slider_changed(payload: gui_hooks.GuiHookPayload) void {
//!         const info = payload.slider_changed;
//!         std.log.info("Slider: {s} = {d}", .{info.element_id, info.new_value});
//!     }
//! };
//!
//! const Dispatcher = gui_hooks.GuiHookDispatcher(GuiHandlers);
//! Dispatcher.emit(.{ .button_clicked = .{ .element_id = "my_button", ...} });
//! ```

const std = @import("std");

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
    /// Element ID
    element_id: ?[]const u8 = null,
    /// Button text
    text: []const u8 = "",
    /// Mouse position when clicked
    mouse_pos: MousePosition = .{ .x = 0, .y = 0 },
    /// Frame number when clicked
    frame_number: u64 = 0,
};

/// Checkbox change payload
pub const CheckboxChangedInfo = struct {
    /// Element ID
    element_id: ?[]const u8 = null,
    /// Label text
    text: []const u8 = "",
    /// New checked state
    new_value: bool,
    /// Previous checked state
    old_value: bool,
    /// Mouse position when toggled
    mouse_pos: MousePosition = .{ .x = 0, .y = 0 },
    /// Frame number when changed
    frame_number: u64 = 0,
};

/// Slider change payload
pub const SliderChangedInfo = struct {
    /// Element ID
    element_id: ?[]const u8 = null,
    /// New slider value
    new_value: f32,
    /// Previous slider value
    old_value: f32,
    /// Minimum value
    min: f32 = 0,
    /// Maximum value
    max: f32 = 100,
    /// Mouse position when changed
    mouse_pos: MousePosition = .{ .x = 0, .y = 0 },
    /// Frame number when changed
    frame_number: u64 = 0,
};

/// Type-safe payload union for GUI hooks
pub const GuiHookPayload = union(GuiHook) {
    button_clicked: ButtonClickedInfo,
    checkbox_changed: CheckboxChangedInfo,
    slider_changed: SliderChangedInfo,
};

/// Standalone GUI hook dispatcher - no external dependencies
pub fn GuiHookDispatcher(comptime HookMap: type) type {
    return struct {
        pub fn emit(payload: GuiHookPayload) void {
            switch (payload) {
                inline else => |_, tag| {
                    const hook_name = @tagName(tag);
                    if (@hasDecl(HookMap, hook_name)) {
                        const handler = @field(HookMap, hook_name);
                        handler(payload);
                    }
                },
            }
        }
    };
}

/// Merge multiple GUI hook handler structs
pub fn MergeGuiHooks(comptime handler_structs: anytype) type {
    // Create a new struct that combines all handlers
    _ = handler_structs;

    // Simplified POC version - just returns empty struct
    // Full implementation would merge all handler functions
    return struct {};
}

/// Empty GUI dispatcher (no-op)
pub const EmptyGuiDispatcher = struct {
    pub fn emit(_: GuiHookPayload) void {}
};
