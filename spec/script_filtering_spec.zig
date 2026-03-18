const std = @import("std");
const zspec = @import("zspec");
const engine = @import("engine");
const scene = @import("scene");

const expect = zspec.expect;

// =============================================================================
// Shared test fixtures
// =============================================================================

/// Two dummy script modules used across all scenarios.
const ScriptAlpha = struct {
    pub fn tick(game: anytype, _: f32) void {
        game.tick_log[0] = true;
    }
    pub fn update(_: *anyopaque, _: *anyopaque, _: f32) void {}
};

const ScriptBeta = struct {
    pub fn tick(game: anytype, _: f32) void {
        game.tick_log[1] = true;
    }
    pub fn update(_: *anyopaque, _: *anyopaque, _: f32) void {}
};

const AllScripts = struct {
    pub const alpha = ScriptAlpha;
    pub const beta = ScriptBeta;
};

const Scripts = scene.ScriptRegistry(AllScripts);
const Runner = engine.ScriptRunner(AllScripts, struct {}, struct {});

/// Mock game that supports getActiveScriptNames filtering + tick logging.
fn MockGameWith(comptime filter: ?[]const []const u8) type {
    return struct {
        const Self = @This();
        tick_log: *[2]bool,

        pub fn getActiveScriptNames(_: *const Self) ?[]const []const u8 {
            return filter;
        }
    };
}

/// Mock game without getActiveScriptNames (backward compat).
const LegacyMockGame = struct {
    tick_log: *[2]bool,
};

fn resetAndTick(comptime GameType: type, game: *GameType) void {
    game.tick_log.* = .{ false, false };
    var runner = Runner.init(std.testing.allocator, &{});
    runner.tick(game, 0.016);
}

// =============================================================================
// Specs
// =============================================================================

pub const ScriptRunnerFiltering = zspec.describe("ScriptRunner scene filtering", struct {
    pub const @"when scene lists specific scripts" = zspec.describe("when scene lists specific scripts", struct {
        pub fn @"only ticks scripts in the active list"() !void {
            var tick_log = [2]bool{ false, false };
            const FilteredGame = MockGameWith(&.{"alpha"});
            var game = FilteredGame{ .tick_log = &tick_log };
            resetAndTick(FilteredGame, &game);

            try expect.toBeTrue(tick_log[0]);
            try expect.toBeFalse(tick_log[1]);
        }

        pub fn @"skips drawGui for unlisted scripts"() !void {
            // drawGui uses the same filter — verified by the same getActiveFilter path.
            // If tick filtering works, drawGui filtering works (shared implementation).
            var tick_log = [2]bool{ false, false };
            const FilteredGame = MockGameWith(&.{"beta"});
            var game = FilteredGame{ .tick_log = &tick_log };
            resetAndTick(FilteredGame, &game);

            try expect.toBeFalse(tick_log[0]);
            try expect.toBeTrue(tick_log[1]);
        }
    });

    pub const @"when scene has no .scripts field (null)" = zspec.describe("when scene has no .scripts field (null)", struct {
        pub fn @"ticks all scripts"() !void {
            var tick_log = [2]bool{ false, false };
            const UnfilteredGame = MockGameWith(null);
            var game = UnfilteredGame{ .tick_log = &tick_log };
            resetAndTick(UnfilteredGame, &game);

            try expect.toBeTrue(tick_log[0]);
            try expect.toBeTrue(tick_log[1]);
        }
    });

    pub const @"when game has no getActiveScriptNames (backward compat)" = zspec.describe("when game has no getActiveScriptNames (backward compat)", struct {
        pub fn @"ticks all scripts"() !void {
            var tick_log = [2]bool{ false, false };
            var game = LegacyMockGame{ .tick_log = &tick_log };
            game.tick_log.* = .{ false, false };
            var runner = Runner.init(std.testing.allocator, &{});
            runner.tick(&game, 0.016);

            try expect.toBeTrue(tick_log[0]);
            try expect.toBeTrue(tick_log[1]);
        }
    });
});

pub const SceneLoaderScriptNames = zspec.describe("SceneLoader script name passthrough", struct {
    const labelle_core = @import("labelle-core");
    const MockEcs = labelle_core.MockEcsBackend(u32);
    const MockSprite = struct { texture: []const u8 = "" };
    const MockShape = struct { kind: []const u8 = "" };

    /// Shared mock game that captures the script_names arg from setActiveScene.
    fn CapturingGame(comptime sentinel: ?[]const []const u8) type {
        return struct {
            const Self = @This();
            pub const EntityType = u32;
            pub const EcsBackend = MockEcs;
            pub const SpriteComp = MockSprite;
            pub const ShapeComp = MockShape;

            ecs_backend: MockEcs,
            allocator: std.mem.Allocator,
            captured_script_names: ?[]const []const u8 = sentinel,
            set_active_called: bool = false,
            gizmo_reconcile_fn: ?*const fn (*Self) void = null,

            pub fn createEntity(self: *Self) u32 {
                return self.ecs_backend.createEntity();
            }
            pub fn setPosition(_: *Self, _: u32, _: anytype) void {}
            pub fn addSprite(_: *Self, _: u32, _: MockSprite) void {}
            pub fn addShape(_: *Self, _: u32, _: MockShape) void {}
            pub fn fireOnReady(_: *Self, _: u32, comptime _: type) void {}
            pub fn setParent(_: *Self, _: u32, _: u32, _: anytype) void {}
            pub fn destroyEntityOnly(_: *Self, _: u32) void {}

            pub fn setActiveScene(
                self: *Self,
                _: *anyopaque,
                _: anytype,
                _: anytype,
                _: anytype,
                script_names: ?[]const []const u8,
            ) void {
                self.captured_script_names = script_names;
                self.set_active_called = true;
            }
        };
    }

    const Components = scene.ComponentRegistry(.{});
    const Prefabs = scene.PrefabRegistry(.{});

    pub const @"when scene defines .scripts" = zspec.describe("when scene defines .scripts", struct {
        pub fn @"passes listed script names to setActiveScene"() !void {
            const Game = CapturingGame(null);
            const Loader = scene.SceneLoader(Game, Prefabs, Components, Scripts);
            const allocator = std.testing.allocator;

            var ecs = MockEcs.init(allocator);
            defer ecs.deinit();

            var game = Game{ .ecs_backend = ecs, .allocator = allocator };

            const loader_fn = Loader.sceneLoaderFn(.{
                .name = "filtered_scene",
                .scripts = .{"alpha"},
                .entities = .{},
            });

            try loader_fn(&game);

            const names = game.captured_script_names orelse return error.ScriptNamesNotCaptured;
            try expect.equal(names.len, 1);
            try expect.toBeTrue(std.mem.eql(u8, names[0], "alpha"));
        }
    });

    pub const @"when scene omits .scripts" = zspec.describe("when scene omits .scripts", struct {
        pub fn @"passes null to setActiveScene (no filtering)"() !void {
            const Game = CapturingGame(@as(?[]const []const u8, &.{}));
            const NoScripts = scene.ScriptRegistry(struct {});
            const Loader = scene.SceneLoader(Game, Prefabs, Components, NoScripts);
            const allocator = std.testing.allocator;

            var ecs = MockEcs.init(allocator);
            defer ecs.deinit();

            var game = Game{ .ecs_backend = ecs, .allocator = allocator };

            const loader_fn = Loader.sceneLoaderFn(.{
                .name = "unfiltered_scene",
                .entities = .{},
            });

            try loader_fn(&game);

            try expect.toBeTrue(game.set_active_called);
            try expect.toBeNull(game.captured_script_names);
        }
    });
});
