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
pub const gui = @import("gui");
pub const graphics = @import("graphics");
pub const hooks = @import("hooks/mod.zig");
pub const gui_hooks = @import("hooks/gui/mod.zig");
pub const render = @import("render/mod.zig");
pub const scene = @import("scene/src/root.zig");
pub const engine = @import("engine/mod.zig");

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
pub const RenderComponents = render.Components;

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
pub const Touch = input.Touch;
pub const TouchPhase = input.TouchPhase;
pub const MAX_TOUCHES = input.MAX_TOUCHES;

// Audio types
pub const Audio = audio.Audio;
pub const SoundId = audio.SoundId;
pub const MusicId = audio.MusicId;
pub const AudioError = audio.AudioError;

// GUI types
pub const Gui = gui.Gui;
pub const GuiBackend = gui.GuiBackend;
pub const GuiElement = gui.GuiElement;
pub const ViewRegistry = gui.ViewRegistry;
pub const ViewDef = gui.ViewDef;
pub const FormBinder = gui.FormBinder;
pub const VisibilityState = gui.VisibilityState;
pub const ValueState = gui.ValueState;

/// Built-in component types for .zon prefab/scene files.
pub const BuiltinComponents = struct {
    pub const Position = render.Position;
    pub const Sprite = render.Sprite;
    pub const Shape = render.Shape;
    pub const Text = render.Text;
};

// Physics types (conditionally exported when physics is enabled)
pub const physics_enabled = build_options.physics_enabled;

pub const physics = if (build_options.physics_enabled)
    @import("physics")
else
    struct {};

/// Physics component types, available when physics is enabled (-Dphysics=true).
/// Use BuiltinComponentsWithPhysics to automatically include these in your ComponentRegistry.
pub const PhysicsComponents = if (build_options.physics_enabled)
    struct {
        pub const RigidBody = physics.RigidBody;
        pub const Collider = physics.Collider;
        pub const Velocity = physics.Velocity;
        pub const Touching = physics.Touching;
    }
else
    struct {};

/// Built-in components including physics types when physics is enabled.
/// Use this with ComponentRegistry or ComponentRegistryMulti to automatically
/// have all engine components available without manual imports.
pub const BuiltinComponentsWithPhysics = if (build_options.physics_enabled)
    struct {
        // Render components (from BuiltinComponents)
        pub const Position = BuiltinComponents.Position;
        pub const Sprite = BuiltinComponents.Sprite;
        pub const Shape = BuiltinComponents.Shape;
        pub const Text = BuiltinComponents.Text;
        // Physics components (from PhysicsComponents)
        pub const RigidBody = PhysicsComponents.RigidBody;
        pub const Collider = PhysicsComponents.Collider;
        pub const Velocity = PhysicsComponents.Velocity;
        pub const Touching = PhysicsComponents.Touching;
    }
else
    BuiltinComponents;
