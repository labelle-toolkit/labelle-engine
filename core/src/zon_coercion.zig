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

    // Handle tagged union coercion from anonymous struct
    // Example: .{ .box = .{ .width = 50, .height = 50 } } -> Shape union
    if (field_info == .@"union") {
        return coerceToUnion(FieldType, data_value);
    }

    // Handle nested struct coercion
    if (field_info == .@"struct" and @typeInfo(DataType) == .@"struct") {
        return buildStruct(FieldType, data_value);
    }

    // Direct assignment for compatible types
    return data_value;
}

/// Coerce a comptime value to a tagged union type.
/// Supports:
/// - Single-field anonymous struct: .{ .box = .{ .width = 50 } } -> Union.box
/// - Enum literal for void payloads: .idle -> State.idle
fn coerceToUnion(comptime UnionType: type, comptime data_value: anytype) UnionType {
    const DataType = @TypeOf(data_value);
    const data_info = @typeInfo(DataType);
    const union_info = @typeInfo(UnionType).@"union";

    // Case 1: Enum literal for void payload variants
    // Example: .idle -> State.idle (where State = union(enum) { idle, running, ... })
    if (data_info == .enum_literal) {
        const tag_name = @tagName(data_value);

        inline for (union_info.fields) |union_field| {
            if (comptime std.mem.eql(u8, union_field.name, tag_name)) {
                // Verify the payload is void
                if (union_field.type != void) {
                    @compileError("Cannot use enum literal for union variant '" ++ tag_name ++
                        "' with non-void payload. Use .{ ." ++ tag_name ++ " = ... } syntax instead.");
                }
                return @unionInit(UnionType, tag_name, {});
            }
        }
        @compileError("No union variant named '" ++ tag_name ++ "' in " ++ @typeName(UnionType));
    }

    // Case 2: Single-field anonymous struct maps to union variant
    // Example: .{ .box = .{ .width = 50, .height = 50 } } -> Shape.box
    if (data_info == .@"struct") {
        const data_fields = data_info.@"struct".fields;

        if (data_fields.len != 1) {
            @compileError("Expected single-field struct for union coercion, got " ++
                std.fmt.comptimePrint("{d}", .{data_fields.len}) ++ " fields. " ++
                "Use .{ .variant_name = payload } syntax for " ++ @typeName(UnionType));
        }

        const variant_name = data_fields[0].name;
        const variant_value = @field(data_value, variant_name);

        // Find matching union variant
        inline for (union_info.fields) |union_field| {
            if (comptime std.mem.eql(u8, union_field.name, variant_name)) {
                // Recursively coerce the payload
                const coerced_payload = coerceValue(union_field.type, variant_value);
                return @unionInit(UnionType, variant_name, coerced_payload);
            }
        }

        @compileError("No union variant named '" ++ variant_name ++ "' in " ++ @typeName(UnionType) ++
            ". Available variants: " ++ unionVariantNames(union_info));
    }

    // Case 3: Direct assignment if types match
    if (DataType == UnionType) {
        return data_value;
    }

    @compileError("Cannot coerce " ++ @typeName(DataType) ++ " to union type " ++ @typeName(UnionType) ++
        ". Use .{ .variant_name = payload } or .variant_name (for void payloads).");
}

/// Helper to format union variant names for error messages
/// Uses pre-calculated buffer size to avoid O(n^2) string concatenation
fn unionVariantNames(comptime union_info: std.builtin.Type.Union) []const u8 {
    comptime {
        if (union_info.fields.len == 0) {
            return "";
        }

        // Calculate total buffer size needed
        var total_len: usize = 0;
        // Account for ", " between names (n-1 separators)
        if (union_info.fields.len > 1) {
            total_len += (union_info.fields.len - 1) * 2;
        }
        // Account for "." prefix and field name for each field
        for (union_info.fields) |field| {
            total_len += 1 + field.name.len;
        }

        // Build the string in a fixed buffer
        var buf: [total_len]u8 = undefined;
        var pos: usize = 0;

        for (union_info.fields, 0..) |field, i| {
            if (i > 0) {
                buf[pos] = ',';
                buf[pos + 1] = ' ';
                pos += 2;
            }
            buf[pos] = '.';
            pos += 1;
            for (field.name) |c| {
                buf[pos] = c;
                pos += 1;
            }
        }

        return &buf;
    }
}

/// Build a struct from comptime anonymous struct data.
/// Recursively coerces nested fields.
/// Raises compile error for missing required fields (fields without defaults).
pub fn buildStruct(comptime StructType: type, comptime data: anytype) StructType {
    return buildStructWithContext(StructType, data, "struct");
}

/// Build a struct with a custom context string for error messages.
fn buildStructWithContext(comptime StructType: type, comptime data: anytype, comptime context: []const u8) StructType {
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
            @compileError("Missing required field '" ++ field.name ++ "' for " ++ context ++ " '" ++ @typeName(StructType) ++ "'");
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

    // Use a comptime block to build the array, then store it as const
    // This ensures proper comptime array semantics
    const array = comptime blk: {
        var arr: [len]ChildType = undefined;
        for (0..len) |i| {
            arr[i] = coerceValue(ChildType, tuple[i]);
        }
        break :blk arr;
    };

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
    if (!@hasField(@TypeOf(data), "type")) return false;

    inline for (std.meta.fields(ComponentType)) |field| {
        if (comptime std.mem.eql(u8, field.name, "shape")) {
            return @typeInfo(field.type) == .@"union";
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
    comptime var found_match = false;
    inline for (union_info.fields) |union_field| {
        if (comptime std.mem.eql(u8, union_field.name, type_name)) {
            found_match = true;
            const inner_value = buildStructWithContext(union_field.type, data, "flattened shape");
            result.shape = @unionInit(ShapeUnionType, type_name, inner_value);
        }
    }

    if (!found_match) {
        @compileError("Unknown shape type '" ++ type_name ++ "' in flattened shape component");
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
