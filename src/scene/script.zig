//! Script registry - maps script names to lifecycle functions for scene loading
//!
//! Scripts can implement any combination of these optional lifecycle hooks:
//! - init(game: *anyopaque, scene: *anyopaque) void    - Called when scene loads
//! - update(game: *anyopaque, scene: *anyopaque, dt: f32) void - Called every frame
//! - deinit(game: *anyopaque, scene: *anyopaque) void  - Called when scene unloads
//!
//! In script implementations, cast the pointers to your project's Game type:
//! ```zig
//! pub fn update(game_ptr: *anyopaque, scene_ptr: *anyopaque, dt: f32) void {
//!     // Cast to the Game type used in your main.zig (e.g., *Game or *GameWith(MyHooks))
//!     const game: *Game = @ptrCast(@alignCast(game_ptr));
//!     const scene: *Scene = @ptrCast(@alignCast(scene_ptr));
//!     // ... use game and scene
//! }
//! ```
//!
//! Usage:
//! const Scripts = engine.ScriptRegistry(struct {
//!     pub const gravity = @import("scripts/gravity.zig");
//!     pub const floating = @import("scripts/floating.zig");
//! });
//!
//! Then in scene .zon:
//! .{ .name = "demo", .scripts = .{ "gravity", "floating" }, .entities = ... }

const std = @import("std");

/// Script init function signature - called when scene loads
/// Parameters are opaque to avoid circular dependencies.
/// Cast to *Game and *Scene in implementations.
pub const InitFn = *const fn (*anyopaque, *anyopaque) void;

/// Script update function signature - called every frame
/// Parameters are opaque to avoid circular dependencies.
/// Cast to *Game and *Scene in implementations.
pub const UpdateFn = *const fn (*anyopaque, *anyopaque, f32) void;

/// Script deinit function signature - called when scene unloads
/// Parameters are opaque to avoid circular dependencies.
/// Cast to *Game and *Scene in implementations.
pub const DeinitFn = *const fn (*anyopaque, *anyopaque) void;

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

        /// Get script's update function by name
        pub fn getUpdateFn(comptime name: []const u8) UpdateFn {
            const script_module = @field(ScriptMap, name);
            return @ptrCast(&script_module.update);
        }

        /// Get all lifecycle functions for a script by name
        pub fn getScriptFns(comptime name: []const u8) ScriptFns {
            const script_module = @field(ScriptMap, name);
            // Scripts are imported as types, so check declarations on the type itself
            return .{
                .init = if (@hasDecl(script_module, "init")) @ptrCast(&script_module.init) else null,
                .update = if (@hasDecl(script_module, "update")) @ptrCast(&script_module.update) else null,
                .deinit = if (@hasDecl(script_module, "deinit")) @ptrCast(&script_module.deinit) else null,
            };
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
