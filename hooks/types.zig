//! Hook Types
//!
//! Defines the core hook enum and payload union for engine lifecycle events.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Type-safe payload union for engine hooks.
/// Each hook type has its corresponding payload type.
pub const HookPayload = union(enum) {
    // Game lifecycle
    game_init: GameInitInfo,
    game_deinit: void,
    frame_start: FrameInfo,
    frame_end: FrameInfo,

    // Scene lifecycle
    scene_before_load: SceneBeforeLoadInfo,
    scene_load: SceneInfo,
    scene_unload: SceneInfo,

    // Entity lifecycle
    entity_created: EntityInfo,
    entity_destroyed: EntityInfo,
};

/// Built-in hooks for engine lifecycle events — derived from HookPayload.
pub const EngineHook = std.meta.Tag(HookPayload);

/// Game initialization info passed to game_init hook.
pub const GameInitInfo = struct {
    /// The allocator used by the game, available for initializing subsystems.
    allocator: Allocator,
};

/// Frame timing information.
pub const FrameInfo = struct {
    /// Current frame number since game start.
    frame_number: u64 = 0,
    /// Delta time for this frame in seconds.
    dt: f32 = 0,
};

/// Scene before load information.
/// Passed to scene_before_load hook before entities are created.
pub const SceneBeforeLoadInfo = struct {
    /// Name of the scene about to be loaded.
    name: []const u8,
    /// The allocator used by the game, available for initializing scene-scoped subsystems.
    allocator: Allocator,
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

/// Payload for component lifecycle callbacks (onAdd, onSet, onRemove).
/// Components can define these callbacks directly on their struct to react
/// to lifecycle events.
pub const ComponentPayload = struct {
    /// The entity ID (as u64 for backend compatibility with zig_ecs/zflecs).
    /// Use `engine.entityFromU64()` to convert to Entity type.
    entity_id: u64,

    /// Opaque pointer to the Game instance.
    /// Use `getGame()` to get a typed pointer.
    game_ptr: *anyopaque,

    /// Get a typed pointer to the Game instance.
    /// Usage: `const game = payload.getGame(Game);`
    pub fn getGame(self: ComponentPayload, comptime GameType: type) *GameType {
        return @ptrCast(@alignCast(self.game_ptr));
    }
};
