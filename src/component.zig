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
                    @field(result, field.name) = @field(data, field.name);
                } else if (field.default_value_ptr) |ptr| {
                    const default_ptr: *const field.type = @ptrCast(@alignCast(ptr));
                    @field(result, field.name) = default_ptr.*;
                } else {
                    @field(result, field.name) = std.mem.zeroes(field.type);
                }
            }

            return result;
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

