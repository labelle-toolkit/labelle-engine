//! Hook System Module
//!
//! A type-safe, comptime-based hook/event system for labelle-engine.
//!
//! Uses the receiver-based dispatcher pattern from labelle-core:
//! handlers are methods on a receiver struct (with `self` parameter),
//! enabling stateful hooks and comptime typo detection.
//!
//! ## Usage
//!
//! Define a hook handler struct with methods matching hook names:
//!
//! ```zig
//! const MyHooks = struct {
//!     pub fn scene_load(_: @This(), info: engine.SceneInfo) void {
//!         std.log.info("Scene loaded: {s}", .{info.name});
//!     }
//!
//!     pub fn entity_created(_: @This(), info: engine.EntityInfo) void {
//!         std.log.info("Entity created: {d}", .{info.entity_id});
//!     }
//! };
//!
//! // Create a dispatcher
//! const Dispatcher = hooks.EngineHookDispatcher(MyHooks);
//! const d = Dispatcher{ .receiver = .{} };
//! d.emit(.{ .scene_load = .{ .name = "main" } });
//! ```

const types = @import("types.zig");
const dispatcher = @import("dispatcher.zig");

// Re-export types
pub const EngineHook = types.EngineHook;
pub const HookPayload = types.HookPayload;
pub const FrameInfo = types.FrameInfo;
pub const SceneInfo = types.SceneInfo;
pub const SceneBeforeLoadInfo = types.SceneBeforeLoadInfo;
pub const EntityInfo = types.EntityInfo;
pub const ComponentPayload = types.ComponentPayload;
pub const GameInitInfo = types.GameInitInfo;

// Re-export dispatcher
pub const HookDispatcher = dispatcher.HookDispatcher;
pub const MergeHooks = dispatcher.MergeHooks;
pub const UnwrapReceiver = dispatcher.UnwrapReceiver;

/// Convenience type for creating an engine hook dispatcher.
/// Equivalent to `HookDispatcher(HookPayload, Receiver, .{})`.
pub fn EngineHookDispatcher(comptime Receiver: type) type {
    return HookDispatcher(HookPayload, Receiver, .{});
}

/// Convenience type for merging multiple engine hook receiver types.
/// Equivalent to `MergeHooks(HookPayload, receiver_types)`.
///
/// Example:
/// ```zig
/// const AllHooks = MergeEngineHooks(.{ GameHooks, PluginHooks });
/// ```
pub fn MergeEngineHooks(comptime receiver_types: anytype) type {
    return MergeHooks(HookPayload, receiver_types);
}

/// An empty engine hook dispatcher with no handlers.
/// Useful as a default when no hooks are needed.
pub const EmptyEngineDispatcher = EngineHookDispatcher(struct {});
