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
const EmptyDispatcher = hooks.EmptyDispatcher;
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
        test "has 8 hook types" {
            const hook_values = std.enums.values(EngineHook);
            try expect.equal(hook_values.len, 8);
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

    test "all 8 payload types can be created" {
        const payloads = [_]HookPayload{
            .{ .game_init = .{ .allocator = std.testing.allocator } },
            .{ .game_deinit = {} },
            .{ .frame_start = FirstFrameFactory.build(.{}) },
            .{ .frame_end = FirstFrameFactory.build(.{}) },
            .{ .scene_load = SceneInfoFactory.build(.{}) },
            .{ .scene_unload = SceneInfoFactory.build(.{}) },
            .{ .entity_created = PlayerEntityFactory.build(.{}) },
            .{ .entity_destroyed = PlayerEntityFactory.build(.{}) },
        };
        try expect.equal(payloads.len, 8);
    }
};

// ============================================
// Test Hook Dispatcher
// ============================================

// Test hook enum and payload for dispatcher tests
const TestHook = enum {
    on_start,
    on_update,
    on_end,
};

const TestPayload = union(TestHook) {
    on_start: void,
    on_update: f32,
    on_end: void,
};

// State for tracking handler calls
var test_start_called: bool = false;
var test_update_value: f32 = 0;

const TestHandlers = struct {
    pub fn on_start(_: TestPayload) void {
        test_start_called = true;
    }

    pub fn on_update(payload: TestPayload) void {
        test_update_value = payload.on_update;
    }
    // Note: on_end has no handler
};

pub const HOOK_DISPATCHER = struct {
    pub const EMIT = struct {
        test "emits to registered handlers" {
            const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);

            test_start_called = false;
            Dispatcher.emit(.{ .on_start = {} });
            try expect.toBeTrue(test_start_called);
        }

        test "passes payload to handler" {
            const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);

            test_update_value = 0;
            Dispatcher.emit(.{ .on_update = 0.016 });
            // Use std.testing for approximate equality since zspec doesn't have it
            try std.testing.expectApproxEqAbs(@as(f32, 0.016), test_update_value, 0.0001);
        }

        test "is no-op for unregistered hooks" {
            const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);
            // on_end has no handler, should not crash
            Dispatcher.emit(.{ .on_end = {} });
        }
    };

    pub const HAS_HANDLER = struct {
        test "returns true for registered hook" {
            const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);
            try expect.toBeTrue(Dispatcher.hasHandler(.on_start));
            try expect.toBeTrue(Dispatcher.hasHandler(.on_update));
        }

        test "returns false for unregistered hook" {
            const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);
            try expect.toBeFalse(Dispatcher.hasHandler(.on_end));
        }
    };

    pub const HANDLER_COUNT = struct {
        test "returns correct count" {
            const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);
            try expect.equal(Dispatcher.handlerCount(), 2);
        }
    };
};

pub const EMPTY_DISPATCHER = struct {
    test "has no handlers" {
        const Dispatcher = EmptyDispatcher(TestHook, TestPayload);

        try expect.toBeFalse(Dispatcher.hasHandler(.on_start));
        try expect.toBeFalse(Dispatcher.hasHandler(.on_update));
        try expect.toBeFalse(Dispatcher.hasHandler(.on_end));
        try expect.equal(Dispatcher.handlerCount(), 0);
    }

    test "emit does not crash" {
        const Dispatcher = EmptyDispatcher(TestHook, TestPayload);

        // Should not crash
        Dispatcher.emit(.{ .on_start = {} });
        Dispatcher.emit(.{ .on_update = 0.016 });
        Dispatcher.emit(.{ .on_end = {} });
    }
};

// ============================================
// Test Engine Hook Dispatcher
// ============================================

pub const ENGINE_HOOK_DISPATCHER = struct {
    const TestEngineHandlers = struct {
        pub fn game_init(_: HookPayload) void {}
    };

    test "creates valid dispatcher" {
        const Dispatcher = engine.EngineHookDispatcher(TestEngineHandlers);
        try expect.toBeTrue(Dispatcher.hasHandler(.game_init));
        try expect.toBeFalse(Dispatcher.hasHandler(.game_deinit));
    }
};

pub const EMPTY_ENGINE_DISPATCHER = struct {
    test "has no handlers" {
        try expect.equal(engine.EmptyEngineDispatcher.handlerCount(), 0);
    }
};

// ============================================
// Test MergeHooks
// ============================================

const MergeHooks = hooks.MergeHooks;

// State for tracking merged handler calls
var merge_handler_a_called: bool = false;
var merge_handler_b_called: bool = false;
var merge_update_count: u32 = 0;

const MergeHandlersA = struct {
    pub fn on_start(_: TestPayload) void {
        merge_handler_a_called = true;
    }

    pub fn on_update(_: TestPayload) void {
        merge_update_count += 1;
    }
};

const MergeHandlersB = struct {
    pub fn on_start(_: TestPayload) void {
        merge_handler_b_called = true;
    }

    pub fn on_update(_: TestPayload) void {
        merge_update_count += 1;
    }

    pub fn on_end(_: TestPayload) void {
        // Handler B has on_end, Handler A doesn't
    }
};

const MergeHandlersEmpty = struct {};

pub const MERGE_HOOKS = struct {
    pub const EMIT = struct {
        test "calls handlers from both structs" {
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersA, MergeHandlersB });

            merge_handler_a_called = false;
            merge_handler_b_called = false;
            Merged.emit(.{ .on_start = {} });

            try expect.toBeTrue(merge_handler_a_called);
            try expect.toBeTrue(merge_handler_b_called);
        }

        test "calls overlapping hooks in order" {
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersA, MergeHandlersB });

            merge_update_count = 0;
            Merged.emit(.{ .on_update = 0.016 });

            // Both handlers should be called
            try expect.equal(merge_update_count, 2);
        }

        test "calls hook that only exists in one struct" {
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersA, MergeHandlersB });

            // on_end only exists in MergeHandlersB - should not crash
            Merged.emit(.{ .on_end = {} });
        }

        test "is no-op when no struct has handler" {
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersEmpty, MergeHandlersEmpty });

            // Should not crash
            Merged.emit(.{ .on_start = {} });
            Merged.emit(.{ .on_update = 0.016 });
            Merged.emit(.{ .on_end = {} });
        }
    };

    pub const HAS_HANDLER = struct {
        test "returns true if any struct has handler" {
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersA, MergeHandlersB });

            try expect.toBeTrue(Merged.hasHandler(.on_start));
            try expect.toBeTrue(Merged.hasHandler(.on_update));
            try expect.toBeTrue(Merged.hasHandler(.on_end));
        }

        test "returns false if no struct has handler" {
            // MergeHandlersA has on_start and on_update but not on_end
            const Merged = MergeHooks(TestHook, TestPayload, .{MergeHandlersA});

            try expect.toBeTrue(Merged.hasHandler(.on_start));
            try expect.toBeTrue(Merged.hasHandler(.on_update));
            try expect.toBeFalse(Merged.hasHandler(.on_end));
        }
    };

    pub const HANDLER_COUNT = struct {
        test "counts unique hooks with handlers" {
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersA, MergeHandlersB });

            // All 3 hooks have at least one handler
            try expect.equal(Merged.handlerCount(), 3);
        }

        test "does not double-count overlapping handlers" {
            // Both structs have on_start and on_update, but handlerCount counts unique hooks
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersA, MergeHandlersB });

            try expect.equal(Merged.handlerCount(), 3);
        }
    };

    pub const TOTAL_HANDLER_COUNT = struct {
        test "counts all handlers including duplicates" {
            const Merged = MergeHooks(TestHook, TestPayload, .{ MergeHandlersA, MergeHandlersB });

            // A has: on_start, on_update (2)
            // B has: on_start, on_update, on_end (3)
            // Total: 5
            try expect.equal(Merged.totalHandlerCount(), 5);
        }
    };

    pub const EMPTY_MERGE = struct {
        test "empty tuple has no handlers" {
            const Merged = MergeHooks(TestHook, TestPayload, .{});

            try expect.toBeFalse(Merged.hasHandler(.on_start));
            try expect.toBeFalse(Merged.hasHandler(.on_update));
            try expect.toBeFalse(Merged.hasHandler(.on_end));
            try expect.equal(Merged.handlerCount(), 0);
            try expect.equal(Merged.totalHandlerCount(), 0);
        }

        test "single empty struct has no handlers" {
            const Merged = MergeHooks(TestHook, TestPayload, .{MergeHandlersEmpty});

            try expect.equal(Merged.handlerCount(), 0);
        }
    };
};

pub const MERGE_ENGINE_HOOKS = struct {
    const GameHooks = struct {
        pub fn game_init(_: HookPayload) void {}
    };

    const PluginHooks = struct {
        pub fn game_init(_: HookPayload) void {}
        pub fn frame_start(_: HookPayload) void {}
    };

    test "creates valid merged dispatcher" {
        const Merged = engine.MergeEngineHooks(.{ GameHooks, PluginHooks });

        try expect.toBeTrue(Merged.hasHandler(.game_init));
        try expect.toBeTrue(Merged.hasHandler(.frame_start));
        try expect.toBeFalse(Merged.hasHandler(.game_deinit));
    }

    test "counts handlers correctly" {
        const Merged = engine.MergeEngineHooks(.{ GameHooks, PluginHooks });

        // 2 unique hooks have handlers: game_init, frame_start
        try expect.equal(Merged.handlerCount(), 2);
        // 3 total handlers: game_init (2), frame_start (1)
        try expect.equal(Merged.totalHandlerCount(), 3);
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
};
