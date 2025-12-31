//! Scene Module - Declarative scene and prefab system
//!
//! This module provides the scene loading system:
//! - SceneLoader: Loads scenes from comptime .zon files
//! - PrefabRegistry: Comptime prefab templates
//! - ComponentRegistry: Maps component names to types
//! - ScriptRegistry: Maps script names to lifecycle functions
//! - Scene, SceneContext, EntityInstance: Runtime scene types

pub const loader = @import("loader.zig");
pub const prefab = @import("prefab.zig");
pub const component = @import("component.zig");
pub const script = @import("script.zig");
pub const core = @import("core.zig");

// Loader exports
pub const SceneLoader = loader.SceneLoader;
pub const SceneCameraConfig = loader.SceneCameraConfig;
pub const CameraSlot = loader.CameraSlot;

// Prefab exports
pub const PrefabRegistry = prefab.PrefabRegistry;
pub const SpriteConfig = prefab.SpriteConfig;
pub const ZIndex = prefab.ZIndex;
pub const Pivot = prefab.Pivot;
pub const Layer = prefab.Layer;
pub const SizeMode = prefab.SizeMode;
pub const Container = prefab.Container;

// Component exports
pub const ComponentRegistry = component.ComponentRegistry;
pub const ComponentRegistryMulti = component.ComponentRegistryMulti;

// Script exports
pub const ScriptRegistry = script.ScriptRegistry;
pub const ScriptFns = script.ScriptFns;
pub const InitFn = script.InitFn;
pub const UpdateFn = script.UpdateFn;
pub const DeinitFn = script.DeinitFn;

// Scene types (from core.zig)
pub const Scene = core.Scene;
pub const SceneContext = core.SceneContext;
pub const EntityInstance = core.EntityInstance;
pub const Entity = core.Entity;
pub const Game = core.Game;
