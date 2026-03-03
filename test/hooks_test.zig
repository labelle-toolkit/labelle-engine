const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const Factory = zspec.Factory;

const engine = @import("labelle-engine");
const hooks = engine.hooks;
const EngineHook = hooks.EngineHook;
const HookPayload = hooks.HookPayload;
const FrameInfo = hooks.FrameInfo;
const SceneInfo = hooks.SceneInfo;
const EntityInfo = hooks.EntityInfo;
const HookDispatcher = hooks.HookDispatcher;
const MergeHooks = hooks.MergeHooks;
const GameInitInfo = hooks.GameInitInfo;

// Import factory definitions from .zon file
const hook_payloads = @import("factories/hook_payloads.zon");

test {
    zspec.runAll(@This());
}

// Define factories from .zon files
const FrameInfoFactory = Factory.defineFrom(FrameInfo, hook_payloads.frame_info.default);
const FirstFrameFactory = Factory.defineFrom(FrameInfo, hook_payloads.frame_info.first_frame);
const Frame60Factory = Factory.defineFrom(FrameInfo, hook_payloads.frame_info.frame_60);
const SlowFrameFactory = Factory.defineFrom(FrameInfo, hook_payloads.frame_info.slow_frame);

const SceneInfoFactory = Factory.defineFrom(SceneInfo, hook_payloads.scene_info.main);
const Level1SceneFactory = Factory.defineFrom(SceneInfo, hook_payloads.scene_info.level1);

const EntityInfoFactory = Factory.defineFrom(EntityInfo, hook_payloads.entity_info.default);
const PlayerEntityFactory = Factory.defineFrom(EntityInfo, hook_payloads.entity_info.player);
const EnemyEntityFactory = Factory.defineFrom(EntityInfo, hook_payloads.entity_info.enemy);
const NoPrefabEntityFactory = Factory.defineFrom(EntityInfo, hook_payloads.entity_info.no_prefab);

// ============================================
// Test Hook Types
// ============================================

pub const ENGINE_HOOK = struct {
    pub const ENUM_VALUES = struct {
        test "has 9 hook types" {
            const hook_values = std.enums.values(EngineHook);
            try expect.equal(hook_values.len, 9);
        }

        test "includes game lifecycle hooks" {
            _ = EngineHook.game_init;
            _ = EngineHook.game_deinit;
        }

        test "includes frame hooks" {
            _ = EngineHook.frame_start;
            _ = EngineHook.frame_end;
        }

        test "includes scene hooks" {
            _ = EngineHook.scene_before_load;
            _ = EngineHook.scene_load;
            _ = EngineHook.scene_unload;
        }

        test "includes entity hooks" {
            _ = EngineHook.entity_created;
            _ = EngineHook.entity_destroyed;
        }
    };
};

pub const FRAME_INFO = struct {
    pub const DEFAULTS = struct {
        test "has default values" {
            const info = FrameInfoFactory.build(.{});
            try expect.equal(info.frame_number, 0);
            try expect.equal(info.dt, 0);
        }
    };

    pub const INITIALIZATION = struct {
        test "can set frame_number" {
            const info = FirstFrameFactory.build(.{});
            try expect.equal(info.frame_number, 1);
        }

        test "can set dt" {
            const info = SlowFrameFactory.build(.{});
            try expect.equal(info.dt, 0.033);
        }

        test "can build frame 60" {
            const info = Frame60Factory.build(.{});
            try expect.equal(info.frame_number, 60);
            try expect.equal(info.dt, 0.016);
        }
    };
};

pub const SCENE_INFO = struct {
    pub const INITIALIZATION = struct {
        test "can set scene name" {
            const info = SceneInfoFactory.build(.{});
            try expect.toBeTrue(std.mem.eql(u8, info.name, "main"));
        }

        test "can have different scene names" {
            const info = Level1SceneFactory.build(.{});
            try expect.toBeTrue(std.mem.eql(u8, info.name, "level1"));
        }
    };
};

pub const ENTITY_INFO = struct {
    pub const DEFAULTS = struct {
        test "has default values" {
            const info = EntityInfoFactory.build(.{});
            try expect.equal(info.entity_id, 0);
            try expect.toBeNull(info.prefab_name);
        }
    };

    pub const INITIALIZATION = struct {
        test "can set entity_id and prefab_name" {
            const info = PlayerEntityFactory.build(.{});
            try expect.equal(info.entity_id, 42);
            try expect.toBeTrue(std.mem.eql(u8, info.prefab_name.?, "player"));
        }

        test "can have entity without prefab" {
            const info = NoPrefabEntityFactory.build(.{});
            try expect.equal(info.entity_id, 50);
            try expect.toBeNull(info.prefab_name);
        }
    };
};

pub const HOOK_PAYLOAD = struct {
    pub const CREATION = struct {
        test "can create game_init payload" {
            const payload: HookPayload = .{ .game_init = .{ .allocator = std.testing.allocator } };
            try expect.equal(std.meta.activeTag(payload), .game_init);
        }

        test "game_init payload has allocator" {
            const payload: HookPayload = .{ .game_init = .{ .allocator = std.testing.allocator } };
            const info = payload.game_init;
            // Verify allocator is accessible and usable
            const ptr = try info.allocator.alloc(u8, 16);
            defer info.allocator.free(ptr);
            try expect.equal(ptr.len, 16);
        }

        test "can create game_deinit payload" {
            const payload: HookPayload = .{ .game_deinit = {} };
            try expect.equal(std.meta.activeTag(payload), .game_deinit);
        }

        test "can create frame_start payload" {
            const frame_info = FirstFrameFactory.build(.{});
            const payload: HookPayload = .{ .frame_start = frame_info };
            try expect.equal(payload.frame_start.frame_number, 1);
            try expect.equal(payload.frame_start.dt, 0.016);
        }

        test "can create frame_end payload" {
            const frame_info = Frame60Factory.build(.{});
            const payload: HookPayload = .{ .frame_end = frame_info };
            try expect.equal(payload.frame_end.frame_number, 60);
        }

        test "can create scene_before_load payload" {
            const payload: HookPayload = .{ .scene_before_load = .{
                .name = "bakery",
                .allocator = std.testing.allocator,
            } };
            try expect.toBeTrue(std.mem.eql(u8, payload.scene_before_load.name, "bakery"));
            // Verify allocator is set correctly by checking vtable pointer
            try expect.equal(payload.scene_before_load.allocator.vtable, std.testing.allocator.vtable);
        }

        test "scene_before_load payload has allocator" {
            const payload: HookPayload = .{ .scene_before_load = .{
                .name = "test",
                .allocator = std.testing.allocator,
            } };
            const info = payload.scene_before_load;
            // Verify allocator is accessible and usable
            const ptr = try info.allocator.alloc(u8, 16);
            defer info.allocator.free(ptr);
            try expect.equal(ptr.len, 16);
        }

        test "can create scene_load payload" {
            const scene_info = SceneInfoFactory.build(.{});
            const payload: HookPayload = .{ .scene_load = scene_info };
            try expect.toBeTrue(std.mem.eql(u8, payload.scene_load.name, "main"));
        }

        test "can create scene_unload payload" {
            const scene_info = Level1SceneFactory.build(.{});
            const payload: HookPayload = .{ .scene_unload = scene_info };
            try expect.toBeTrue(std.mem.eql(u8, payload.scene_unload.name, "level1"));
        }

        test "can create entity_created payload" {
            const entity_info = PlayerEntityFactory.build(.{});
            const payload: HookPayload = .{ .entity_created = entity_info };
            try expect.equal(payload.entity_created.entity_id, 42);
            try expect.toBeTrue(std.mem.eql(u8, payload.entity_created.prefab_name.?, "player"));
        }

        test "can create entity_destroyed payload" {
            const entity_info = EnemyEntityFactory.build(.{});
            const payload: HookPayload = .{ .entity_destroyed = entity_info };
            try expect.equal(payload.entity_destroyed.entity_id, 100);
        }
    };

    test "all 9 payload types can be created" {
        const payloads = [_]HookPayload{
            .{ .game_init = .{ .allocator = std.testing.allocator } },
            .{ .game_deinit = {} },
            .{ .frame_start = FirstFrameFactory.build(.{}) },
            .{ .frame_end = FirstFrameFactory.build(.{}) },
            .{ .scene_before_load = .{ .name = "test", .allocator = std.testing.allocator } },
            .{ .scene_load = SceneInfoFactory.build(.{}) },
            .{ .scene_unload = SceneInfoFactory.build(.{}) },
            .{ .entity_created = PlayerEntityFactory.build(.{}) },
            .{ .entity_destroyed = PlayerEntityFactory.build(.{}) },
        };
        try expect.equal(payloads.len, 9);
    }
};

// ============================================
// Test Hook Dispatcher (receiver-based)
// ============================================

// Test payload union for dispatcher tests
const TestPayload = union(enum) {
    on_start: void,
    on_update: f32,
    on_end: void,
};

// State for tracking handler calls
var test_start_called: bool = false;
var test_update_value: f32 = 0;

const TestHandlers = struct {
    pub fn on_start(_: @This(), _: void) void {
        test_start_called = true;
    }

    pub fn on_update(_: @This(), dt: f32) void {
        test_update_value = dt;
    }
    // Note: on_end has no handler
};

pub const HOOK_DISPATCHER = struct {
    pub const EMIT = struct {
        test "emits to registered handlers" {
            const Dispatcher = HookDispatcher(TestPayload, TestHandlers, .{});
            const d = Dispatcher{ .receiver = .{} };

            test_start_called = false;
            d.emit(.{ .on_start = {} });
            try expect.toBeTrue(test_start_called);
        }

        test "passes payload data to handler" {
            const Dispatcher = HookDispatcher(TestPayload, TestHandlers, .{});
            const d = Dispatcher{ .receiver = .{} };

            test_update_value = 0;
            d.emit(.{ .on_update = 0.016 });
            // Use std.testing for approximate equality since zspec doesn't have it
            try std.testing.expectApproxEqAbs(@as(f32, 0.016), test_update_value, 0.0001);
        }

        test "is no-op for unregistered hooks" {
            const Dispatcher = HookDispatcher(TestPayload, TestHandlers, .{});
            const d = Dispatcher{ .receiver = .{} };
            // on_end has no handler, should not crash
            d.emit(.{ .on_end = {} });
        }
    };

    pub const HAS_HANDLER = struct {
        test "returns true for registered hook" {
            const Dispatcher = HookDispatcher(TestPayload, TestHandlers, .{});
            try expect.toBeTrue(Dispatcher.hasHandler("on_start"));
            try expect.toBeTrue(Dispatcher.hasHandler("on_update"));
        }

        test "returns false for unregistered hook" {
            const Dispatcher = HookDispatcher(TestPayload, TestHandlers, .{});
            try expect.toBeFalse(Dispatcher.hasHandler("on_end"));
        }
    };

    pub const ZERO_SIZE = struct {
        test "stateless dispatcher is zero-size" {
            const Dispatcher = HookDispatcher(TestPayload, TestHandlers, .{});
            try expect.equal(@sizeOf(Dispatcher), 0);
        }
    };
};

pub const EMPTY_DISPATCHER = struct {
    test "empty receiver has no handlers" {
        const Dispatcher = HookDispatcher(TestPayload, struct {}, .{});
        try expect.toBeFalse(Dispatcher.hasHandler("on_start"));
        try expect.toBeFalse(Dispatcher.hasHandler("on_update"));
        try expect.toBeFalse(Dispatcher.hasHandler("on_end"));
    }

    test "emit does not crash with empty receiver" {
        const Dispatcher = HookDispatcher(TestPayload, struct {}, .{});
        const d = Dispatcher{ .receiver = .{} };

        // Should not crash
        d.emit(.{ .on_start = {} });
        d.emit(.{ .on_update = 0.016 });
        d.emit(.{ .on_end = {} });
    }
};

// ============================================
// Test Engine Hook Dispatcher
// ============================================

pub const ENGINE_HOOK_DISPATCHER = struct {
    const TestEngineHandlers = struct {
        pub fn game_init(_: @This(), _: GameInitInfo) void {}
    };

    test "creates valid dispatcher" {
        const Dispatcher = engine.EngineHookDispatcher(TestEngineHandlers);
        try expect.toBeTrue(Dispatcher.hasHandler("game_init"));
        try expect.toBeFalse(Dispatcher.hasHandler("game_deinit"));
    }
};

pub const EMPTY_ENGINE_DISPATCHER = struct {
    test "has no handlers" {
        try expect.toBeFalse(engine.EmptyEngineDispatcher.hasHandler("game_init"));
    }

    test "is zero-size" {
        try expect.equal(@sizeOf(engine.EmptyEngineDispatcher), 0);
    }
};

// ============================================
// Test MergeHooks
// ============================================

// State for tracking merged handler calls
var merge_handler_a_called: bool = false;
var merge_handler_b_called: bool = false;
var merge_update_count: u32 = 0;

const MergeHandlersA = struct {
    pub fn on_start(_: @This(), _: void) void {
        merge_handler_a_called = true;
    }

    pub fn on_update(_: @This(), _: f32) void {
        merge_update_count += 1;
    }
};

const MergeHandlersB = struct {
    pub fn on_start(_: @This(), _: void) void {
        merge_handler_b_called = true;
    }

    pub fn on_update(_: @This(), _: f32) void {
        merge_update_count += 1;
    }

    pub fn on_end(_: @This(), _: void) void {
        // Handler B has on_end, Handler A doesn't
    }
};

const MergeHandlersEmpty = struct {};

pub const MERGE_HOOKS = struct {
    pub const EMIT = struct {
        test "calls handlers from both receiver types" {
            const Merged = MergeHooks(TestPayload, .{ MergeHandlersA, MergeHandlersB });
            const m = Merged{ .receivers = .{ .{}, .{} } };

            merge_handler_a_called = false;
            merge_handler_b_called = false;
            m.emit(.{ .on_start = {} });

            try expect.toBeTrue(merge_handler_a_called);
            try expect.toBeTrue(merge_handler_b_called);
        }

        test "calls overlapping hooks in order" {
            const Merged = MergeHooks(TestPayload, .{ MergeHandlersA, MergeHandlersB });
            const m = Merged{ .receivers = .{ .{}, .{} } };

            merge_update_count = 0;
            m.emit(.{ .on_update = 0.016 });

            // Both handlers should be called
            try expect.equal(merge_update_count, 2);
        }

        test "calls hook that only exists in one receiver" {
            const Merged = MergeHooks(TestPayload, .{ MergeHandlersA, MergeHandlersB });
            const m = Merged{ .receivers = .{ .{}, .{} } };

            // on_end only exists in MergeHandlersB - should not crash
            m.emit(.{ .on_end = {} });
        }

        test "is no-op when no receiver has handler" {
            const Merged = MergeHooks(TestPayload, .{ MergeHandlersEmpty, MergeHandlersEmpty });
            const m = Merged{ .receivers = .{ .{}, .{} } };

            // Should not crash
            m.emit(.{ .on_start = {} });
            m.emit(.{ .on_update = 0.016 });
            m.emit(.{ .on_end = {} });
        }
    };

    pub const ZERO_SIZE = struct {
        test "merged stateless receivers are zero-size" {
            const Merged = MergeHooks(TestPayload, .{ MergeHandlersA, MergeHandlersB });
            try expect.equal(@sizeOf(Merged), 0);
        }
    };
};

pub const MERGE_ENGINE_HOOKS = struct {
    const GameHooks = struct {
        pub fn game_init(_: @This(), _: GameInitInfo) void {}
    };

    const PluginHooks = struct {
        pub fn game_init(_: @This(), _: GameInitInfo) void {}
        pub fn frame_start(_: @This(), _: FrameInfo) void {}
    };

    test "creates valid merged dispatcher" {
        const Merged = engine.MergeEngineHooks(.{ GameHooks, PluginHooks });
        const m = Merged{ .receivers = .{ .{}, .{} } };
        // Verify emit doesn't crash
        m.emit(.{ .game_init = .{ .allocator = std.testing.allocator } });
    }

    test "merged engine dispatcher is zero-size" {
        const Merged = engine.MergeEngineHooks(.{ GameHooks, PluginHooks });
        try expect.equal(@sizeOf(Merged), 0);
    }
};

// ============================================
// Test scene_unload double-emit guard
// ============================================

// State for tracking scene_unload emissions
var scene_unload_count: u32 = 0;
var scene_unload_last_name: ?[]const u8 = null;

const SceneUnloadTracker = struct {
    pub fn scene_unload(_: @This(), info: SceneInfo) void {
        scene_unload_count += 1;
        scene_unload_last_name = info.name;
    }
};

pub const SCENE_UNLOAD_GUARD = struct {
    // Reproduces the template pattern:
    //   if (game.getCurrentSceneName() == null) {
    //       game.hook_dispatcher.emit(.{ .scene_unload = .{ .name = initial_scene.name } });
    //   }

    test "emits scene_unload at shutdown when no scene transition occurred" {
        const Dispatcher = engine.EngineHookDispatcher(SceneUnloadTracker);
        const d = Dispatcher{ .receiver = .{} };

        scene_unload_count = 0;
        scene_unload_last_name = null;

        // Simulate: initial scene loaded manually, game loop runs, no setScene called.
        // At shutdown, getCurrentSceneName() returns null → should emit.
        const current_scene_name: ?[]const u8 = null;

        if (current_scene_name == null) {
            d.emit(.{ .scene_unload = .{ .name = "main" } });
        }

        try expect.equal(scene_unload_count, 1);
        try expect.toBeTrue(std.mem.eql(u8, scene_unload_last_name.?, "main"));
    }

    test "does NOT emit scene_unload at shutdown after scene transition" {
        const Dispatcher = engine.EngineHookDispatcher(SceneUnloadTracker);
        const d = Dispatcher{ .receiver = .{} };

        scene_unload_count = 0;
        scene_unload_last_name = null;

        // Simulate: setScene("level2") was called during the game loop.
        // game.setScene() calls unloadCurrentScene() internally and sets current_scene_name.
        // At shutdown, getCurrentSceneName() returns "level2" → guard should prevent emit.
        const current_scene_name: ?[]const u8 = "level2";

        if (current_scene_name == null) {
            d.emit(.{ .scene_unload = .{ .name = "main" } });
        }

        try expect.equal(scene_unload_count, 0);
        try expect.toBeNull(scene_unload_last_name);
    }

    test "without guard, scene_unload fires incorrectly after scene transition" {
        // This test documents the bug that the guard prevents:
        // Without the null check, scene_unload would fire for the initial scene
        // even though a different scene is active.
        const Dispatcher = engine.EngineHookDispatcher(SceneUnloadTracker);
        const d = Dispatcher{ .receiver = .{} };

        scene_unload_count = 0;

        // Simulate full lifecycle with scene transition:
        // 1. game.setScene("level2") emits scene_unload for current scene (handled by Game)
        d.emit(.{ .scene_unload = .{ .name = "level2" } });

        // 2. At shutdown WITHOUT guard, template would unconditionally emit for initial scene
        d.emit(.{ .scene_unload = .{ .name = "main" } });

        // Bug: scene_unload fired twice — once for level2 (correct) and once for main (wrong)
        try expect.equal(scene_unload_count, 2);

        // 3. With the guard, only the level2 unload fires at shutdown.
        // Reset and simulate the correct behavior:
        scene_unload_count = 0;
        const current_scene_name: ?[]const u8 = "level2";

        // Game.deinit() unloads current scene
        d.emit(.{ .scene_unload = .{ .name = current_scene_name.? } });

        // Guarded emit — should NOT fire since current_scene_name != null
        if (current_scene_name == null) {
            d.emit(.{ .scene_unload = .{ .name = "main" } });
        }

        // Correct: only one scene_unload (for level2)
        try expect.equal(scene_unload_count, 1);
        try expect.toBeTrue(std.mem.eql(u8, scene_unload_last_name.?, "level2"));
    }
};

// ============================================
// Test Module Exports
// ============================================

pub const MODULE_EXPORTS = struct {
    test "hooks module exports EngineHook" {
        _ = engine.EngineHook.game_init;
    }

    test "hooks module exports HookPayload" {
        const payload: engine.HookPayload = .{ .game_init = .{ .allocator = std.testing.allocator } };
        _ = payload;
    }

    test "hooks module exports FrameInfo" {
        const info = engine.FrameInfo{ .frame_number = 1, .dt = 0.016 };
        _ = info;
    }

    test "hooks module exports SceneInfo" {
        const info = engine.SceneInfo{ .name = "test" };
        _ = info;
    }

    test "hooks module exports EntityInfo" {
        const info = engine.EntityInfo{ .entity_id = 42 };
        _ = info;
    }

    test "hooks module exports GameInitInfo" {
        const info = engine.GameInitInfo{ .allocator = std.testing.allocator };
        _ = info;
    }

    test "hooks module exports SceneBeforeLoadInfo" {
        const info = engine.SceneBeforeLoadInfo{ .name = "test", .allocator = std.testing.allocator };
        _ = info;
    }

    test "hooks module exports EngineHookDispatcher" {
        const Handlers = struct {};
        _ = engine.EngineHookDispatcher(Handlers);
    }

    test "hooks module exports HookDispatcher" {
        _ = engine.HookDispatcher;
    }

    test "hooks module exports MergeHooks" {
        _ = engine.MergeHooks;
    }

    test "hooks module exports MergeEngineHooks" {
        _ = engine.MergeEngineHooks;
    }

    test "hooks module exports UnwrapReceiver" {
        _ = engine.UnwrapReceiver;
    }
};
