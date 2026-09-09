//! Shared handler-order log for the tracing harness.
//!
//! Receivers are distinct TYPES, so an order assertion needs one sink
//! they all append to. Kept free of two-parameter `pub fn`s: `MergeHooks`
//! reads every `pub` declaration of a receiver and rejects any two-param
//! function that is not an event name, and the receivers hold a `*Log`.

const std = @import("std");

pub const Log = struct {
    entries: [64][]const u8 = undefined,
    len: usize = 0,

    pub fn push(self: *Log, label: []const u8) void {
        if (self.len < self.entries.len) {
            self.entries[self.len] = label;
            self.len += 1;
        }
    }

    pub fn reset(self: *Log) void {
        self.len = 0;
    }

    pub fn items(self: *const Log) []const []const u8 {
        return self.entries[0..self.len];
    }

    pub fn eql(self: *const Log, other: *const Log) bool {
        if (self.len != other.len) return false;
        for (self.items(), other.items()) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }

    pub fn matches(self: *const Log, expected: []const []const u8) bool {
        if (self.len != expected.len) return false;
        for (self.items(), expected) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }
};
