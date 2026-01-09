//! Runtime GUI State Management
//!
//! Provides runtime state tracking for GUI elements, including visibility overrides.
//! This allows dynamic show/hide of elements without redefining comptime views.

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
