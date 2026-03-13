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
            // Local components take precedence
            if (@hasField(@TypeOf(local_map), name)) return true;
            // Check plugin Components declarations
            inline for (plugins_info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Components")) {
                    if (@hasDecl(@field(mod, "Components"), name)) return true;
                }
            }
            return false;
        }

        pub fn getType(comptime name: []const u8) type {
            // Local components take precedence
            if (@hasField(@TypeOf(local_map), name)) {
                return @field(local_map, name);
            }
            // Check plugin Components declarations
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
    };
}
