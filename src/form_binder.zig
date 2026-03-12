//! FormBinder — Automatic Form State Management
//!
//! Uses comptime reflection to bind form fields to GUI events by naming convention.
//! Element IDs follow: `form_id.field_name` → `FormState.field_name`
//!
//! Supported field types:
//! - `bool` — checkbox values
//! - `f32`, `f64` — slider values
//! - `[N:0]u8` — text input (sentinel-terminated strings)
//!
//! Custom setters: define `setFieldName(self: *T, value) void` for validation/clamping.

const std = @import("std");

/// GUI event types for form binding.
pub const GuiEvent = union(enum) {
    checkbox_changed: struct { element_id: []const u8, value: bool },
    slider_changed: struct { element_id: []const u8, value: f32 },
    text_changed: struct { element_id: []const u8, value: []const u8 },
    button_clicked: struct { element_id: []const u8 },
};

/// Creates a FormBinder for the given form state type.
///
/// - `FormStateType`: struct containing form fields
/// - `form_id`: prefix for element IDs (e.g. "monster_form")
///
/// Element IDs: `form_id.field_name` → routes to `FormState.field_name`
pub fn FormBinder(comptime FormStateType: type, comptime form_id: []const u8) type {
    const type_info = @typeInfo(FormStateType);
    if (type_info != .@"struct") {
        @compileError("FormStateType must be a struct type");
    }

    return struct {
        const Self = @This();

        form_state: *FormStateType,

        pub fn init(form_state: *FormStateType) Self {
            return .{ .form_state = form_state };
        }

        /// Handle a GUI event and route to the appropriate field.
        /// Returns true if the event was handled by this form.
        pub fn handleEvent(self: Self, event: GuiEvent) bool {
            return switch (event) {
                .checkbox_changed => |info| self.handleCheckbox(info.element_id, info.value),
                .slider_changed => |info| self.handleSlider(info.element_id, info.value),
                .text_changed => |info| self.handleText(info.element_id, info.value),
                .button_clicked => false, // Buttons don't update fields directly
            };
        }

        fn handleCheckbox(self: Self, element_id: []const u8, value: bool) bool {
            const field_name = extractFieldName(element_id) orelse return false;
            inline for (std.meta.fields(FormStateType)) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    if (field.type == bool) {
                        const setter_name = comptime "set" ++ snakeToPascalCase(field.name);
                        if (@hasDecl(FormStateType, setter_name)) {
                            @field(FormStateType, setter_name)(self.form_state, value);
                        } else {
                            @field(self.form_state, field.name) = value;
                        }
                        return true;
                    }
                    return false;
                }
            }
            return false;
        }

        fn handleSlider(self: Self, element_id: []const u8, value: f32) bool {
            const field_name = extractFieldName(element_id) orelse return false;
            inline for (std.meta.fields(FormStateType)) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    const fti = @typeInfo(field.type);
                    const is_numeric = fti == .float or fti == .int;
                    if (is_numeric) {
                        const setter_name = comptime "set" ++ snakeToPascalCase(field.name);
                        if (@hasDecl(FormStateType, setter_name)) {
                            @field(FormStateType, setter_name)(self.form_state, value);
                        } else {
                            if (fti == .int) {
                                @field(self.form_state, field.name) = @intFromFloat(value);
                            } else {
                                @field(self.form_state, field.name) = @floatCast(value);
                            }
                        }
                        return true;
                    }
                    return false;
                }
            }
            return false;
        }

        fn handleText(self: Self, element_id: []const u8, value: []const u8) bool {
            const field_name = extractFieldName(element_id) orelse return false;
            inline for (std.meta.fields(FormStateType)) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Check for [N:0]u8 sentinel-terminated arrays
                    const fti = @typeInfo(field.type);
                    if (fti == .array and fti.array.child == u8) {
                        const setter_name = comptime "set" ++ snakeToPascalCase(field.name);
                        if (@hasDecl(FormStateType, setter_name)) {
                            @field(FormStateType, setter_name)(self.form_state, value);
                        } else {
                            const buf = &@field(self.form_state, field.name);
                            const copy_len = @min(value.len, buf.len);
                            @memcpy(buf[0..copy_len], value[0..copy_len]);
                            if (copy_len < buf.len) buf[copy_len] = 0;
                        }
                        return true;
                    }
                    return false;
                }
            }
            return false;
        }

        fn extractFieldName(element_id: []const u8) ?[]const u8 {
            const prefix = form_id ++ ".";
            if (!std.mem.startsWith(u8, element_id, prefix)) return null;
            const field_name = element_id[prefix.len..];
            if (field_name.len == 0) return null;
            return field_name;
        }

        fn snakeToPascalCase(comptime str: []const u8) []const u8 {
            comptime {
                if (str.len == 0) return "";
                var result: []const u8 = "";
                var capitalize_next = true;
                for (str) |c| {
                    if (c == '_') {
                        capitalize_next = true;
                    } else if (capitalize_next) {
                        result = result ++ &[_]u8{std.ascii.toUpper(c)};
                        capitalize_next = false;
                    } else {
                        result = result ++ &[_]u8{c};
                    }
                }
                return result;
            }
        }

        // ── Conditional Visibility ───────────────────────────────

        pub const ElementMap = std.StringHashMap(bool);

        /// Check if a single element should be visible based on form state.
        pub fn evaluateVisibility(self: Self, element_id: []const u8) bool {
            if (!@hasDecl(FormStateType, "VisibilityRules")) return true;
            if (@hasDecl(FormStateType, "isVisible")) {
                return self.form_state.isVisible(element_id);
            }
            return true;
        }

        /// Evaluate all visibility rules, returning element ID → visible map.
        pub fn updateVisibility(self: Self, allocator: std.mem.Allocator) !ElementMap {
            var visibility = ElementMap.init(allocator);
            errdefer visibility.deinit();

            if (!@hasDecl(FormStateType, "VisibilityRules")) return visibility;

            const VisibilityRules = @field(FormStateType, "VisibilityRules");
            inline for (std.meta.fields(VisibilityRules)) |field| {
                try visibility.put(field.name, self.evaluateVisibility(field.name));
            }
            return visibility;
        }

        /// Evaluate visibility rules via a callback (no allocation needed).
        pub fn updateVisibilityWith(
            self: Self,
            comptime callback: fn (element_id: []const u8, visible: bool) void,
        ) void {
            if (!@hasDecl(FormStateType, "VisibilityRules")) return;
            const VisibilityRules = @field(FormStateType, "VisibilityRules");
            inline for (std.meta.fields(VisibilityRules)) |field| {
                callback(field.name, self.evaluateVisibility(field.name));
            }
        }
    };
}
