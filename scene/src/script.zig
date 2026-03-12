// Script Registry — maps script names to lifecycle functions
//
// Ported from v1 scene/src/script.zig

// ============================================================
// Script types (opaque to avoid circular deps)
// ============================================================

pub const InitFn = *const fn (*anyopaque, *anyopaque) void;
pub const UpdateFn = *const fn (*anyopaque, *anyopaque, f32) void;
pub const DeinitFn = *const fn (*anyopaque, *anyopaque) void;

pub const ScriptFns = struct {
    init: ?InitFn = null,
    update: ?UpdateFn = null,
    deinit: ?DeinitFn = null,
};

/// Comptime script registry — maps script names to lifecycle functions.
///
/// Usage:
///   const Scripts = ScriptRegistry(struct {
///       pub const gravity = @import("scripts/gravity.zig");
///       pub const floating = @import("scripts/floating.zig");
///   });
///
/// Script modules implement optional lifecycle hooks:
///   pub fn init(game_ptr: *anyopaque, scene_ptr: *anyopaque) void { ... }
///   pub fn update(game_ptr: *anyopaque, scene_ptr: *anyopaque, dt: f32) void { ... }
///   pub fn deinit(game_ptr: *anyopaque, scene_ptr: *anyopaque) void { ... }
pub fn ScriptRegistry(comptime ScriptMap: type) type {
    return struct {
        pub fn has(comptime name: []const u8) bool {
            return @hasDecl(ScriptMap, name);
        }

        pub fn getScriptFns(comptime name: []const u8) ScriptFns {
            const script_module = @field(ScriptMap, name);
            return .{
                .init = if (@hasDecl(script_module, "init")) @ptrCast(&script_module.init) else null,
                .update = if (@hasDecl(script_module, "update")) @ptrCast(&script_module.update) else null,
                .deinit = if (@hasDecl(script_module, "deinit")) @ptrCast(&script_module.deinit) else null,
            };
        }

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

/// Empty script registry for when no scripts are defined.
pub const NoScripts = ScriptRegistry(struct {});
