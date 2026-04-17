//! Hook Types
//!
//! Rich hook payload union for engine lifecycle events.
//! Extends the basic EngineHookPayload from labelle-core with
//! scene lifecycle and component lifecycle hooks.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Full hook payload union for the engine.
/// Games can use this with HookDispatcher for rich lifecycle events.
pub fn HookPayload(comptime Entity: type) type {
    return union(enum) {
        // Game lifecycle
        game_init: GameInitInfo,
        game_deinit: void,
        frame_start: FrameInfo,
        frame_end: FrameInfo,

        // Scene lifecycle
        scene_before_load: SceneBeforeLoadInfo,
        scene_load: SceneInfo,
        scene_unload: SceneInfo,
        scene_assets_acquire: SceneAssetsInfo,
        scene_assets_release: SceneAssetsInfo,

        // State lifecycle
        state_before_change: StateChangeInfo,
        state_after_change: StateChangeInfo,

        // Entity lifecycle
        entity_created: EntityInfo(Entity),
        entity_destroyed: EntityInfo(Entity),
    };
}

pub const GameInitInfo = struct {
    allocator: Allocator,
};

pub const FrameInfo = struct {
    frame_number: u64 = 0,
    dt: f32 = 0,
};

pub const SceneBeforeLoadInfo = struct {
    name: []const u8,
    allocator: Allocator,
};

pub const SceneInfo = struct {
    name: []const u8,
};

/// Payload for `scene_assets_acquire` / `scene_assets_release`. `assets`
/// is the manifest attached to the scene entry — listeners can read it
/// without a `scenes.get(name)` lookup. Slice lifetime matches the
/// `SceneEntry.assets` slice (program-lifetime when populated by the
/// assembler).
pub const SceneAssetsInfo = struct {
    name: []const u8,
    assets: []const []const u8,
};

pub const StateChangeInfo = struct {
    old_state: []const u8,
    new_state: []const u8,
};

pub fn EntityInfo(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
        prefab_name: ?[]const u8 = null,
    };
}

/// Payload for component lifecycle callbacks (onAdd, onSet, onRemove).
pub const ComponentPayload = struct {
    entity_id: u64,
    game_ptr: *anyopaque,

    pub fn getGame(self: ComponentPayload, comptime GameType: type) *GameType {
        return @ptrCast(@alignCast(self.game_ptr));
    }
};
