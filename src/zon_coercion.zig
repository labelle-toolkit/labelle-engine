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

/// Check if a component uses flattened shape syntax.
/// Flattened format: .{ .type = .circle, .radius = 20, .color = ... }
/// Returns true if data has a .type field and component has a 'shape' union field.
pub fn isFlattenedShapeComponent(comptime ComponentType: type, comptime data: anytype) bool {
    const DataType = @TypeOf(data);
    if (!@hasField(DataType, "type")) return false;

    const comp_fields = std.meta.fields(ComponentType);
    for (comp_fields) |cf| {
        if (std.mem.eql(u8, cf.name, "shape")) {
            if (@typeInfo(cf.type) == .@"union") return true;
        }
    }
    return false;
}

/// Build a Shape-like component from flattened format.
/// Flattened format: .{ .type = .rectangle, .width = 80, .height = 60, .color = ... }
/// The .type field determines the union variant, shape-specific fields (width, height, radius, etc.)
/// are used to construct the inner union, and remaining fields (color, etc.) are component fields.
pub fn buildFlattenedShapeComponent(comptime ComponentType: type, comptime data: anytype) ComponentType {
    const comp_fields = std.meta.fields(ComponentType);
    var result: ComponentType = undefined;

    // Find the 'shape' field (the union field)
    const shape_field_info = comptime blk: {
        for (comp_fields) |cf| {
            if (std.mem.eql(u8, cf.name, "shape")) {
                break :blk cf;
            }
        }
        @compileError("Component does not have a 'shape' field");
    };

    const ShapeUnionType = shape_field_info.type;
    const union_info = @typeInfo(ShapeUnionType).@"union";

    // Get the shape type from .type field
    const type_value = @field(data, "type");
    const type_name = @tagName(type_value);

    // Build the shape union
    inline for (union_info.fields) |union_field| {
        if (comptime std.mem.eql(u8, union_field.name, type_name)) {
            const inner_value = buildStructFromFlattenedData(union_field.type, data);
            result.shape = @unionInit(ShapeUnionType, type_name, inner_value);
        }
    }

    // Fill in the remaining component fields (color, rotation, z_index, etc.)
    inline for (comp_fields) |comp_field| {
        if (comptime std.mem.eql(u8, comp_field.name, "shape")) {
            // Already handled above
            continue;
        }

        if (@hasField(@TypeOf(data), comp_field.name)) {
            const data_value = @field(data, comp_field.name);
            @field(result, comp_field.name) = coerceValue(comp_field.type, data_value);
        } else if (comp_field.default_value_ptr) |ptr| {
            const default_ptr: *const comp_field.type = @ptrCast(@alignCast(ptr));
            @field(result, comp_field.name) = default_ptr.*;
        } else {
            @compileError("Missing required field '" ++ comp_field.name ++ "' for component");
        }
    }

    return result;
}

/// Build a struct from flattened data, using only fields that exist in the target struct.
/// Used to extract shape-specific fields (radius, width, height) from flattened format.
fn buildStructFromFlattenedData(comptime StructType: type, comptime data: anytype) StructType {
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
            @compileError("Missing required field '" ++ field.name ++ "' for flattened shape struct '" ++ @typeName(StructType) ++ "'");
        }
    }

    return result;
}
