// Script registry - maps script names to lifecycle functions for scene loading
//
// Scripts can implement any combination of these optional lifecycle hooks:
// - init(game: *Game, scene: *Scene) void    - Called when scene loads
// - update(game: *Game, scene: *Scene, dt: f32) void - Called every frame
// - deinit(game: *Game, scene: *Scene) void  - Called when scene unloads
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

/// Script init function signature - called when scene loads
pub const InitFn = *const fn (*Game, *Scene) void;

/// Script update function signature - called every frame
/// Scripts receive Game (for ECS/rendering access) and Scene (for scene-specific data)
pub const UpdateFn = *const fn (*Game, *Scene, f32) void;

/// Script deinit function signature - called when scene unloads
pub const DeinitFn = *const fn (*Game, *Scene) void;

/// Bundle of script lifecycle functions
pub const ScriptFns = struct {
    init: ?InitFn = null,
    update: ?UpdateFn = null,
    deinit: ?DeinitFn = null,
};

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

        /// Get script's update function by name (for backwards compatibility)
        pub fn getUpdateFn(comptime name: []const u8) UpdateFn {
            const script_module = @field(ScriptMap, name);
            return script_module.update;
        }

        /// Get all lifecycle functions for a script by name
        pub fn getScriptFns(comptime name: []const u8) ScriptFns {
            const script_module = @field(ScriptMap, name);
            // Scripts are imported as types, so check declarations on the type itself
            return .{
                .init = if (@hasDecl(script_module, "init")) script_module.init else null,
                .update = if (@hasDecl(script_module, "update")) script_module.update else null,
                .deinit = if (@hasDecl(script_module, "deinit")) script_module.deinit else null,
            };
        }

        /// Get all update functions for a list of script names (backwards compatibility)
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

        /// Get all script function bundles for a list of script names
        pub fn getScriptFnsList(comptime script_names: anytype) []const ScriptFns {
            comptime {
                var fns: [script_names.len]ScriptFns = undefined;
                for (script_names, 0..) |name, i| {
                    if (!has(name)) {
                        @compileError("Unknown script: " ++ name);
                    }
                    fns[i] = getScriptFns(name);
                }
                const result = fns;
                return &result;
            }
        }
    };
}

