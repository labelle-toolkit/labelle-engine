//! Hook System - Thin wrapper for backward compatibility
//!
//! See hooks/mod.zig for full documentation.
//! This file re-exports everything from the hooks module for compatibility
//! with existing imports like `@import("hooks.zig")`.

const mod = @import("hooks/mod.zig");

// Re-export everything from the module
pub const EngineHook = mod.EngineHook;
pub const HookPayload = mod.HookPayload;
pub const FrameInfo = mod.FrameInfo;
pub const SceneInfo = mod.SceneInfo;
pub const SceneBeforeLoadInfo = mod.SceneBeforeLoadInfo;
pub const EntityInfo = mod.EntityInfo;
pub const ComponentPayload = mod.ComponentPayload;
pub const GameInitInfo = mod.GameInitInfo;

pub const HookDispatcher = mod.HookDispatcher;
pub const EmptyDispatcher = mod.EmptyDispatcher;
pub const MergeHooks = mod.MergeHooks;

pub const EngineHookDispatcher = mod.EngineHookDispatcher;
pub const MergeEngineHooks = mod.MergeEngineHooks;
pub const EmptyEngineDispatcher = mod.EmptyEngineDispatcher;
