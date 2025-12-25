//! Hook System
//!
//! A type-safe, comptime-based hook/event system for labelle-engine.
//!
//! ## Overview
//!
//! The hook system allows games to register callbacks for engine lifecycle events
//! (game init, scene load, entity created, etc.) with zero runtime overhead.
//! Plugins can also define their own hook enums and payloads.
//!
//! ## Usage
//!
//! Define a hook handler struct with functions matching hook names:
//!
//! ```zig
//! const MyHooks = struct {
//!     pub fn scene_load(payload: hooks.HookPayload) void {
//!         const info = payload.scene_load;
//!         std.log.info("Scene loaded: {s}", .{info.name});
//!     }
//!
//!     pub fn entity_created(payload: hooks.HookPayload) void {
//!         const info = payload.entity_created;
//!         std.log.info("Entity created: {d}", .{info.entity_id});
//!     }
//! };
//!
//! // Create a dispatcher
//! const Dispatcher = hooks.EngineHookDispatcher(MyHooks);
//!
//! // Emit events (typically done by the engine)
//! Dispatcher.emit(.{ .scene_load = .{ .name = "main" } });
//! ```
//!
//! ## Plugin Hooks
//!
//! Plugins can define their own hook systems:
//!
//! ```zig
//! // In your plugin
//! pub const MyPluginHook = enum {
//!     on_task_complete,
//!     on_state_change,
//! };
//!
//! pub const MyPluginPayload = union(MyPluginHook) {
//!     on_task_complete: TaskInfo,
//!     on_state_change: StateInfo,
//! };
//!
//! // Games create dispatchers for plugin hooks
//! const PluginDispatcher = hooks.HookDispatcher(
//!     MyPluginHook,
//!     MyPluginPayload,
//!     MyPluginHandlers
//! );
//! ```

const types = @import("hooks/types.zig");
const dispatcher = @import("hooks/dispatcher.zig");

// Re-export types
pub const EngineHook = types.EngineHook;
pub const HookPayload = types.HookPayload;
pub const FrameInfo = types.FrameInfo;
pub const SceneInfo = types.SceneInfo;
pub const EntityInfo = types.EntityInfo;

// Re-export dispatcher
pub const HookDispatcher = dispatcher.HookDispatcher;
pub const EmptyDispatcher = dispatcher.EmptyDispatcher;

/// Convenience type for creating an engine hook dispatcher.
/// Equivalent to `HookDispatcher(EngineHook, HookPayload, HookMap)`.
pub fn EngineHookDispatcher(comptime HookMap: type) type {
    return HookDispatcher(EngineHook, HookPayload, HookMap);
}

/// An empty engine hook dispatcher with no handlers.
/// Useful as a default when no hooks are needed.
pub const EmptyEngineDispatcher = EmptyDispatcher(EngineHook, HookPayload);

// ============================================
// Tests
// ============================================

test "hooks module exports all types" {
    _ = EngineHook.game_init;
    _ = EngineHook.scene_load;
    _ = EngineHook.entity_created;

    const payload: HookPayload = .{ .game_init = {} };
    _ = payload;

    const frame_info = FrameInfo{ .frame_number = 1, .dt = 0.016 };
    _ = frame_info;

    const scene_info = SceneInfo{ .name = "test" };
    _ = scene_info;

    const entity_info = EntityInfo{ .entity_id = 42 };
    _ = entity_info;
}

test "EngineHookDispatcher creates valid dispatcher" {
    const TestHandlers = struct {
        pub fn game_init(_: HookPayload) void {}
    };

    const Dispatcher = EngineHookDispatcher(TestHandlers);
    try @import("std").testing.expect(Dispatcher.hasHandler(.game_init));
    try @import("std").testing.expect(!Dispatcher.hasHandler(.game_deinit));
}

test "EmptyEngineDispatcher has no handlers" {
    try @import("std").testing.expectEqual(0, EmptyEngineDispatcher.handlerCount());
}

test {
    // Run all submodule tests
    _ = types;
    _ = dispatcher;
}
