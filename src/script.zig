// Script registry - maps script names to update functions for scene loading
//
// Usage:
// const Scripts = engine.ScriptRegistry(struct {
//     pub const gravity = @import("scripts/gravity.zig");
//     pub const floating = @import("scripts/floating.zig");
// });
//
// Then in scene .zon:
// .{ .name = "demo", .scripts = .{ "gravity", "floating" }, .entities = ... }

const std = @import("std");
const game_mod = @import("game.zig");
const scene_mod = @import("scene.zig");

pub const Game = game_mod.Game;
pub const Scene = scene_mod.Scene;

/// Script update function signature
/// Scripts receive Game (for ECS/rendering access) and Scene (for scene-specific data)
pub const UpdateFn = *const fn (*Game, *Scene, f32) void;

/// Create a script registry from a struct type with script imports
pub fn ScriptRegistry(comptime ScriptMap: type) type {
    return struct {
        const Self = @This();

        /// Get the list of script names
        pub const names = std.meta.declarations(ScriptMap);

        /// Check if a script name exists
        pub fn has(comptime name: []const u8) bool {
            return @hasDecl(ScriptMap, name);
        }

        /// Get script's update function by name
        pub fn getUpdateFn(comptime name: []const u8) UpdateFn {
            const script = @field(ScriptMap, name);
            return script.update;
        }

        /// Get all update functions for a list of script names
        pub fn getUpdateFns(comptime script_names: anytype) []const UpdateFn {
            comptime {
                var fns: [script_names.len]UpdateFn = undefined;
                for (script_names, 0..) |name, i| {
                    if (!has(name)) {
                        @compileError("Unknown script: " ++ name);
                    }
                    fns[i] = getUpdateFn(name);
                }
                const result = fns;
                return &result;
            }
        }
    };
}

