/// SystemRegistry — auto-discovers and dispatches plugin systems at comptime.
///
/// Mirrors ComponentRegistryWithPlugins: plugins export `pub const Systems`
/// with lifecycle functions that the engine calls at the right phase.
///
/// Plugin system convention:
///   pub const Systems = struct {
///       pub fn setup(game: anytype) void { ... }
///       pub fn tick(game: anytype, dt: f32) void { ... }
///       pub fn postTick(game: anytype, dt: f32) void { ... }
///       pub fn drawGui(game: anytype) void { ... }
///       pub fn deinit() void { ... }
///   };
///
/// All functions are optional — only declare what you need.
///
/// Usage (in generated main.zig):
///   const PluginSystems = engine.SystemRegistry(.{
///       @import("box2d"),
///       @import("labelle-gfx"),
///   });
///   // In setup:  PluginSystems.setup(&g);
///   // In tick:   PluginSystems.tick(&g, dt);
///   // In render: PluginSystems.drawGui(&g);

pub fn SystemRegistry(comptime plugin_modules: anytype) type {
    const info = @typeInfo(@TypeOf(plugin_modules));

    return struct {
        /// Call setup() on all plugin systems that declare it.
        pub fn setup(game: anytype) void {
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "setup")) {
                        Sys.setup(game);
                    }
                }
            }
        }

        /// Call tick() on all plugin systems that declare it.
        /// Runs after the game's own scripts tick.
        pub fn tick(game: anytype, dt: f32) void {
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "tick")) {
                        Sys.tick(game, dt);
                    }
                }
            }
        }

        /// Call postTick() on all plugin systems that declare it.
        /// Runs after tick — useful for physics position writeback.
        pub fn postTick(game: anytype, dt: f32) void {
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "postTick")) {
                        Sys.postTick(game, dt);
                    }
                }
            }
        }

        /// Call drawGui() on all plugin systems that declare it.
        pub fn drawGui(game: anytype) void {
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "drawGui")) {
                        Sys.drawGui(game);
                    }
                }
            }
        }

        /// Call deinit() on all plugin systems in reverse order (mirrors setup).
        pub fn deinit() void {
            const fields = info.@"struct".fields;
            comptime var i: usize = fields.len;
            inline while (i > 0) {
                i -= 1;
                const mod = @field(plugin_modules, fields[i].name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "deinit")) {
                        Sys.deinit();
                    }
                }
            }
        }

        /// Returns true if any plugin module exports a Systems declaration.
        pub fn hasSystems() bool {
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) return true;
            }
            return false;
        }
    };
}
