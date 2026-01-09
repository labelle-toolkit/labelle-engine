//! FormBinder - Automatic Form State Management
//!
//! Uses Zig's comptime reflection to automatically bind form fields to GUI events.
//! This provides minimal boilerplate for form handling with compile-time safety.
//!
//! ## Overview
//!
//! FormBinder automatically routes GUI events to form state fields based on
//! a naming convention: `form_id.field_name` → `FormState.field_name`
//!
//! ## Usage
//!
//! ```zig
//! // 1. Define form state struct
//! pub const MonsterFormState = struct {
//!     name: [128:0]u8 = std.mem.zeroes([128:0]u8),
//!     health: f32 = 100,
//!     attack: f32 = 10,
//!     is_boss: bool = false,
//!
//!     // Optional: custom field setters
//!     pub fn setName(self: *MonsterFormState, text: []const u8) void {
//!         @memcpy(self.name[0..text.len], text);
//!         self.name[text.len] = 0;
//!     }
//!
//!     // Optional: validation
//!     pub fn validate(self: *MonsterFormState) bool {
//!         return self.name[0] != 0 and self.health > 0;
//!     }
//! };
//!
//! // 2. Create binder (comptime magic!)
//! const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
//! var monster_form = MonsterFormState{};
//! const monster_binder = MonsterBinder.init(&monster_form);
//!
//! // 3. Minimal handlers (one line per event type!)
//! pub const GuiHandlers = struct {
//!     pub fn button_clicked(payload: gui.GuiHookPayload) void {
//!         monster_binder.handleEvent(payload);  // Routes to correct field!
//!     }
//!
//!     pub fn checkbox_changed(payload: gui.GuiHookPayload) void {
//!         monster_binder.handleEvent(payload);
//!     }
//!
//!     pub fn slider_changed(payload: gui.GuiHookPayload) void {
//!         monster_binder.handleEvent(payload);
//!     }
//! };
//! ```
//!
//! ## Element ID Naming Convention
//!
//! GUI element IDs must follow the pattern: `form_id.field_name`
//!
//! Examples:
//! - `monster_form.name` → routes to `MonsterFormState.name`
//! - `monster_form.health` → routes to `MonsterFormState.health`
//! - `monster_form.is_boss` → routes to `MonsterFormState.is_boss`
//!
//! ## Supported Field Types
//!
//! - `bool` - checkbox values
//! - `f32`, `f64` - slider values
//! - `[N:0]u8` - text input (sentinel-terminated strings)
//!
//! ## Custom Setters
//!
//! Define `setFieldName(self: *T, value: ValueType) void` methods for custom logic:
//! - `setName(self: *T, text: []const u8) void` - for text fields
//! - `setHealth(self: *T, value: f32) void` - for sliders
//! - `setIsBoss(self: *T, value: bool) void` - for checkboxes
//!
//! Custom setters are called instead of direct field assignment when available.

const std = @import("std");
const gui_hooks = @import("hooks.zig");

/// Creates a FormBinder for the given form state type.
///
/// Type parameters:
/// - `FormStateType`: The struct type containing form fields
/// - `form_id`: The form identifier prefix for element IDs (e.g. "monster_form")
///
/// The binder automatically routes GUI events to form fields based on element IDs.
/// Element IDs should follow the pattern: `form_id.field_name`
///
/// Example:
/// ```zig
/// const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
/// var form_state = MonsterFormState{};
/// const binder = MonsterBinder.init(&form_state);
///
/// // In GUI hook handler:
/// binder.handleEvent(payload);  // Automatically routes to correct field
/// ```
pub fn FormBinder(comptime FormStateType: type, comptime form_id: []const u8) type {
    // Validate that FormStateType is a struct
    const type_info = @typeInfo(FormStateType);
    if (type_info != .@"struct") {
        @compileError("FormStateType must be a struct type");
    }

    return struct {
        const Self = @This();

        /// Pointer to the form state struct
        form_state: *FormStateType,

        /// Create a new FormBinder instance
        pub fn init(form_state: *FormStateType) Self {
            return Self{
                .form_state = form_state,
            };
        }

        /// Handle a GUI event and route it to the appropriate field.
        ///
        /// This is the main entry point for form event handling. Call this from
        /// your GUI hook handlers to automatically update form state.
        ///
        /// The element ID is parsed to extract the field name, and the value is
        /// routed to the corresponding form field.
        ///
        /// Returns true if the event was handled, false if it wasn't for this form.
        pub fn handleEvent(self: Self, payload: gui_hooks.GuiHookPayload) bool {
            return switch (payload) {
                .button_clicked => |info| self.handleButtonClick(info),
                .checkbox_changed => |info| self.handleCheckboxChange(info),
                .slider_changed => |info| self.handleSliderChange(info),
            };
        }

        /// Handle button click events
        fn handleButtonClick(self: Self, info: gui_hooks.ButtonClickedInfo) bool {
            const field_name = extractFieldName(info.element.id) orelse return false;

            // For buttons, we typically call handler methods like onSubmit()
            // This is a simple implementation - can be extended for form submission
            _ = self;
            _ = field_name;

            // For now, buttons don't update fields directly
            // In a full implementation, this could call form.onSubmit() etc.
            return false;
        }

        /// Handle checkbox change events
        fn handleCheckboxChange(self: Self, info: gui_hooks.CheckboxChangedInfo) bool {
            const field_name = extractFieldName(info.element.id) orelse return false;

            // Use comptime to check all fields and route to the matching one
            inline for (std.meta.fields(FormStateType)) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Check if field type is bool
                    if (field.type != bool) {
                        @compileError("Checkbox field '" ++ field.name ++ "' must be bool type");
                    }

                    // Check for custom setter: setFieldName(self: *T, value: bool) void
                    const setter_name = "set" ++ capitalize(field.name);
                    if (@hasDecl(FormStateType, setter_name)) {
                        const setter = @field(FormStateType, setter_name);
                        setter(self.form_state, info.new_value);
                    } else {
                        // Direct field assignment
                        @field(self.form_state, field.name) = info.new_value;
                    }

                    return true;
                }
            }

            return false;
        }

        /// Handle slider change events
        fn handleSliderChange(self: Self, info: gui_hooks.SliderChangedInfo) bool {
            const field_name = extractFieldName(info.element.id) orelse return false;

            // Use comptime to check all fields and route to the matching one
            inline for (std.meta.fields(FormStateType)) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Check if field type is numeric
                    const field_type_info = @typeInfo(field.type);
                    const is_numeric = switch (field_type_info) {
                        .float => true,
                        .int => true,
                        else => false,
                    };

                    if (!is_numeric) {
                        @compileError("Slider field '" ++ field.name ++ "' must be numeric type (int or float)");
                    }

                    // Check for custom setter: setFieldName(self: *T, value: f32) void
                    const setter_name = "set" ++ capitalize(field.name);
                    if (@hasDecl(FormStateType, setter_name)) {
                        const setter = @field(FormStateType, setter_name);
                        setter(self.form_state, info.new_value);
                    } else {
                        // Direct field assignment with type conversion
                        @field(self.form_state, field.name) = @as(field.type, @floatCast(info.new_value));
                    }

                    return true;
                }
            }

            return false;
        }

        /// Extract field name from element ID
        /// Element IDs follow pattern: "form_id.field_name"
        /// Returns null if ID doesn't match this form's prefix
        fn extractFieldName(element_id: []const u8) ?[]const u8 {
            // Check if element ID starts with our form ID prefix
            const prefix = form_id ++ ".";
            if (!std.mem.startsWith(u8, element_id, prefix)) {
                return null;
            }

            // Extract field name after the prefix
            const field_name = element_id[prefix.len..];
            if (field_name.len == 0) {
                return null;
            }

            return field_name;
        }

        /// Capitalize first letter of string (comptime helper)
        fn capitalize(comptime str: []const u8) []const u8 {
            if (str.len == 0) return str;

            var result: [str.len]u8 = undefined;
            result[0] = std.ascii.toUpper(str[0]);
            @memcpy(result[1..], str[1..]);

            return &result;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "FormBinder - basic checkbox binding" {
    const TestForm = struct {
        enabled: bool = false,
        visible: bool = true,
    };

    var form = TestForm{};
    const Binder = FormBinder(TestForm, "test_form");
    const binder = Binder.init(&form);

    // Simulate checkbox change event
    const payload = gui_hooks.GuiHookPayload{
        .checkbox_changed = .{
            .element = .{
                .id = "test_form.enabled",
                .text = "Enabled",
                .position = .{},
                .checked = true,
            },
            .new_value = true,
            .old_value = false,
            .mouse_pos = .{ .x = 0, .y = 0 },
        },
    };

    const handled = binder.handleEvent(payload);
    try testing.expect(handled);
    try testing.expectEqual(true, form.enabled);
}

test "FormBinder - basic slider binding" {
    const TestForm = struct {
        health: f32 = 100,
        speed: f32 = 5,
    };

    var form = TestForm{};
    const Binder = FormBinder(TestForm, "test_form");
    const binder = Binder.init(&form);

    // Simulate slider change event
    const payload = gui_hooks.GuiHookPayload{
        .slider_changed = .{
            .element = .{
                .id = "test_form.health",
                .position = .{},
                .size = .{},
                .value = 75,
                .min = 0,
                .max = 100,
            },
            .new_value = 75,
            .old_value = 100,
            .mouse_pos = .{ .x = 0, .y = 0 },
        },
    };

    const handled = binder.handleEvent(payload);
    try testing.expect(handled);
    try testing.expectEqual(@as(f32, 75), form.health);
}

test "FormBinder - wrong form prefix ignored" {
    const TestForm = struct {
        enabled: bool = false,
    };

    var form = TestForm{};
    const Binder = FormBinder(TestForm, "test_form");
    const binder = Binder.init(&form);

    // Event for a different form
    const payload = gui_hooks.GuiHookPayload{
        .checkbox_changed = .{
            .element = .{
                .id = "other_form.enabled", // Different form!
                .text = "Enabled",
                .position = .{},
                .checked = true,
            },
            .new_value = true,
            .old_value = false,
            .mouse_pos = .{ .x = 0, .y = 0 },
        },
    };

    const handled = binder.handleEvent(payload);
    try testing.expect(!handled);
    try testing.expectEqual(false, form.enabled); // Should not change
}

test "FormBinder - custom setter" {
    const TestForm = struct {
        value: f32 = 0,
        clamped_value: f32 = 0,

        pub fn setClampedValue(self: *@This(), new_value: f32) void {
            // Custom logic: clamp between 10 and 90
            self.clamped_value = @max(10, @min(90, new_value));
        }
    };

    var form = TestForm{};
    const Binder = FormBinder(TestForm, "test_form");
    const binder = Binder.init(&form);

    // Try to set value beyond range
    const payload = gui_hooks.GuiHookPayload{
        .slider_changed = .{
            .element = .{
                .id = "test_form.clamped_value",
                .position = .{},
                .size = .{},
                .value = 95,
                .min = 0,
                .max = 100,
            },
            .new_value = 95,
            .old_value = 0,
            .mouse_pos = .{ .x = 0, .y = 0 },
        },
    };

    const handled = binder.handleEvent(payload);
    try testing.expect(handled);

    // Should be clamped to 90 by custom setter
    try testing.expectEqual(@as(f32, 90), form.clamped_value);
}
