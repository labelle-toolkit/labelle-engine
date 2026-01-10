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

/// Merge multiple GUI hook handler structs into a single dispatcher
///
/// This function combines multiple GUI hook handler structs, allowing each handler
/// function to be called when its event fires. Handler functions are auto-generated
/// from the GuiHook enum fields at comptime.
///
/// Example:
/// ```zig
/// const FormHandlers = struct {
///     pub fn slider_changed(payload: GuiHookPayload) void { ... }
/// };
/// const LoggingHandlers = struct {
///     pub fn slider_changed(payload: GuiHookPayload) void { ... }
/// };
/// const Combined = MergeGuiHooks(.{ FormHandlers, LoggingHandlers });
/// // Both handlers are called on slider_changed events
/// ```
pub fn MergeGuiHooks(comptime handler_structs: anytype) type {
    const handler_info = @typeInfo(@TypeOf(handler_structs));
    if (handler_info != .@"struct") {
        @compileError("MergeGuiHooks expects a tuple of handler structs");
    }

    return struct {
        /// Internal helper that dispatches to all handlers for a given hook name
        fn dispatchToHandlers(comptime hook_name: []const u8, payload: GuiHookPayload) void {
            inline for (handler_info.@"struct".fields) |field| {
                const handler_struct = @field(handler_structs, field.name);
                if (@hasDecl(@TypeOf(handler_struct), hook_name)) {
                    @field(@TypeOf(handler_struct), hook_name)(payload);
                }
            }
        }

        // Auto-generate handler functions from GuiHook enum fields
        pub fn button_clicked(payload: GuiHookPayload) void {
            dispatchToHandlers("button_clicked", payload);
        }

        pub fn checkbox_changed(payload: GuiHookPayload) void {
            dispatchToHandlers("checkbox_changed", payload);
        }

        pub fn slider_changed(payload: GuiHookPayload) void {
            dispatchToHandlers("slider_changed", payload);
        }
    };
}

/// Empty GUI dispatcher (no-op)
pub const EmptyGuiDispatcher = struct {
    pub fn emit(_: GuiHookPayload) void {}
};

// Unit tests
test "MergeGuiHooks dispatches to all handlers" {
    var handler1_called = false;
    var handler2_called = false;

    const Handler1 = struct {
        var called: *bool = undefined;
        pub fn slider_changed(_: GuiHookPayload) void {
            called.* = true;
        }
    };
    Handler1.called = &handler1_called;

    const Handler2 = struct {
        var called: *bool = undefined;
        pub fn slider_changed(_: GuiHookPayload) void {
            called.* = true;
        }
    };
    Handler2.called = &handler2_called;

    const Merged = MergeGuiHooks(.{ Handler1, Handler2 });
    Merged.slider_changed(.{ .slider_changed = .{ .new_value = 0.5, .old_value = 0.0 } });

    try std.testing.expect(handler1_called);
    try std.testing.expect(handler2_called);
}

test "MergeGuiHooks skips handlers without matching decl" {
    var handler1_called = false;

    const Handler1 = struct {
        var called: *bool = undefined;
        pub fn button_clicked(_: GuiHookPayload) void {
            called.* = true;
        }
    };
    Handler1.called = &handler1_called;

    // Handler2 has no button_clicked - should be skipped
    const Handler2 = struct {
        pub fn slider_changed(_: GuiHookPayload) void {}
    };

    const Merged = MergeGuiHooks(.{ Handler1, Handler2 });
    Merged.button_clicked(.{ .button_clicked = .{} });

    try std.testing.expect(handler1_called);
}

test "MergeGuiHooks works with GuiHookDispatcher" {
    var handler_called = false;

    const Handler = struct {
        var called: *bool = undefined;
        pub fn checkbox_changed(_: GuiHookPayload) void {
            called.* = true;
        }
    };
    Handler.called = &handler_called;

    const Merged = MergeGuiHooks(.{Handler});
    const Dispatcher = GuiHookDispatcher(Merged);

    Dispatcher.emit(.{ .checkbox_changed = .{ .new_value = true, .old_value = false } });

    try std.testing.expect(handler_called);
}
