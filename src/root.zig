const std = @import("std");

pub const core = @import("labelle-core");

// Engine modules
pub const game_mod = @import("game.zig");
pub const game_log_mod = @import("game_log.zig");
pub const input_mod = @import("input.zig");
pub const audio_mod = @import("audio.zig");
pub const gui_mod = @import("gui.zig");
pub const gui_runtime_state_mod = @import("gui_runtime_state.zig");
pub const form_binder_mod = @import("form_binder.zig");
pub const scene_mod = @import("scene.zig");
pub const script_runner_mod = @import("script_runner.zig");
pub const gestures_mod = @import("gestures.zig");
pub const sparse_set_mod = @import("sparse_set.zig");
pub const query_mod = @import("query.zig");
pub const hooks_types_mod = @import("hooks_types.zig");
pub const animation_mod = @import("animation.zig");
pub const animation_def_mod = @import("animation_def.zig");
pub const animation_state_mod = @import("animation_state.zig");
pub const atlas_mod = @import("atlas.zig");
pub const jsonc_mod = @import("jsonc");

// ── Game ──
pub const GameConfig = game_mod.GameConfig;
pub const GameLog = game_log_mod.GameLog;
pub const StubLogSink = core.StubLogSink;
pub const StderrLogSink = core.StderrLogSink;
pub const GameWith = game_mod.GameWith;
pub const Game = game_mod.Game;

// ── Input ──
pub const InputInterface = input_mod.InputInterface;
pub const StubInput = input_mod.StubInput;
pub const KeyboardKey = input_mod.KeyboardKey;
pub const MouseButton = input_mod.MouseButton;
pub const MousePosition = input_mod.MousePosition;
pub const Touch = input_mod.Touch;
pub const TouchPhase = input_mod.TouchPhase;
pub const MAX_TOUCHES = input_mod.MAX_TOUCHES;
pub const GamepadButton = input_mod.GamepadButton;
pub const GamepadAxis = input_mod.GamepadAxis;
pub const Gestures = input_mod.Gestures;
pub const SwipeDirection = input_mod.SwipeDirection;
pub const Pinch = input_mod.Pinch;
pub const Pan = input_mod.Pan;
pub const Swipe = input_mod.Swipe;
pub const Tap = input_mod.Tap;
pub const DoubleTap = input_mod.DoubleTap;
pub const LongPress = input_mod.LongPress;
pub const Rotation = input_mod.Rotation;

// ── Audio ──
pub const AudioInterface = audio_mod.AudioInterface;
pub const StubAudio = audio_mod.StubAudio;
pub const SoundId = audio_mod.SoundId;
pub const MusicId = audio_mod.MusicId;
pub const AudioError = audio_mod.AudioError;

// ── GUI ──
pub const GuiInterface = gui_mod.GuiInterface;
pub const StubGui = gui_mod.StubGui;
pub const GuiColor = gui_mod.GuiColor;
pub const GuiPosition = gui_mod.GuiPosition;
pub const GuiSize = gui_mod.GuiSize;
pub const Label = gui_mod.Label;
pub const Button = gui_mod.Button;
pub const ProgressBar = gui_mod.ProgressBar;
pub const Panel = gui_mod.Panel;
pub const GuiImage = gui_mod.Image;
pub const GuiCheckbox = gui_mod.Checkbox;
pub const GuiSlider = gui_mod.Slider;
pub const GuiElement = gui_mod.GuiElement;
pub const ViewDef = gui_mod.ViewDef;
pub const ViewRegistry = gui_mod.ViewRegistry;
pub const EmptyViewRegistry = gui_mod.EmptyViewRegistry;
pub const VisibilityState = gui_runtime_state_mod.VisibilityState;
pub const ValueState = gui_runtime_state_mod.ValueState;
pub const FormBinder = form_binder_mod.FormBinder;
pub const GuiEvent = form_binder_mod.GuiEvent;

// ── Core Utilities ──
pub const SparseSet = sparse_set_mod.SparseSet;
pub const separateComponents = query_mod.separateComponents;
pub const CallbackType = query_mod.CallbackType;

// ── Hook Types ──
pub const HookPayload = hooks_types_mod.HookPayload;
pub const GameInitInfo = hooks_types_mod.GameInitInfo;
pub const FrameInfo = hooks_types_mod.FrameInfo;
pub const SceneBeforeLoadInfo = hooks_types_mod.SceneBeforeLoadInfo;
pub const SceneInfo = hooks_types_mod.SceneInfo;
pub const StateChangeInfo = hooks_types_mod.StateChangeInfo;
pub const EntityInfo = hooks_types_mod.EntityInfo;
pub const ComponentPayload = hooks_types_mod.ComponentPayload;

// ── Hook Dispatcher ──
pub const MergeHooks = core.MergeHooks;
pub const MergeHookPayloads = core.MergeHookPayloads;

// ── Scene System ──
pub const Scene = scene_mod.Scene;
pub const PrefabRegistry = scene_mod.PrefabRegistry;
pub const ComponentRegistry = scene_mod.ComponentRegistry;
pub const ComponentRegistryMulti = scene_mod.ComponentRegistryMulti;
pub const ComponentRegistryWithPlugins = scene_mod.ComponentRegistryWithPlugins;
pub const ScriptRegistry = scene_mod.ScriptRegistry;
pub const ScriptFns = scene_mod.ScriptFns;
pub const GizmoRegistry = scene_mod.GizmoRegistry;
pub const NoGizmos = scene_mod.NoGizmos;
pub const NoScripts = scene_mod.NoScripts;
pub const ScriptRunner = script_runner_mod.ScriptRunner;
pub const SystemRegistry = scene_mod.SystemRegistry;
pub const ReferenceContext = scene_mod.ReferenceContext;

// ── Animation ──
pub const Animation = animation_mod.Animation;
pub const AnimConfig = animation_mod.AnimConfig;
pub const DefaultAnimationType = animation_mod.DefaultAnimationType;
pub const AnimationDef = animation_def_mod.AnimationDef;
pub const AnimationState = animation_state_mod.AnimationState;
pub const AnimMode = animation_def_mod.Mode;
pub const AnimClipMeta = animation_def_mod.ClipMeta;

// ── Atlas ──
pub const SpriteData = atlas_mod.SpriteData;
pub const FindSpriteResult = atlas_mod.FindSpriteResult;
pub const ComptimeAtlas = atlas_mod.ComptimeAtlas;
pub const RuntimeAtlas = atlas_mod.RuntimeAtlas;
pub const TextureManager = atlas_mod.TextureManager;
pub const SpriteCache = atlas_mod.SpriteCache;

// ── JSONC Scene Bridge ──
pub const JsoncSceneBridge = @import("jsonc_scene_bridge.zig").JsoncSceneBridge;
pub const JsoncSceneBridgeWithGizmos = @import("jsonc_scene_bridge.zig").JsoncSceneBridgeWithGizmos;

// ── Scene Value & JSONC Parser ──
pub const SceneValue = jsonc_mod.Value;
pub const JsoncParser = jsonc_mod.JsoncParser;
pub const JsoncParseError = jsonc_mod.ParseError;
pub const HotReloader = jsonc_mod.HotReloader;

// ── Core Re-exports ──
pub const Position = core.Position;
pub const Ecs = core.Ecs;
pub const MockEcsBackend = core.MockEcsBackend;
pub const HookDispatcher = core.HookDispatcher;
pub const VisualType = core.VisualType;
pub const RenderInterface = core.RenderInterface;
pub const StubRender = core.StubRender;
pub const ParentComponent = core.ParentComponent;
pub const ChildrenComponent = core.ChildrenComponent;
pub const GizmoInterface = core.GizmoInterface;
pub const StubGizmos = core.StubGizmos;
pub const PhysicsInterface = core.PhysicsInterface;
pub const StubPhysics = core.StubPhysics;

