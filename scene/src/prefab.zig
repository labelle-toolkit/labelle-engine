// Prefab Registry — comptime prefab lookup
//
// Ported from v1 scene/src/prefab.zig

/// Comptime prefab registry — maps names to .zon prefab data.
///
/// Usage:
///   const Prefabs = PrefabRegistry(.{
///       .player = @import("prefabs/player.zon"),
///       .enemy = @import("prefabs/enemy.zon"),
///   });
pub fn PrefabRegistry(comptime prefab_map: anytype) type {
    return struct {
        const PrefabMap = @TypeOf(prefab_map);

        pub fn has(comptime name: anytype) bool {
            const name_str: []const u8 = name;
            return @hasField(PrefabMap, name_str);
        }

        pub fn get(comptime name: []const u8) @TypeOf(@field(prefab_map, name)) {
            return @field(prefab_map, name);
        }

        pub fn hasComponents(comptime name: []const u8) bool {
            const data = get(name);
            return @hasField(@TypeOf(data), "components");
        }

        pub fn getComponents(comptime name: []const u8) @TypeOf(@field(get(name), "components")) {
            return get(name).components;
        }

        pub fn hasChildren(comptime name: []const u8) bool {
            const data = get(name);
            return @hasField(@TypeOf(data), "children");
        }

        pub fn getChildren(comptime name: []const u8) @TypeOf(@field(get(name), "children")) {
            return get(name).children;
        }
    };
}
