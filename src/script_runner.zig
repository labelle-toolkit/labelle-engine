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
        const builtin = @import("builtin");
        pub const profiling_enabled = builtin.mode == .Debug;

        /// Profiling data — timing per script per phase. Only in debug builds.
        pub const ProfileEntry = struct {
            name: []const u8,
            tick_ns: u64 = 0,
            draw_gui_ns: u64 = 0,
        };

        pub const script_count: usize = blk: {
            var count: usize = 0;
            for (@typeInfo(AllScripts).@"struct".decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (isGameScript(mod)) count += 1;
            }
            break :blk count;
        };

        // Fields
        states: States,
        ctx: CtxType,
        allocator: std.mem.Allocator,
        profile: if (profiling_enabled) [script_count]ProfileEntry else void =
            if (profiling_enabled) initProfile() else {},

        fn initProfile() [script_count]ProfileEntry {
            comptime {
                var entries: [script_count]ProfileEntry = undefined;
                var idx: usize = 0;
                for (@typeInfo(AllScripts).@"struct".decls) |d| {
                    const mod = @field(AllScripts, d.name);
                    if (isGameScript(mod)) {
                        entries[idx] = .{ .name = d.name };
                        idx += 1;
                    }
                }
                return entries;
            }
        }

        /// Comptime-built struct with one field per script that exports State.
        const States = buildStatesType();

        fn buildStatesType() type {
            const decls = @typeInfo(AllScripts).@"struct".decls;
            var fields: [decls.len]std.builtin.Type.StructField = undefined;
            var count: usize = 0;
            for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime isGameScript(mod) and hasStateDecl(mod)) {
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
        /// Decls must be actual functions/types, not empty struct literals from wrappers.
        fn isGameScript(comptime mod: type) bool {
            return isFnDecl(mod, "setup") or isFnDecl(mod, "tick") or
                isFnDecl(mod, "drawGui") or isFnDecl(mod, "onEvent") or @hasDecl(mod, "State");
        }

        fn hasStateDecl(comptime mod: type) bool {
            if (!@hasDecl(mod, "State")) return false;
            const info = @typeInfo(@TypeOf(@field(mod, "State")));
            return info == .type or info == .@"fn";
        }

        fn isFnDecl(comptime mod: type, comptime name: []const u8) bool {
            if (!@hasDecl(mod, name)) return false;
            return @typeInfo(@TypeOf(@field(mod, name))) == .@"fn";
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
                if (comptime isGameScript(mod) and hasStateDecl(mod)) {
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
                if (comptime isGameScript(mod) and hasStateDecl(mod)) {
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
                if (comptime isFnDecl(mod, "setup")) {
                    dispatchCall(mod.setup, game, self, d.name);
                }
            }
        }

        pub fn tick(self: *Self, game: anytype, dt: f32) void {
            const current_state = getGameState(game);
            const decls = @typeInfo(AllScripts).@"struct".decls;
            comptime var profile_idx: usize = 0;
            inline for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime isGameScript(mod)) {
                    if (comptime isFnDecl(mod, "tick")) {
                        if (isStateAllowedCached(mod, current_state)) {
                            if (profiling_enabled) {
                                var timer = std.time.Timer.start() catch null;
                                dispatchTickCall(mod.tick, game, self, d.name, dt);
                                if (timer) |*t| {
                                    self.profile[profile_idx].tick_ns = t.read();
                                }
                            } else {
                                dispatchTickCall(mod.tick, game, self, d.name, dt);
                            }
                        } else if (profiling_enabled) {
                            self.profile[profile_idx].tick_ns = 0;
                        }
                    }
                    profile_idx += 1;
                }
            }
        }

        pub fn drawGui(self: *Self, game: anytype) void {
            const current_state = getGameState(game);
            const decls = @typeInfo(AllScripts).@"struct".decls;
            comptime var profile_idx: usize = 0;
            inline for (decls) |d| {
                const mod = @field(AllScripts, d.name);
                if (comptime isGameScript(mod)) {
                    if (comptime isFnDecl(mod, "drawGui")) {
                        if (isStateAllowedCached(mod, current_state)) {
                            if (profiling_enabled) {
                                var timer = std.time.Timer.start() catch null;
                                dispatchCall(mod.drawGui, game, self, d.name);
                                if (timer) |*t| {
                                    self.profile[profile_idx].draw_gui_ns = t.read();
                                }
                            } else {
                                dispatchCall(mod.drawGui, game, self, d.name);
                            }
                        } else if (profiling_enabled) {
                            self.profile[profile_idx].draw_gui_ns = 0;
                        }
                    }
                    profile_idx += 1;
                }
            }
        }

        /// Deliver buffered game events to all scripts that declare onEvent.
        /// Called after all script ticks complete (end-of-frame delivery).
        pub fn dispatchEvents(self: *Self, game: anytype) void {
            const info = @typeInfo(@TypeOf(game));
            const GameType = if (info == .pointer) info.pointer.child else @TypeOf(game);
            if (comptime !@hasField(GameType, "event_buffer")) return;
            if (comptime @TypeOf(@as(GameType, undefined).event_buffer) == void) return;

            const current_state = getGameState(game);
            const decls = @typeInfo(AllScripts).@"struct".decls;

            // Swap buffers to avoid invalidation if onEvent emits new events.
            var dispatch_buf: @TypeOf(game.event_buffer) = .{};
            std.mem.swap(@TypeOf(game.event_buffer), &game.event_buffer, &dispatch_buf);

            for (dispatch_buf.items) |event| {
                inline for (decls) |d| {
                    const mod = @field(AllScripts, d.name);
                    if (comptime isGameScript(mod) and isFnDecl(mod, "onEvent")) {
                        if (isStateAllowedCached(mod, current_state)) {
                            dispatchEventCall(mod.onEvent, game, self, d.name, event);
                        }
                    }
                }
            }
            dispatch_buf.clearRetainingCapacity();

            // Swap back — any events emitted during dispatch are now in game.event_buffer
            // and will be delivered next frame.
            if (game.event_buffer.items.len == 0) {
                // No new events emitted during dispatch — reuse the dispatch buffer
                std.mem.swap(@TypeOf(game.event_buffer), &game.event_buffer, &dispatch_buf);
            }
            dispatch_buf.deinit(game.allocator);
        }

        /// Dispatch onEvent by arity:
        ///   2 args: func(game, event)
        ///   3 args: func(game, state, event)
        fn dispatchEventCall(
            comptime func: anytype,
            game: anytype,
            self: *Self,
            comptime name: []const u8,
            event: anytype,
        ) void {
            const n = comptime @typeInfo(@TypeOf(func)).@"fn".params.len;
            if (n == 3) {
                func(game, &@field(self.states, name), event);
            } else if (n == 2) {
                func(game, event);
            } else {
                @compileError("onEvent in '" ++ name ++ "' must take 2-3 args (game + [state] + event)");
            }
        }

        /// Check whether a script is allowed to run given a cached game state.
        /// Scripts with a `pub const game_states` tuple only run when the state
        /// matches one of the listed strings. Scripts without the decl
        /// (or when state is null) run unconditionally.
        fn isStateAllowedCached(comptime mod: type, state: ?[]const u8) bool {
            if (!@hasDecl(mod, "game_states")) return true;

            const game_state = state orelse return true;
            const states = mod.game_states;
            inline for (states) |s| {
                if (std.mem.eql(u8, s, game_state)) return true;
            }
            return false;
        }

        /// Query the game for its current state string.
        /// Returns null if the game type has no state machine.
        fn getGameState(game: anytype) ?[]const u8 {
            const info = @typeInfo(@TypeOf(game));
            const GameType = if (info == .pointer) info.pointer.child else @TypeOf(game);
            if (comptime @hasDecl(GameType, "getState")) {
                return game.getState();
            }
            return null;
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
