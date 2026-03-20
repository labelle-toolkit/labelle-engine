// Component Registry — maps .zon field names to Zig types
//
// Ported from v1 scene/src/component.zig

/// Comptime component registry — maps .zon field names to Zig types.
///
/// Usage:
///   const Components = ComponentRegistry(.{
///       .Health = Health,
///       .Velocity = Velocity,
///   });
///
/// Built-in components (Position, Sprite, Shape) are handled automatically
/// by the scene loader and don't need to be registered here.
pub fn ComponentRegistry(comptime component_map: anytype) type {
    return struct {
        pub fn has(comptime name: []const u8) bool {
            return @hasField(@TypeOf(component_map), name);
        }

        pub fn getType(comptime name: []const u8) type {
            return @field(component_map, name);
        }

        pub fn names() []const []const u8 {
            comptime {
                const fields = @typeInfo(@TypeOf(component_map)).@"struct".fields;
                var result: [fields.len][]const u8 = undefined;
                for (fields, 0..) |f, i| {
                    result[i] = f.name;
                }
                return &result;
            }
        }

        pub fn entityHasNamed(ecs: anytype, entity: anytype, comptime name: []const u8) bool {
            const T = getType(name);
            return ecs.hasComponent(entity, T);
        }
    };
}

/// Multi-source component registry — searches multiple maps in order.
///
/// Usage:
///   const Components = ComponentRegistryMulti(.{
///       .{ .Health = Health, .Speed = Speed },
///       plugin_foo.Components,
///   });
pub fn ComponentRegistryMulti(comptime component_maps: anytype) type {
    const maps_info = @typeInfo(@TypeOf(component_maps));

    return struct {
        pub fn has(comptime name: []const u8) bool {
            inline for (maps_info.@"struct".fields) |field| {
                const Map = @field(component_maps, field.name);
                if (@hasField(@TypeOf(Map), name)) return true;
            }
            return false;
        }

        pub fn getType(comptime name: []const u8) type {
            inline for (maps_info.@"struct".fields) |field| {
                const Map = @field(component_maps, field.name);
                if (@hasField(@TypeOf(Map), name)) {
                    return @field(Map, name);
                }
            }
            @compileError("Unknown component: " ++ name);
        }
    };
}

/// Component registry with automatic plugin component discovery.
///
/// Game-local components (field-based struct) take precedence over plugin
/// components. Plugin modules are checked for a `Components` declaration
/// whose public declarations are registered automatically.
///
/// Usage:
///   const Components = ComponentRegistryWithPlugins(
///       .{ .Health = Health, .Velocity = Velocity },
///       .{ @import("pathfinding"), @import("labelle-gfx") },
///   );
pub fn ComponentRegistryWithPlugins(comptime local_map: anytype, comptime plugin_modules: anytype) type {
    const plugins_info = @typeInfo(@TypeOf(plugin_modules));

    return struct {
        pub fn has(comptime name: []const u8) bool {
            if (@hasField(@TypeOf(local_map), name)) return true;
            inline for (plugins_info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Components")) {
                    if (@hasDecl(@field(mod, "Components"), name)) return true;
                }
            }
            return false;
        }

        pub fn getType(comptime name: []const u8) type {
            if (@hasField(@TypeOf(local_map), name)) {
                return @field(local_map, name);
            }
            inline for (plugins_info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Components")) {
                    const Comps = @field(mod, "Components");
                    if (@hasDecl(Comps, name)) {
                        return @field(Comps, name);
                    }
                }
            }
            @compileError("Unknown component: " ++ name);
        }

        /// Returns a comptime slice of all registered component names.
        pub fn names() []const []const u8 {
            comptime {
                var count: usize = 0;

                // Count local components
                for (@typeInfo(@TypeOf(local_map)).@"struct".fields) |_| {
                    count += 1;
                }

                // Count plugin components (skip duplicates with local)
                for (plugins_info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Components")) {
                        const Comps = @field(mod, "Components");
                        for (@typeInfo(Comps).@"struct".decls) |decl| {
                            if (!@hasField(@TypeOf(local_map), decl.name)) {
                                count += 1;
                            }
                        }
                    }
                }

                var result: [count][]const u8 = undefined;
                var idx: usize = 0;

                for (@typeInfo(@TypeOf(local_map)).@"struct".fields) |f| {
                    result[idx] = f.name;
                    idx += 1;
                }

                for (plugins_info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Components")) {
                        const Comps = @field(mod, "Components");
                        for (@typeInfo(Comps).@"struct".decls) |decl| {
                            if (!@hasField(@TypeOf(local_map), decl.name)) {
                                result[idx] = decl.name;
                                idx += 1;
                            }
                        }
                    }
                }

                return &result;
            }
        }

        /// Check if an entity has a named component (runtime name, comptime dispatch).
        /// Returns true if the entity has the component matching the given name.
        pub fn entityHasNamed(ecs: anytype, entity: anytype, comptime name: []const u8) bool {
            const T = getType(name);
            return ecs.hasComponent(entity, T);
        }
    };
}
