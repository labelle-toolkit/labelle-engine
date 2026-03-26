/// Comptime-generated Value → T deserializer.
/// Uses @typeInfo to auto-generate mapping for structs (with defaults),
/// enums, tagged unions, ints, floats, bools, strings, slices, and optionals.
/// Integer-to-float and float-to-integer coercion is automatic.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

pub const DeserializeError = error{
    TypeMismatch,
    MissingRequiredField,
    UnknownEnumValue,
    UnknownUnionField,
    OutOfMemory,
};

/// Deserialize a parsed Value into a concrete Zig type T.
pub fn deserialize(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    return deserializeInner(T, value, allocator);
}

fn deserializeInner(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => return deserializeStruct(T, value, allocator),
        .@"enum" => return deserializeEnum(T, value),
        .@"union" => return deserializeUnion(T, value, allocator),
        .optional => |opt| {
            if (value == .null_value) return null;
            return try deserializeInner(opt.child, value, allocator);
        },
        .bool => {
            if (value.asBool()) |b| return b;
            return error.TypeMismatch;
        },
        .int => return deserializeInt(T, value),
        .float => return deserializeFloat(T, value),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                // []const u8 — string
                if (value.asString()) |s| return s;
                return error.TypeMismatch;
            }
            if (ptr.size == .slice) {
                // []const SomeType — deserialize from array
                return deserializeSlice(ptr.child, value, allocator);
            }
            return error.TypeMismatch;
        },
        else => return error.TypeMismatch,
    }
}

fn deserializeStruct(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };

    const fields = @typeInfo(T).@"struct".fields;
    var result: T = undefined;

    inline for (fields) |field| {
        if (obj.get(field.name)) |field_value| {
            @field(result, field.name) = try deserializeInner(field.type, field_value, allocator);
        } else if (field.default_value_ptr) |default_ptr| {
            const ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
            @field(result, field.name) = ptr.*;
        } else {
            return error.MissingRequiredField;
        }
    }

    return result;
}

fn deserializeEnum(comptime T: type, value: Value) DeserializeError!T {
    const name = switch (value) {
        .enum_literal => |e| e,
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const fields = @typeInfo(T).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return error.UnknownEnumValue;
}

fn deserializeUnion(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };

    // A tagged union is { "variant_name": payload } — exactly one entry.
    if (obj.entries.len != 1) return error.TypeMismatch;

    const entry = obj.entries[0];
    const union_info = @typeInfo(T).@"union";

    inline for (union_info.fields) |field| {
        if (std.mem.eql(u8, entry.key, field.name)) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            }
            const payload = try deserializeInner(field.type, entry.value, allocator);
            return @unionInit(T, field.name, payload);
        }
    }

    return error.UnknownUnionField;
}

fn deserializeInt(comptime T: type, value: Value) DeserializeError!T {
    switch (value) {
        .integer => |i| return std.math.cast(T, i) orelse return error.TypeMismatch,
        .float => |f| {
            if (f != f or f == std.math.inf(f64) or f == -std.math.inf(f64)) return error.TypeMismatch;
            const truncated = @as(i64, @intFromFloat(f));
            return std.math.cast(T, truncated) orelse return error.TypeMismatch;
        },
        else => return error.TypeMismatch,
    }
}

fn deserializeFloat(comptime T: type, value: Value) DeserializeError!T {
    switch (value) {
        .float => |f| {
            if (T == f64) return f;
            // Check f32 range
            if (f != f) return @as(T, @floatCast(f)); // preserve NaN
            if (f > std.math.floatMax(T) or f < -std.math.floatMax(T)) return error.TypeMismatch;
            return @floatCast(f);
        },
        .integer => |i| return @floatFromInt(i),
        else => return error.TypeMismatch,
    }
}

fn deserializeSlice(comptime Child: type, value: Value, allocator: Allocator) DeserializeError![]const Child {
    const arr = switch (value) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const result = allocator.alloc(Child, arr.items.len) catch return error.OutOfMemory;
    for (arr.items, 0..) |item, i| {
        result[i] = try deserializeInner(Child, item, allocator);
    }
    return result;
}

/// A runtime component registry that maps string names to typed deserializers.
/// Built at comptime from a tuple of (name, type) pairs.
pub fn ComponentRegistry(comptime components: anytype) type {
    return struct {
        /// Deserialize a component by name from a parsed Value.
        /// Returns the component as type-erased bytes, or null if unknown.
        pub fn deserializeByName(name: []const u8, value: Value, allocator: Allocator) DeserializeError!?TypeErasedComponent {
            inline for (components) |entry| {
                if (std.mem.eql(u8, name, entry.name)) {
                    const T = entry.type;
                    const comp = try deserialize(T, value, allocator);
                    const slice = allocator.alloc(T, 1) catch return error.OutOfMemory;
                    slice[0] = comp;
                    const bytes: [*]u8 = @ptrCast(slice.ptr);
                    return TypeErasedComponent{
                        .name = entry.name,
                        .data = bytes[0..@sizeOf(T)],
                        .size = @sizeOf(T),
                    };
                }
            }
            return null;
        }

        /// Deserialize a component by its concrete type.
        pub fn deserializeTyped(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
            return deserialize(T, value, allocator);
        }

        /// Check if a component name is registered.
        pub fn has(name: []const u8) bool {
            inline for (components) |entry| {
                if (std.mem.eql(u8, name, entry.name)) return true;
            }
            return false;
        }

        /// Get the number of registered components.
        pub fn count() usize {
            return components.len;
        }

        /// Get the list of registered component names.
        pub fn names() [components.len][]const u8 {
            var result: [components.len][]const u8 = undefined;
            inline for (components, 0..) |entry, i| {
                result[i] = entry.name;
            }
            return result;
        }
    };
}

pub const TypeErasedComponent = struct {
    name: []const u8,
    data: []u8,
    size: usize,

    /// Cast the type-erased data back to a concrete type.
    pub fn as(self: TypeErasedComponent, comptime T: type) *const T {
        return @ptrCast(@alignCast(self.data.ptr));
    }
};

/// Helper to define a component entry for the registry.
pub fn component(comptime name: []const u8, comptime T: type) struct { name: []const u8, type: type } {
    return .{ .name = name, .type = T };
}
