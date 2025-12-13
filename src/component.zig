// Component registry - maps component names to types for scene loading
//
// Usage:
// const Components = engine.ComponentRegistry(struct {
//     pub const Gravity = components.Gravity;
//     pub const Speed = components.Speed;
// });
//
// Then in scene .zon:
// .{ .sprite = .{ .name = "cloud.png" }, .components = .{ .Gravity = .{ .strength = 9.8 } } }

const std = @import("std");
const ecs = @import("ecs");

pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

/// Create a component registry from a struct type with component type declarations
/// The struct's pub const declarations become the component names in .zon files
pub fn ComponentRegistry(comptime ComponentMap: type) type {
    return struct {
        const Self = @This();

        /// Get the list of component declaration names
        pub const names = std.meta.declarations(ComponentMap);

        /// Check if a component name exists
        pub fn has(comptime name: []const u8) bool {
            return @hasDecl(ComponentMap, name);
        }

        /// Get component type by name
        pub fn getType(comptime name: []const u8) type {
            return @field(ComponentMap, name);
        }

        /// Add a component to an entity by name using comptime data
        pub fn addComponent(
            registry: *Registry,
            entity: Entity,
            comptime name: []const u8,
            comptime data: anytype,
        ) void {
            const ComponentType = getType(name);
            const component_value = createComponentFromData(ComponentType, data);
            registry.add(entity, component_value);
        }

        /// Create a component value from .zon data by direct field initialization
        fn createComponentFromData(comptime ComponentType: type, comptime data: anytype) ComponentType {
            // Build the component using comptime field access
            return comptime buildComponent(ComponentType, data);
        }

        fn buildComponent(comptime ComponentType: type, comptime data: anytype) ComponentType {
            const fields = std.meta.fields(ComponentType);
            var result: ComponentType = undefined;

            inline for (fields) |field| {
                if (@hasField(@TypeOf(data), field.name)) {
                    const data_value = @field(data, field.name);
                    @field(result, field.name) = coerceValue(field.type, data_value);
                } else if (field.default_value_ptr) |ptr| {
                    const default_ptr: *const field.type = @ptrCast(@alignCast(ptr));
                    @field(result, field.name) = default_ptr.*;
                } else {
                    @field(result, field.name) = std.mem.zeroes(field.type);
                }
            }

            return result;
        }

        /// Coerce a ZON value to the expected field type
        /// Handles tuple-to-slice conversion for array fields
        fn coerceValue(comptime FieldType: type, comptime data_value: anytype) FieldType {
            const DataType = @TypeOf(data_value);
            const field_info = @typeInfo(FieldType);

            // Check if field is a slice and data is a tuple
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

            // Check if field is a struct and data is an anonymous struct (nested component)
            if (field_info == .@"struct" and @typeInfo(DataType) == .@"struct") {
                return buildComponent(FieldType, data_value);
            }

            // Direct assignment for compatible types
            return data_value;
        }

        /// Convert a tuple to a slice at comptime
        fn tupleToSlice(comptime ChildType: type, comptime tuple: anytype) []const ChildType {
            const tuple_info = @typeInfo(@TypeOf(tuple)).@"struct";
            const len = tuple_info.fields.len;

            // Build array from tuple elements
            var array: [len]ChildType = undefined;
            inline for (0..len) |i| {
                // Recursively coerce each element (handles nested structs)
                array[i] = coerceValue(ChildType, tuple[i]);
            }

            // Return pointer to comptime array as slice
            const final = array;
            return &final;
        }

        /// Add all components from a .zon components struct to an entity
        pub fn addComponents(
            registry: *Registry,
            entity: Entity,
            comptime components_data: anytype,
        ) void {
            // Use comptime block to iterate over fields
            comptime var i: usize = 0;
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline while (i < data_fields.len) : (i += 1) {
                const field_name = data_fields[i];
                const field_data = @field(components_data, field_name);
                // This will error at comptime if field_name doesn't exist in ComponentMap
                addComponent(registry, entity, field_name, field_data);
            }
        }
    };
}

