//! labelle-engine - 2D game engine for Zig
//!
//! Import submodules directly for namespaced access:
//! ```zig
//! const labelle = @import("labelle-engine");
//! const Game = labelle.engine.Game;
//! const Position = labelle.render.Position;
//! const SceneLoader = labelle.scene.SceneLoader;
//! ```

const std = @import("std");
const labelle_gfx = @import("labelle");
const build_options = @import("build_options");

// Core submodules
pub const core = @import("core/mod.zig");
pub const ecs = @import("ecs");
pub const input = @import("input");
pub const audio = @import("audio");
pub const hooks = @import("hooks/mod.zig");
pub const render = @import("render/mod.zig");
pub const scene = @import("scene/mod.zig");
pub const engine = @import("engine/mod.zig");

// Submodule aliases (for direct access)
pub const loader = scene.loader;
pub const prefab = scene.prefab;
pub const script = scene.script;
pub const component = scene.component;
pub const zon_coercion = core.zon;
pub const scene_mod = scene;

// Build configuration
pub const build_helpers = @import("build_helpers.zig");
pub const project_config = @import("tools/project_config.zig");
pub const generator = @import("tools/generator.zig");
pub const ProjectConfig = project_config.ProjectConfig;

// Re-export build options
pub const Backend = build_options.backend;

// Re-export graphics types from labelle-gfx
pub const Camera = labelle_gfx.Camera;
pub const CameraManager = labelle_gfx.CameraManager;
pub const SplitScreenLayout = labelle_gfx.SplitScreenLayout;

// Low-level graphics backends (for direct access when needed)
pub const SokolBackend = labelle_gfx.SokolBackend;
pub const RaylibBackend = labelle_gfx.RaylibBackend;

// Convenience re-exports for common types
pub const Game = engine.Game;
pub const GameWith = engine.GameWith;
pub const GameConfig = engine.GameConfig;
pub const WindowConfig = engine.WindowConfig;
pub const ScreenSize = engine.ScreenSize;
pub const SceneLoader = scene.SceneLoader;
pub const PrefabRegistry = scene.PrefabRegistry;
pub const ComponentRegistry = scene.ComponentRegistry;
pub const ComponentRegistryMulti = scene.ComponentRegistryMulti;
pub const ScriptRegistry = scene.ScriptRegistry;

// Core entity utilities
pub const Entity = core.Entity;
pub const entityToU64 = core.entityToU64;
pub const entityFromU64 = core.entityFromU64;

// Render types
pub const Position = render.Position;
pub const Sprite = render.Sprite;
pub const Shape = render.Shape;
pub const Text = render.Text;
pub const Color = render.Color;
pub const Layer = render.Layer;
pub const SizeMode = render.SizeMode;
pub const Container = render.Container;
pub const RenderPipeline = render.RenderPipeline;
pub const RetainedEngine = render.RetainedEngine;
pub const TextureId = render.TextureId;
pub const FontId = render.FontId;
pub const VisualType = render.VisualType;
pub const LayerConfig = render.LayerConfig;
pub const LayerSpace = render.LayerSpace;

// ECS types
pub const Registry = @import("ecs").Registry;

// Scene types
pub const Scene = scene.Scene;
pub const SceneContext = scene.SceneContext;
pub const EntityInstance = scene.EntityInstance;
pub const SpriteConfig = scene.SpriteConfig;
pub const ZIndex = scene.ZIndex;
pub const Pivot = scene.Pivot;

// Hooks
pub const HookDispatcher = hooks.HookDispatcher;
pub const MergeEngineHooks = hooks.MergeEngineHooks;
pub const MergeHooks = hooks.MergeHooks;
pub const HookPayload = hooks.HookPayload;
pub const EngineHook = hooks.EngineHook;
pub const EngineHookDispatcher = hooks.EngineHookDispatcher;
pub const EmptyEngineDispatcher = hooks.EmptyEngineDispatcher;
pub const GameInitInfo = hooks.GameInitInfo;
pub const SceneBeforeLoadInfo = hooks.SceneBeforeLoadInfo;
pub const SceneInfo = hooks.SceneInfo;
pub const EntityInfo = hooks.EntityInfo;
pub const FrameInfo = hooks.FrameInfo;
pub const ComponentPayload = hooks.ComponentPayload;

// Input types
pub const Input = input.Input;
pub const KeyboardKey = input.KeyboardKey;
pub const MouseButton = input.MouseButton;
pub const MousePosition = input.MousePosition;

// Audio types
pub const Audio = audio.Audio;
pub const SoundId = audio.SoundId;
pub const MusicId = audio.MusicId;
pub const AudioError = audio.AudioError;

/// Built-in component types for .zon prefab/scene files.
pub const BuiltinComponents = struct {
    pub const Position = render.Position;
    pub const Sprite = render.Sprite;
    pub const Shape = render.Shape;
    pub const Text = render.Text;
};
