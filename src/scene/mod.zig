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

// Re-export from parent scene.zig for Scene, SceneContext, EntityInstance
// These types have complex dependencies and remain in the parent module
const scene_types = @import("../scene.zig");

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
pub const Game = script.Game;

// Scene types (from parent module)
pub const Scene = scene_types.Scene;
pub const SceneContext = scene_types.SceneContext;
pub const EntityInstance = scene_types.EntityInstance;
