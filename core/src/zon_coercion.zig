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

    // Handle optional types - unwrap and coerce the child type
    if (field_info == .optional) {
        const ChildType = field_info.optional.child;
        // Check for null
        if (DataType == @TypeOf(null)) {
            return null;
        }
        // Coerce to the child type and wrap in optional
        return coerceValue(ChildType, data_value);
    }

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
/// - Payload-matching struct: .{ .width = 50, .height = 50 } -> Container.explicit (if fields match)
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

    // Case 2: Anonymous struct - could be variant selector or direct payload
    if (data_info == .@"struct") {
        const data_fields = data_info.@"struct".fields;

        // Case 2a: Single-field struct where field name matches a union variant
        // Example: .{ .box = .{ .width = 50, .height = 50 } } -> Shape.box
        if (data_fields.len == 1) {
            const field_name = data_fields[0].name;

            // Check if this field name matches a union variant
            inline for (union_info.fields) |union_field| {
                if (comptime std.mem.eql(u8, union_field.name, field_name)) {
                    // This is the variant selector pattern
                    const variant_value = @field(data_value, field_name);
                    const coerced_payload = coerceValue(union_field.type, variant_value);
                    return @unionInit(UnionType, field_name, coerced_payload);
                }
            }
        }

        // Case 2b: Multi-field struct that matches a union variant's payload type
        // Example: .{ .width = 400, .height = 300 } -> Container.explicit
        // Find a union variant whose payload struct has compatible fields.
        // Note: If multiple variants have compatible payload types, the first one
        // in declaration order will be selected. Use explicit variant syntax
        // (.{ .variant_name = payload }) to avoid ambiguity.
        inline for (union_info.fields) |union_field| {
            const payload_info = @typeInfo(union_field.type);
            if (payload_info == .@"struct") {
                // Check if data fields are compatible with this payload struct
                if (comptime structFieldsCompatible(DataType, union_field.type)) {
                    const coerced_payload = buildStruct(union_field.type, data_value);
                    return @unionInit(UnionType, union_field.name, coerced_payload);
                }
            }
        }

        @compileError("Cannot coerce struct to union type " ++ @typeName(UnionType) ++
            ". Use .{ .variant_name = payload } syntax or ensure struct fields match a variant's payload.");
    }

    // Case 3: Direct assignment if types match
    if (DataType == UnionType) {
        return data_value;
    }

    @compileError("Cannot coerce " ++ @typeName(DataType) ++ " to union type " ++ @typeName(UnionType) ++
        ". Use .{ .variant_name = payload } or .variant_name (for void payloads).");
}

/// Check if all fields in DataType exist in TargetType (for struct compatibility)
fn structFieldsCompatible(comptime DataType: type, comptime TargetType: type) bool {
    const data_fields = @typeInfo(DataType).@"struct".fields;
    const target_fields = @typeInfo(TargetType).@"struct".fields;

    // All data fields must exist in target
    for (data_fields) |df| {
        var found = false;
        for (target_fields) |tf| {
            if (std.mem.eql(u8, df.name, tf.name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    // Target must have at least some required fields from data, or all fields must have defaults
    // For now, just check that we have at least one matching field
    return data_fields.len > 0;
}

/// Helper to format union variant names for error messages
fn unionVariantNames(comptime union_info: std.builtin.Type.Union) []const u8 {
    comptime {
        if (union_info.fields.len == 0) {
            return "";
        }

        var result: []const u8 = "";
        for (union_info.fields, 0..) |field, i| {
            if (i > 0) {
                result = result ++ ", ";
            }
            result = result ++ "." ++ field.name;
        }
        return result;
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

/// Merge two comptime structs, with overrides taking precedence.
/// Returns a new anonymous struct with all fields from base, plus any
/// fields from overrides (which override base values).
///
/// Used for prefab + scene component merging:
///   const merged = mergeStructs(prefab_component, scene_override);
///
/// Example:
///   base = .{ .x = 10, .y = 20, .color = .red }
///   overrides = .{ .color = .blue }
///   result = .{ .x = 10, .y = 20, .color = .blue }
pub fn mergeStructs(comptime base: anytype, comptime overrides: anytype) MergedStructType(@TypeOf(base), @TypeOf(overrides)) {
    const BaseType = @TypeOf(base);
    const OverridesType = @TypeOf(overrides);

    var result: MergedStructType(BaseType, OverridesType) = undefined;

    // Copy all fields from base
    inline for (std.meta.fields(BaseType)) |field| {
        if (@hasField(OverridesType, field.name)) {
            // Override takes precedence
            @field(result, field.name) = @field(overrides, field.name);
        } else {
            @field(result, field.name) = @field(base, field.name);
        }
    }

    // Add fields that exist only in overrides (not in base)
    inline for (std.meta.fields(OverridesType)) |field| {
        if (!@hasField(BaseType, field.name)) {
            @field(result, field.name) = @field(overrides, field.name);
        }
    }

    return result;
}

/// Compute the merged struct type from two struct types.
/// The result type has all fields from both, with overrides type taking
/// precedence for field types when names conflict.
fn MergedStructType(comptime BaseType: type, comptime OverridesType: type) type {
    const base_fields = std.meta.fields(BaseType);
    const override_fields = std.meta.fields(OverridesType);

    // Count total unique fields
    comptime var field_count = base_fields.len;
    inline for (override_fields) |of| {
        if (!@hasField(BaseType, of.name)) {
            field_count += 1;
        }
    }

    // Build the fields array
    comptime var fields: [field_count]std.builtin.Type.StructField = undefined;
    comptime var i = 0;

    // Add base fields (with override type if overridden)
    inline for (base_fields) |bf| {
        // Check if this field is overridden
        if (@hasField(OverridesType, bf.name)) {
            // Find the override field to get its type
            inline for (override_fields) |of| {
                if (comptime std.mem.eql(u8, of.name, bf.name)) {
                    fields[i] = .{
                        .name = bf.name,
                        .type = of.type,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(of.type),
                    };
                }
            }
        } else {
            fields[i] = .{
                .name = bf.name,
                .type = bf.type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(bf.type),
            };
        }
        i += 1;
    }

    // Add override-only fields
    inline for (override_fields) |of| {
        if (!@hasField(BaseType, of.name)) {
            fields[i] = .{
                .name = of.name,
                .type = of.type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(of.type),
            };
            i += 1;
        }
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Check if a struct type has any fields
pub fn hasFields(comptime T: type) bool {
    return std.meta.fields(T).len > 0;
}

// ============================================
// ENTITY REFERENCES (Issue #242)
// ============================================

/// Reference info extracted from comptime ZON data
pub const RefInfo = struct {
    /// Name of the referenced entity (null for self-reference)
    entity_name: ?[]const u8,
    /// Whether this is a self-reference (.ref = .self)
    is_self: bool,
};

/// Check if a comptime value is a reference marker.
/// References use the syntax: .{ .ref = .{ .entity = "name" } } or .{ .ref = .self }
pub fn isReference(comptime value: anytype) bool {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .@"struct") return false;
    return @hasField(T, "ref");
}

/// Extract reference info from a comptime value.
/// Returns null if the value is not a reference.
pub fn extractRefInfo(comptime value: anytype) ?RefInfo {
    if (!isReference(value)) return null;

    const ref_data = value.ref;
    const RefType = @TypeOf(ref_data);

    // Check for self-reference: .{ .ref = .self }
    if (@typeInfo(RefType) == .enum_literal) {
        const tag_name = @tagName(ref_data);
        if (std.mem.eql(u8, tag_name, "self")) {
            return RefInfo{
                .entity_name = null,
                .is_self = true,
            };
        }
        @compileError("Invalid reference: .ref = ." ++ tag_name ++ ". Use .ref = .self or .ref = .{ .entity = \"name\" }");
    }

    // Check for entity reference: .{ .ref = .{ .entity = "name" } }
    if (@typeInfo(RefType) == .@"struct") {
        if (@hasField(RefType, "entity")) {
            return RefInfo{
                .entity_name = ref_data.entity,
                .is_self = false,
            };
        }
    }

    @compileError("Invalid reference format. Use .ref = .self or .ref = .{ .entity = \"name\" }");
}

/// Check if any field in a comptime struct contains a reference
pub fn hasAnyReference(comptime value: anytype) bool {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .@"struct") return false;

    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const field_value = @field(value, field.name);
        if (isReference(field_value)) return true;
    }
    return false;
}

/// Get all reference field names from a comptime struct
pub fn getReferenceFieldNames(comptime value: anytype) []const []const u8 {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .@"struct") return &.{};

    const fields = @typeInfo(T).@"struct".fields;
    comptime var count: usize = 0;

    // Count reference fields
    inline for (fields) |field| {
        const field_value = @field(value, field.name);
        if (isReference(field_value)) count += 1;
    }

    if (count == 0) return &.{};

    // Collect reference field names
    comptime var names: [count][]const u8 = undefined;
    comptime var i: usize = 0;

    inline for (fields) |field| {
        const field_value = @field(value, field.name);
        if (isReference(field_value)) {
            names[i] = field.name;
            i += 1;
        }
    }

    const final = names;
    return &final;
}
