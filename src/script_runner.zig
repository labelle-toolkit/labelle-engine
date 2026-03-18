/// ScriptRunner — comptime-driven script lifecycle dispatcher.
///
/// Replaces the generator's string-scanning approach with comptime @hasDecl
/// detection. Scripts declare their capabilities through exports:
///
///   Tier 1 (stateless):     pub fn tick(g: anytype, dt: f32)
///   Tier 2 (context only):  pub fn tick(g: anytype, ctx: anytype, dt: f32)
///   Tier 3 (state+context): pub fn tick(g: anytype, state: *State, ctx: anytype, dt: f32)
///
/// Per-script state is detected via `pub const State` or `pub fn State(EcsBackend) type`.
/// Context is shared across all scripts.
///
/// Scene scripts (init/update/deinit with opaque ptrs) are not processed here —
/// they go through ScriptRegistry and SceneLoader as before.
const std = @import("std");

pub fn ScriptRunner(
    comptime AllScripts: type,
    comptime CtxType: type,
    comptime EcsBackend: type,
) type {
    return struct {
        const Self = @This();

        states: States,
        ctx: CtxType,
        allocator: std.mem.Allocator,

        /// Comptime-built struct with one field per script that exports State.
        const States = buildStatesType();

        fn buildStatesType() type {
            const decls = @typeInfo(AllScripts).@"struct".decls;
            var fields: [decls.len]std.builtin.Type.StructField = undefined;
            var count: usize = 0;
            for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime isGameScript(mod) and @hasDecl(mod, "State")) {
                    const ST = resolveState(mod);
                    fields[count] = .{
                        .name = d.name,
                        .type = ST,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(ST),
                    };
                    count += 1;
                }
            }
            if (count == 0) {
                return struct {};
            }
            return @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = fields[0..count],
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        }

        /// Resolve a script's State type. Handles both:
        ///   pub const State = struct { ... };           → plain type
        ///   pub fn State(comptime Ecs: type) type { ... } → parameterized
        fn resolveState(comptime mod: type) type {
            const S = @field(mod, "State");
            const info = @typeInfo(@TypeOf(S));
            if (info == .type) return S;
            // It's a function — call with EcsBackend
            return S(EcsBackend);
        }

        /// A game script exports at least one of: setup, tick, drawGui, State.
        /// Scripts without any of these are scene scripts (init/update/deinit).
        fn isGameScript(comptime mod: type) bool {
            return @hasDecl(mod, "setup") or @hasDecl(mod, "tick") or
                @hasDecl(mod, "drawGui") or @hasDecl(mod, "State");
        }

        pub fn init(allocator: std.mem.Allocator, ecs_backend: anytype) Self {
            var self = Self{
                .states = undefined,
                .ctx = .{},
                .allocator = allocator,
            };
            const decls = @typeInfo(AllScripts).@"struct".decls;
            inline for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime isGameScript(mod) and @hasDecl(mod, "State")) {
                    const ST = resolveState(mod);
                    if (comptime @hasDecl(ST, "init")) {
                        @field(self.states, d.name) = ST.init(allocator, ecs_backend);
                    } else {
                        @field(self.states, d.name) = .{};
                    }
                }
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            const decls = @typeInfo(AllScripts).@"struct".decls;
            inline for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime isGameScript(mod) and @hasDecl(mod, "State")) {
                    const ST = resolveState(mod);
                    if (comptime @hasDecl(ST, "deinit")) {
                        (&@field(self.states, d.name)).deinit();
                    }
                }
            }
        }

        /// Run setup for all scripts that declare it.
        ///
        /// Scripts are dispatched in alphabetical declaration order from AllScripts.
        /// This is safe because setup is for registration/configuration (e.g. registering
        /// callbacks, initializing state fields) — it does not query entities or depend on
        /// other scripts having run first. Entity creation happens later, during scene
        /// loading or the first tick.
        pub fn setup(self: *Self, game: anytype) void {
            const decls = @typeInfo(AllScripts).@"struct".decls;
            inline for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime @hasDecl(mod, "setup")) {
                    dispatchCall(mod.setup, game, self, d.name);
                }
            }
        }

        pub fn tick(self: *Self, game: anytype, dt: f32) void {
            const active = getActiveFilter(game);
            const decls = @typeInfo(AllScripts).@"struct".decls;
            inline for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime @hasDecl(mod, "tick")) {
                    if (active == null or nameInSlice(d.name, active.?)) {
                        dispatchTickCall(mod.tick, game, self, d.name, dt);
                    }
                }
            }
        }

        pub fn drawGui(self: *Self, game: anytype) void {
            const active = getActiveFilter(game);
            const decls = @typeInfo(AllScripts).@"struct".decls;
            inline for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime @hasDecl(mod, "drawGui")) {
                    if (active == null or nameInSlice(d.name, active.?)) {
                        dispatchCall(mod.drawGui, game, self, d.name);
                    }
                }
            }
        }

        /// Query the game for the active scene's script filter list.
        /// Returns null if no filtering (tick all scripts).
        fn getActiveFilter(game: anytype) ?[]const []const u8 {
            const GameType = @typeInfo(@TypeOf(game)).pointer.child;
            if (comptime @hasDecl(GameType, "getActiveScriptNames")) {
                return game.getActiveScriptNames();
            }
            return null;
        }

        fn nameInSlice(comptime name: []const u8, names: []const []const u8) bool {
            for (names) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
            return false;
        }

        /// Dispatch setup/drawGui by arity:
        ///   1 arg: func(game)
        ///   2 args: func(game, ctx)
        ///   3 args: func(game, state, ctx)
        fn dispatchCall(
            comptime func: anytype,
            game: anytype,
            self: *Self,
            comptime name: []const u8,
        ) void {
            const n = comptime @typeInfo(@TypeOf(func)).@"fn".params.len;
            if (n == 3) {
                func(game, &@field(self.states, name), &self.ctx);
            } else if (n == 2) {
                func(game, &self.ctx);
            } else if (n == 1) {
                func(game);
            } else {
                @compileError("setup/drawGui in '" ++ name ++ "' must take 1-3 args");
            }
        }

        /// Dispatch tick by arity:
        ///   2 args: func(game, dt)
        ///   3 args: func(game, ctx, dt)
        ///   4 args: func(game, state, ctx, dt)
        fn dispatchTickCall(
            comptime func: anytype,
            game: anytype,
            self: *Self,
            comptime name: []const u8,
            dt: f32,
        ) void {
            const n = comptime @typeInfo(@TypeOf(func)).@"fn".params.len;
            if (n == 4) {
                func(game, &@field(self.states, name), &self.ctx, dt);
            } else if (n == 3) {
                func(game, &self.ctx, dt);
            } else if (n == 2) {
                func(game, dt);
            } else {
                @compileError("tick in '" ++ name ++ "' must take 2-4 args");
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "ScriptRunner.tick only runs scripts listed in active scene" {
    // Two scripts: alpha ticks always, beta ticks always — but scene only lists alpha
    var tick_log = [2]bool{ false, false };

    const AllScripts = struct {
        pub const alpha = struct {
            pub fn tick(game: anytype, _: f32) void {
                game.tick_log[0] = true;
            }
        };
        pub const beta = struct {
            pub fn tick(game: anytype, _: f32) void {
                game.tick_log[1] = true;
            }
        };
    };

    const MockGame = struct {
        tick_log: *[2]bool,

        pub fn getActiveScriptNames(_: *const @This()) ?[]const []const u8 {
            return &.{"alpha"};
        }
    };

    var game = MockGame{ .tick_log = &tick_log };

    const Runner = ScriptRunner(AllScripts, struct {}, struct {});
    var runner = Runner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    try std.testing.expect(tick_log[0]); // alpha should have ticked
    try std.testing.expect(!tick_log[1]); // beta should NOT have ticked
}

test "ScriptRunner.tick runs all scripts when getActiveScriptNames returns null" {
    var tick_log = [2]bool{ false, false };

    const AllScripts = struct {
        pub const alpha = struct {
            pub fn tick(game: anytype, _: f32) void {
                game.tick_log[0] = true;
            }
        };
        pub const beta = struct {
            pub fn tick(game: anytype, _: f32) void {
                game.tick_log[1] = true;
            }
        };
    };

    const MockGame = struct {
        tick_log: *[2]bool,

        pub fn getActiveScriptNames(_: *const @This()) ?[]const []const u8 {
            return null; // no filtering
        }
    };

    var game = MockGame{ .tick_log = &tick_log };

    const Runner = ScriptRunner(AllScripts, struct {}, struct {});
    var runner = Runner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    try std.testing.expect(tick_log[0]); // alpha ticked
    try std.testing.expect(tick_log[1]); // beta ticked
}

test "ScriptRunner.tick runs all scripts when game has no getActiveScriptNames" {
    var tick_log = [2]bool{ false, false };

    const AllScripts = struct {
        pub const alpha = struct {
            pub fn tick(game: anytype, _: f32) void {
                game.tick_log[0] = true;
            }
        };
        pub const beta = struct {
            pub fn tick(game: anytype, _: f32) void {
                game.tick_log[1] = true;
            }
        };
    };

    // Game without getActiveScriptNames — backward compat
    const MockGame = struct {
        tick_log: *[2]bool,
    };

    var game = MockGame{ .tick_log = &tick_log };

    const Runner = ScriptRunner(AllScripts, struct {}, struct {});
    var runner = Runner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    try std.testing.expect(tick_log[0]);
    try std.testing.expect(tick_log[1]);
}
