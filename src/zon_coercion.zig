// Comptime ZON coercion utilities
//
// Converts anonymous structs from .zon files to typed structs at comptime.
// Handles nested struct coercion and tuple-to-slice conversion.
//
// Usage:
//   const MyType = zon.buildStruct(TargetType, zon_data);
//   const field_val = zon.coerceValue(FieldType, zon_value);

const std = @import("std");
const ecs = @import("ecs");

pub const Entity = ecs.Entity;

/// Coerce a comptime ZON value to the expected field type.
/// Handles nested struct coercion and tuple-to-slice conversion.
/// Skips []const Entity fields (entity creation is runtime-only).
pub fn coerceValue(comptime FieldType: type, comptime data_value: anytype) FieldType {
    const DataType = @TypeOf(data_value);
    const field_info = @typeInfo(FieldType);

    // Handle slice types
    if (field_info == .pointer) {
        const ptr_info = field_info.pointer;
        if (ptr_info.size == .slice) {
            const ChildType = ptr_info.child;

            // Skip []const Entity fields - entity creation is a runtime operation
            // and must be handled by the scene loader, not comptime coercion
            if (ChildType == Entity) {
                return &.{};
            }

            const data_info = @typeInfo(DataType);

            // If data is a tuple, convert to slice
            if (data_info == .@"struct" and data_info.@"struct".is_tuple) {
                return tupleToSlice(ChildType, data_value);
            }
        }
    }

    // Handle fixed-size array coercion (tuple to array)
    if (field_info == .array) {
        const arr_info = field_info.array;
        const data_info = @typeInfo(DataType);
        if (data_info == .@"struct" and data_info.@"struct".is_tuple) {
            const tuple_len = data_info.@"struct".fields.len;
            if (tuple_len != arr_info.len) {
                @compileError(std.fmt.comptimePrint(
                    "Array size mismatch: expected {d} elements, got {d}",
                    .{ arr_info.len, tuple_len },
                ));
            }
            var array: [arr_info.len]arr_info.child = undefined;
            inline for (0..arr_info.len) |i| {
                array[i] = coerceValue(arr_info.child, data_value[i]);
            }
            return array;
        }
    }

    // Handle nested struct coercion
    if (field_info == .@"struct" and @typeInfo(DataType) == .@"struct") {
        return buildStruct(FieldType, data_value);
    }

    // Direct assignment for compatible types
    return data_value;
}

/// Build a struct from comptime anonymous struct data.
/// Recursively coerces nested fields.
/// Raises compile error for missing required fields (fields without defaults).
pub fn buildStruct(comptime StructType: type, comptime data: anytype) StructType {
    const fields = std.meta.fields(StructType);
    var result: StructType = undefined;

    inline for (fields) |field| {
        if (@hasField(@TypeOf(data), field.name)) {
            const data_value = @field(data, field.name);
            @field(result, field.name) = coerceValue(field.type, data_value);
        } else if (field.default_value_ptr) |ptr| {
            const default_ptr: *const field.type = @ptrCast(@alignCast(ptr));
            @field(result, field.name) = default_ptr.*;
        } else {
            @compileError("Missing required field '" ++ field.name ++ "' for struct '" ++ @typeName(StructType) ++ "'");
        }
    }

    return result;
}

/// Convert a tuple to a slice at comptime.
/// Recursively coerces each element.
/// Note: Returns pointer to comptime array, which is valid because
/// comptime arrays have static lifetime.
pub fn tupleToSlice(comptime ChildType: type, comptime tuple: anytype) []const ChildType {
    const tuple_info = @typeInfo(@TypeOf(tuple)).@"struct";
    const len = tuple_info.fields.len;

    var array: [len]ChildType = undefined;
    inline for (0..len) |i| {
        array[i] = coerceValue(ChildType, tuple[i]);
    }

    return &array;
}

/// Check if a field type is a slice of Entity
pub fn isEntitySlice(comptime FieldType: type) bool {
    const info = @typeInfo(FieldType);
    if (info == .pointer) {
        const ptr_info = info.pointer;
        if (ptr_info.size == .slice and ptr_info.child == Entity) {
            return true;
        }
    }
    return false;
}

/// Check if a field type is a single Entity (not a slice)
pub fn isEntity(comptime FieldType: type) bool {
    return FieldType == Entity;
}
