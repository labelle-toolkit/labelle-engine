pub const dispatcher = @import("dispatcher.zig");
pub const ecs = @import("ecs.zig");
pub const component = @import("component.zig");
pub const context = @import("context.zig");

// Re-exports
pub const HookDispatcher = dispatcher.HookDispatcher;
pub const MergeHooks = dispatcher.MergeHooks;
pub const Ecs = ecs.Ecs;
pub const MockEcsBackend = ecs.MockEcsBackend;
pub const ComponentPayload = component.ComponentPayload;
pub const PluginContext = context.PluginContext;
pub const TestContext = context.TestContext;
pub const RecordingHooks = context.RecordingHooks;

/// Standard engine lifecycle events — parameterized by Entity type.
pub fn EngineHookPayload(comptime Entity: type) type {
    return union(enum) {
        game_init: GameInitInfo,
        game_deinit: void,
        frame_start: FrameInfo,
        frame_end: FrameInfo,
        scene_load: SceneInfo,
        scene_unload: SceneInfo,
        entity_created: EntityInfo(Entity),
        entity_destroyed: EntityInfo(Entity),
    };
}

pub const GameInitInfo = struct {
    allocator: *const anyopaque, // simplified — real one would be std.mem.Allocator
};

pub const FrameInfo = struct {
    frame_number: u64,
    dt: f32,
};

pub const SceneInfo = struct {
    name: []const u8,
};

pub fn EntityInfo(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
        prefab_name: ?[]const u8 = null,
    };
}
