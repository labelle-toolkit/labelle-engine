//! Runtime GUI State Management
//!
//! Provides runtime state tracking for GUI elements, including visibility and value overrides.
//! This allows dynamic show/hide and value updates without redefining comptime views.

const std = @import("std");

/// Runtime state for GUI element visibility
pub const VisibilityState = struct {
    /// Map of element ID -> visibility override
    /// If an element ID is not in this map, use its default visibility from the view definition
    overrides: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator) VisibilityState {
        return .{
            .overrides = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *VisibilityState) void {
        self.overrides.deinit();
    }

    /// Set visibility override for an element
    pub fn setVisible(self: *VisibilityState, element_id: []const u8, visible: bool) !void {
        try self.overrides.put(element_id, visible);
    }

    /// Get visibility for an element, considering overrides
    /// If no override exists, returns the default_visible value
    pub fn isVisible(self: *const VisibilityState, element_id: []const u8, default_visible: bool) bool {
        if (self.overrides.get(element_id)) |override_value| {
            return override_value;
        }
        return default_visible;
    }

    /// Clear all visibility overrides
    pub fn clear(self: *VisibilityState) void {
        self.overrides.clearRetainingCapacity();
    }

    /// Apply visibility map from FormBinder to this state
    pub fn applyVisibilityMap(self: *VisibilityState, visibility_map: std.StringHashMap(bool)) !void {
        var it = visibility_map.iterator();
        while (it.next()) |entry| {
            try self.setVisible(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

/// Runtime value state for GUI elements (checkboxes, sliders, text inputs)
pub const ValueState = struct {
    allocator: std.mem.Allocator,
    checkbox_values: std.StringHashMap(bool),
    slider_values: std.StringHashMap(f32),
    text_values: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ValueState {
        return .{
            .allocator = allocator,
            .checkbox_values = std.StringHashMap(bool).init(allocator),
            .slider_values = std.StringHashMap(f32).init(allocator),
            .text_values = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ValueState) void {
        // Free allocated text values
        var it = self.text_values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.text_values.deinit();
        self.checkbox_values.deinit();
        self.slider_values.deinit();
    }

    /// Set checkbox value
    pub fn setCheckbox(self: *ValueState, element_id: []const u8, checked: bool) !void {
        try self.checkbox_values.put(element_id, checked);
    }

    /// Get checkbox value (returns default if not found)
    pub fn getCheckbox(self: *const ValueState, element_id: []const u8, default: bool) bool {
        return self.checkbox_values.get(element_id) orelse default;
    }

    /// Set slider value
    pub fn setSlider(self: *ValueState, element_id: []const u8, value: f32) !void {
        try self.slider_values.put(element_id, value);
    }

    /// Get slider value (returns default if not found)
    pub fn getSlider(self: *const ValueState, element_id: []const u8, default: f32) f32 {
        return self.slider_values.get(element_id) orelse default;
    }

    /// Set text value (makes a copy)
    pub fn setText(self: *ValueState, element_id: []const u8, text: []const u8) !void {
        // Free old value if exists
        if (self.text_values.get(element_id)) |old_value| {
            self.allocator.free(old_value);
        }
        // Allocate and store new value
        const owned = try self.allocator.dupe(u8, text);
        try self.text_values.put(element_id, owned);
    }

    /// Get text value (returns default if not found)
    pub fn getText(self: *const ValueState, element_id: []const u8, default: []const u8) []const u8 {
        return self.text_values.get(element_id) orelse default;
    }

    /// Clear all value overrides
    pub fn clear(self: *ValueState) void {
        // Free allocated text values before clearing
        var it = self.text_values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.text_values.clearRetainingCapacity();
        self.checkbox_values.clearRetainingCapacity();
        self.slider_values.clearRetainingCapacity();
    }
};
