/// Runtime scene value — the generic tree representation for parsed scene/prefab data.
/// Both the JSONC parser and (future) ZON parser produce this same type,
/// so the downstream pipeline (deserializer, scene loader, hot reload) is format-agnostic.
const std = @import("std");

pub const Value = union(enum) {
    /// { "key": value, ... } or .{ .key = value, ... }
    object: Object,
    /// [ val1, val2, ... ] or .{ val1, val2, ... }
    array: Array,
    /// "hello"
    string: []const u8,
    /// 42, -20
    integer: i64,
    /// 0.9, 3.14
    float: f64,
    /// .hydroponics, .static (ZON only — JSONC uses strings for enums)
    enum_literal: []const u8,
    /// true / false
    boolean: bool,
    /// null
    null_value: void,

    pub const Object = struct {
        entries: []Entry,

        pub const Entry = struct {
            key: []const u8,
            value: Value,
        };

        pub fn get(self: Object, key: []const u8) ?Value {
            for (self.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return null;
        }

        pub fn getObject(self: Object, key: []const u8) ?Object {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .object => |o| o,
                else => null,
            };
        }

        pub fn getArray(self: Object, key: []const u8) ?Array {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .array => |a| a,
                else => null,
            };
        }

        pub fn getString(self: Object, key: []const u8) ?[]const u8 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }

        pub fn getInteger(self: Object, key: []const u8) ?i64 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .integer => |i| i,
                else => null,
            };
        }

        pub fn getFloat(self: Object, key: []const u8) ?f64 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .float => |f| f,
                else => null,
            };
        }

        pub fn getEnum(self: Object, key: []const u8) ?[]const u8 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .enum_literal => |e| e,
                else => null,
            };
        }

        pub fn getBool(self: Object, key: []const u8) ?bool {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .boolean => |b| b,
                else => null,
            };
        }
    };

    pub const Array = struct {
        items: []Value,

        pub fn len(self: Array) usize {
            return self.items.len;
        }
    };

    pub fn asObject(self: Value) ?Object {
        return switch (self) {
            .object => |o| o,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?Array {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInteger(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            else => null,
        };
    }

    pub fn asEnum(self: Value) ?[]const u8 {
        return switch (self) {
            .enum_literal => |e| e,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }
};

pub const Location = struct {
    line: usize,
    column: usize,
    offset: usize,
};
