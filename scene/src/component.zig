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
const zon = @import("../../core/src/zon_coercion.zig");

pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

/// Create a component registry from multiple struct types.
/// Searches all provided maps when looking up components.
///
/// Usage:
/// ```
/// const Components = ComponentRegistryMulti(.{
///     struct { pub const Position = engine.Position; },
///     plugin_foo.Components,
///     plugin_bar.Components,
/// });
/// ```
pub fn ComponentRegistryMulti(comptime ComponentMaps: anytype) type {
    const maps_info = @typeInfo(@TypeOf(ComponentMaps));
    if (maps_info != .@"struct" or !maps_info.@"struct".is_tuple) {
        @compileError("ComponentRegistryMulti expects a tuple of struct types");
    }

    return struct {
        const Self = @This();

        /// Check if a component name exists in any of the maps
        pub fn has(comptime name: []const u8) bool {
            inline for (maps_info.@"struct".fields) |field| {
                const Map = @field(ComponentMaps, field.name);
                if (@hasDecl(Map, name)) return true;
            }
            return false;
        }

        /// Get component type by name (searches maps in order)
        pub fn getType(comptime name: []const u8) type {
            inline for (maps_info.@"struct".fields) |field| {
                const Map = @field(ComponentMaps, field.name);
                if (@hasDecl(Map, name)) {
                    return @field(Map, name);
                }
            }
            @compileError("Unknown component: " ++ name);
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
            return comptime zon.buildStruct(ComponentType, data);
        }

        /// Add all components from a .zon components struct to an entity
        pub fn addComponents(
            registry: *Registry,
            entity: Entity,
            comptime components_data: anytype,
        ) void {
            comptime var i: usize = 0;
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline while (i < data_fields.len) : (i += 1) {
                const field_name = data_fields[i];
                const field_data = @field(components_data, field_name);
                addComponent(registry, entity, field_name, field_data);
            }
        }

        /// Register component lifecycle callbacks for all component types declared in the maps.
        ///
        /// This calls `ecs.registerComponentCallbacks()` for each component type, which
        /// will wire `onAdd`/`onRemove` hooks (and enable `onSet` via `setComponent()`).
        ///
        /// For overlapping component names, only the first map (in tuple order) wins.
        pub fn registerCallbacks(registry: *Registry) void {
            inline for (maps_info.@"struct".fields, 0..) |field, map_idx| {
                const Map = @field(ComponentMaps, field.name);
                inline for (std.meta.declarations(Map)) |decl| {
                    const decl_val = @field(Map, decl.name);
                    if (@TypeOf(decl_val) != type) continue;

                    // Respect lookup semantics: if an earlier map declares the same name,
                    // skip this one to avoid duplicate registration.
                    comptime var shadowed = false;
                    inline for (0..map_idx) |prev_idx| {
                        const PrevMap = @field(ComponentMaps, maps_info.@"struct".fields[prev_idx].name);
                        if (@hasDecl(PrevMap, decl.name)) {
                            shadowed = true;
                            break;
                        }
                    }
                    if (shadowed) continue;

                    ecs.registerComponentCallbacks(registry, decl_val);
                }
            }
        }
    };
}

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
            return comptime zon.buildStruct(ComponentType, data);
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

        /// Register component lifecycle callbacks for all component types declared in this map.
        ///
        /// This calls `ecs.registerComponentCallbacks()` for each component type, which
        /// will wire `onAdd`/`onRemove` hooks (and enable `onSet` via `setComponent()`).
        pub fn registerCallbacks(registry: *Registry) void {
            inline for (names) |decl| {
                const decl_val = @field(ComponentMap, decl.name);
                if (@TypeOf(decl_val) != type) continue;
                ecs.registerComponentCallbacks(registry, decl_val);
            }
        }
    };
}

