//! Hook Types
//!
//! Defines the core hook enum and payload union for engine lifecycle events.

const std = @import("std");

/// Built-in hooks for engine lifecycle events.
/// Games can register handlers for any of these hooks.
pub const EngineHook = enum {
    // Game lifecycle
    game_init,
    game_deinit,
    frame_start,
    frame_end,

    // Scene lifecycle
    scene_load,
    scene_unload,

    // Entity lifecycle
    entity_created,
    entity_destroyed,
};

/// Frame timing information.
pub const FrameInfo = struct {
    /// Current frame number since game start.
    frame_number: u64 = 0,
    /// Delta time for this frame in seconds.
    dt: f32 = 0,
};

/// Scene information for scene lifecycle hooks.
pub const SceneInfo = struct {
    /// Name of the scene.
    name: []const u8,
};

/// Entity information for entity lifecycle hooks.
pub const EntityInfo = struct {
    /// The entity ID (as u64 for backend compatibility with zig_ecs/zflecs).
    /// Use `engine.entityFromU64()` / `engine.entityToU64()` to convert.
    entity_id: u64,
    /// Name of the prefab used to create this entity, if any.
    prefab_name: ?[]const u8 = null,
};

/// Type-safe payload union for engine hooks.
/// Each hook type has its corresponding payload type.
pub const HookPayload = union(EngineHook) {
    game_init: void,
    game_deinit: void,
    frame_start: FrameInfo,
    frame_end: FrameInfo,

    scene_load: SceneInfo,
    scene_unload: SceneInfo,

    entity_created: EntityInfo,
    entity_destroyed: EntityInfo,
};
