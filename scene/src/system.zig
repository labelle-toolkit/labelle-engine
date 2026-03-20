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
        const std_time = @import("std").time;
        const builtin = @import("builtin");
        pub const profiling_enabled = builtin.mode == .Debug;

        /// Plugin system profiling entry.
        pub const PluginProfileEntry = struct {
            name: []const u8,
            tick_ns: u64 = 0,
            post_tick_ns: u64 = 0,
            draw_gui_ns: u64 = 0,
        };

        pub const plugin_system_count: usize = countPluginSystems();

        fn countPluginSystems() usize {
            comptime {
                var count: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Systems")) count += 1;
                }
                return count;
            }
        }

        /// Per-plugin timing data (updated each frame).
        pub var plugin_profile: [plugin_system_count]PluginProfileEntry = initPluginProfile();

        fn initPluginProfile() [plugin_system_count]PluginProfileEntry {
            comptime {
                var entries: [plugin_system_count]PluginProfileEntry = undefined;
                var idx: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Systems")) {
                        entries[idx] = .{ .name = field.name };
                        idx += 1;
                    }
                }
                return entries;
            }
        }

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
        pub fn tick(game: anytype, dt: f32) void {
            comptime var pidx: usize = 0;
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "tick")) {
                        var timer = std_time.Timer.start() catch null;
                        Sys.tick(game, dt);
                        if (timer) |*t| plugin_profile[pidx].tick_ns = t.read();
                    }
                    pidx += 1;
                }
            }
        }

        /// Call postTick() on all plugin systems that declare it.
        pub fn postTick(game: anytype, dt: f32) void {
            comptime var pidx: usize = 0;
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "postTick")) {
                        var timer = std_time.Timer.start() catch null;
                        Sys.postTick(game, dt);
                        if (timer) |*t| plugin_profile[pidx].post_tick_ns = t.read();
                    }
                    pidx += 1;
                }
            }
        }

        /// Call drawGui() on all plugin systems that declare it.
        pub fn drawGui(game: anytype) void {
            comptime var pidx: usize = 0;
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "drawGui")) {
                        var timer = std_time.Timer.start() catch null;
                        Sys.drawGui(game);
                        if (timer) |*t| plugin_profile[pidx].draw_gui_ns = t.read();
                    }
                    pidx += 1;
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

        /// Gizmo category entry — name + index, discovered from plugins.
        pub const GizmoCategoryEntry = struct {
            name: []const u8,
            id: u8,
        };

        /// Number of gizmo categories across all plugins.
        pub const gizmo_category_count: usize = countGizmoCategories();

        fn countGizmoCategories() usize {
            comptime {
                var count: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "GizmoCategories")) {
                        for (@typeInfo(@field(mod, "GizmoCategories")).@"struct".decls) |_| {
                            count += 1;
                        }
                    }
                }
                return count;
            }
        }

        /// Collect all gizmo categories from plugins that export GizmoCategories.
        pub fn gizmoCategories() [gizmo_category_count]GizmoCategoryEntry {
            comptime {
                var entries: [gizmo_category_count]GizmoCategoryEntry = undefined;
                var idx: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "GizmoCategories")) {
                        const Cats = @field(mod, "GizmoCategories");
                        for (@typeInfo(Cats).@"struct".decls) |decl| {
                            entries[idx] = .{
                                .name = decl.name,
                                .id = @field(Cats, decl.name),
                            };
                            idx += 1;
                        }
                    }
                }
                return entries;
            }
        }
    };
}
