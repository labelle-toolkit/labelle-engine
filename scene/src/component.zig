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
