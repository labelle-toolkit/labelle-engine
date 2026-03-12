//! Runtime GUI State Management
//!
//! Provides runtime state tracking for GUI elements, including visibility and value overrides.
//! This allows dynamic show/hide and value updates without redefining comptime views.

const std = @import("std");

/// Runtime state for GUI element visibility.
/// Overrides the default `.visible` field on GuiElement at runtime.
pub const VisibilityState = struct {
    overrides: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator) VisibilityState {
        return .{
            .overrides = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *VisibilityState) void {
        self.overrides.deinit();
    }

    pub fn setVisible(self: *VisibilityState, element_id: []const u8, visible: bool) !void {
        try self.overrides.put(element_id, visible);
    }

    /// Get visibility for an element. Returns override if set, otherwise default_visible.
    pub fn isVisible(self: *const VisibilityState, element_id: []const u8, default_visible: bool) bool {
        return self.overrides.get(element_id) orelse default_visible;
    }

    pub fn clear(self: *VisibilityState) void {
        self.overrides.clearRetainingCapacity();
    }

    /// Bulk-apply a visibility map (e.g. from FormBinder.updateVisibility).
    pub fn applyVisibilityMap(self: *VisibilityState, visibility_map: std.StringHashMap(bool)) !void {
        var it = visibility_map.iterator();
        while (it.next()) |entry| {
            try self.setVisible(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

/// Runtime value state for GUI elements (checkboxes, sliders, text inputs).
/// Tracks user interactions so views can reflect current values.
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
        self.freeAllTextValues();
        self.text_values.deinit();
        self.checkbox_values.deinit();
        self.slider_values.deinit();
    }

    fn freeAllTextValues(self: *ValueState) void {
        var it = self.text_values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
    }

    pub fn setCheckbox(self: *ValueState, element_id: []const u8, checked: bool) !void {
        try self.checkbox_values.put(element_id, checked);
    }

    pub fn getCheckbox(self: *const ValueState, element_id: []const u8, default: bool) bool {
        return self.checkbox_values.get(element_id) orelse default;
    }

    pub fn setSlider(self: *ValueState, element_id: []const u8, value: f32) !void {
        try self.slider_values.put(element_id, value);
    }

    pub fn getSlider(self: *const ValueState, element_id: []const u8, default: f32) f32 {
        return self.slider_values.get(element_id) orelse default;
    }

    /// Set text value (makes an owned copy, frees old value).
    pub fn setText(self: *ValueState, element_id: []const u8, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);

        if (try self.text_values.fetchPut(element_id, owned)) |old_entry| {
            self.allocator.free(old_entry.value);
        }
    }

    pub fn getText(self: *const ValueState, element_id: []const u8, default: []const u8) []const u8 {
        return self.text_values.get(element_id) orelse default;
    }

    pub fn clear(self: *ValueState) void {
        self.freeAllTextValues();
        self.text_values.clearRetainingCapacity();
        self.checkbox_values.clearRetainingCapacity();
        self.slider_values.clearRetainingCapacity();
    }
};
