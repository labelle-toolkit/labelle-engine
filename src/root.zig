const std = @import("std");

pub const core = @import("labelle-core");

// Engine modules
pub const game_mod = @import("game.zig");
pub const game_log_mod = @import("game_log.zig");
pub const input_mod = @import("input.zig");
pub const audio_mod = @import("audio.zig");
pub const font_types_mod = @import("font_types");
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
pub const sprite_animation_mod = @import("sprite_animation.zig");
pub const sprite_animation_tick_mod = @import("sprite_animation_tick.zig");
pub const sprite_by_field_mod = @import("sprite_by_field.zig");
pub const sprite_by_field_tick_mod = @import("sprite_by_field_tick.zig");
pub const atlas_mod = @import("atlas.zig");
pub const assets_mod = @import("assets/mod.zig");
pub const preview_mode_mod = @import("preview_mode.zig");
pub const preview_capture_mod = @import("preview_capture.zig");
pub const screenshot_request_mod = @import("screenshot_request.zig");
pub const jsonc_mod = @import("jsonc");

// ── Android runtime helpers ──
// Immersive-mode (hide system bars) lives here; see src/android.zig
// for the JNI / UI-thread rationale. Reached from the assembler-
// generated Android `main.zig` as `engine.android.enableImmersiveMode`.
pub const android = @import("android.zig");

// ── Runtime-env hooks (cli#229) ──
// `engine.requestedScene()` reads the `LABELLE_SCENE` env var the cli
// sets when invoked with `labelle run --scene=<name>`. Loading
// controllers should consume this AFTER `assets.allReady` succeeds, so
// asset streaming for large scenes doesn't race the boot swap.
pub const runtime_env = @import("runtime_env.zig");
pub const requestedScene = runtime_env.requestedScene;

// ── Game ──
pub const GameConfig = game_mod.GameConfig;
/// Y-axis-aware game configuration — `GameConfig` plus an explicit trailing
/// `core.YAxis` slot. The assembler adopts this once it parses `.y_axis`
/// from `project.labelle` (labelle-engine#639 / #370). See `game.zig`.
pub const GameConfigWithYAxis = game_mod.GameConfigWithYAxis;
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
pub const VideoInterface = core.VideoInterface;
pub const StubVideo = core.StubVideo;
pub const SoundId = audio_mod.SoundId;
pub const MusicId = audio_mod.MusicId;
pub const AudioError = audio_mod.AudioError;
/// Runtime backend hook for the audio asset loader. The assembler
/// populates this at `Game.init` via `AudioLoader.setBackend(...)`
/// with adapters that forward to the chosen audio backend's
/// `decode` (dr_wav / stb_vorbis) / `upload` / `unload` calls. See
/// `src/assets/loaders/audio.zig` for the full rationale.
pub const AudioLoader = assets_mod.audio_loader;
pub const AudioBackend = assets_mod.audio_loader.AudioBackend;
pub const DecodedAudio = assets_mod.audio_loader.DecodedAudio;

// ── Fonts ──
pub const FontId = font_types_mod.FontId;
pub const Glyph = font_types_mod.Glyph;
pub const CodepointEntry = font_types_mod.CodepointEntry;
pub const KernPair = font_types_mod.KernPair;
/// Runtime backend hook for the font asset loader, paired with the
/// `FontBakeParams` / `CodepointRange` shapes the catalog stores on
/// each font entry and forwards into `decode` via `WorkRequest.params`.
/// See `src/assets/loaders/font.zig` for the full ownership contract.
pub const FontLoader = assets_mod.font_loader;
pub const FontBackend = assets_mod.font_loader.FontBackend;
pub const FontBakeParams = assets_mod.font_loader.FontBakeParams;
pub const CodepointRange = assets_mod.font_loader.CodepointRange;
pub const DecodedFont = assets_mod.font_loader.DecodedFont;

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

// ── Engine Lifecycle Events (RFC-FLOW-VOCABULARY phase 6, #578) ──
//
// `pub const Events` is the assembler-discoverable side of the
// engine's lifecycle hooks — same `Events` convention plugins use
// (RFC-PLUGIN-EVENTS phase 1), but on the engine itself so flows can
// listen to `engine.tick`, `engine.entity_created`, etc. as Event-node
// variants under one model.
//
// Each variant mirrors a variant on the closed `HookPayload` union
// (the in-process lifecycle dispatch that's been live since
// labelle-engine#422). The assembler folds these into the project's
// merged `PluginEvents` union with qualified tags `engine__<event>`,
// alongside true plugin events like `box2d__collision_begin`.
//
// Payload shapes:
//   - Entity-typed fields use `u32` — same convention as box2d's
//     `Events.collision_begin`. The `entity_id` matches the
//     `Game.EntityType` of `u32`-backed ECS backends (the toolkit
//     default); games that override the entity type are responsible
//     for the cast at the emit site (the engine's tolerant
//     `emit` helper widens through `@intCast`).
//   - Scene-name strings use `[]const u8`, borrowed from the engine
//     scene registry (program-lifetime for assembler-generated
//     entries, allocator-owned for runtime registrations).
//   - `dt` mirrors `FrameInfo.dt` — scaled by `time_scale`, in seconds.
//
// Variant set kept in lockstep with `HookPayload` in
// `hooks_types.zig`; reference comments below point at the source
// hook for each.
pub const Events = struct {
    /// Fired when `Game.init` completes and hooks have been wired
    /// (mirrors `HookPayload.game_init`). `Allocator` is not threaded
    /// through because the on-disk Event-node form doesn't carry
    /// non-POD payload types — listeners that need an allocator should
    /// reach `game.allocator` directly.
    pub const game_init = struct {};

    /// Fired at `Game.deinit` start (mirrors `HookPayload.game_deinit`).
    pub const game_deinit = struct {};

    /// Fired at the top of `Game.tick`, before active-scene + script
    /// `tick`s run. Equivalent to `HookPayload.frame_start`. `dt` is
    /// already scaled by `time_scale`.
    pub const tick = struct {
        frame_number: u64 = 0,
        dt: f32 = 0,
    };

    /// Fired at the bottom of `Game.tick`, after active-scene + script
    /// `tick`s. Mirrors `HookPayload.frame_end`. Same `dt` value the
    /// matching `tick` event fired with.
    pub const post_tick = struct {
        frame_number: u64 = 0,
        dt: f32 = 0,
    };

    /// Fired when the ECS façade creates an entity. Mirrors
    /// `HookPayload.entity_created`. Entity IDs above the u32 range
    /// are clipped — the engine's on-disk catalog convention assumes
    /// u32-backed entity IDs (see RFC-PLUGIN-EVENTS phase 3 resolver).
    pub const entity_created = struct {
        entity: u32,
    };

    /// Fired when the ECS façade destroys an entity (or when an
    /// entity is uprooted via `destroyEntityOnly`). Mirrors
    /// `HookPayload.entity_destroyed`.
    pub const entity_destroyed = struct {
        entity: u32,
    };

    /// Fired once when a play-once `VideoComponent` (loop = false) reaches the
    /// end of its clip — emitted by the engine's video system (FP#549), not the
    /// in-process hook path. Wire a flow/script to `engine__video_finished` to
    /// transition the scene when an intro ends. `entity` is the video entity;
    /// `path` is its (borrowed, scene-lifetime) resource name.
    pub const video_finished = struct {
        entity: u32,
        path: []const u8,
    };

    /// Fired just before a scene's loader runs (assets are already
    /// `.ready` by the manifest gate). Mirrors
    /// `HookPayload.scene_before_load`. `Allocator` is omitted here
    /// for the same reason as `game_init`.
    pub const scene_loading = struct {
        name: []const u8,
    };

    /// Fired after the new scene's loader returns and the scene is
    /// active. Mirrors `HookPayload.scene_load`.
    pub const scene_loaded = struct {
        name: []const u8,
    };

    /// Fired during `unloadCurrentScene`, just before the outgoing
    /// scene's entities are destroyed. Mirrors
    /// `HookPayload.scene_unload`.
    pub const scene_unloaded = struct {
        name: []const u8,
    };

    /// Fired before a `setSceneAtomic` wipes the world clean.
    /// Mirrors `HookPayload.scene_before_reset`. Carries the
    /// outgoing scene's name (game-supplied or `"unknown"` when the
    /// previous scene was unnamed).
    pub const scene_before_reset = struct {
        name: []const u8,
    };

    /// Fired when an `asset_manifest`-bearing scene's assets are
    /// acquired by `setScene` / `setSceneAtomic`. Mirrors
    /// `HookPayload.scene_assets_acquire`. The `assets` slice is the
    /// scene-entry manifest (program-lifetime for assembler-emitted
    /// scenes); listeners must not retain a pointer past the next
    /// scene swap.
    pub const scene_assets_acquire = struct {
        name: []const u8,
    };

    /// Fired when the engine drops its acquire on the outgoing
    /// scene's manifest. Mirrors `HookPayload.scene_assets_release`.
    pub const scene_assets_release = struct {
        name: []const u8,
    };

    /// Fired by `Game.setState` after a real state transition.
    /// Mirrors `HookPayload.state_after_change`. `old_state` is the
    /// value before the swap; `new_state` is the value `getState`
    /// will read after this event.
    pub const state_changed = struct {
        old_state: []const u8,
        new_state: []const u8,
    };

    /// Fired by `Game.setPaused` when the flag transitions. Mirrors
    /// `HookPayload.pause_changed`.
    pub const pause_changed = struct {
        paused: bool,
    };

    // ── Input events (labelle-gui#208, Option B) ─────────────────
    // Engine-hosted input events scanned in `Game.tick` through the
    // unified `InputInterface`. Flows handle them via
    // `OnEvent { name: "engine.key_pressed" }` etc. `key`/`button` are
    // backend-compatible raylib codes (see `input_types.zig`).

    /// Fired when a key transitioned to down THIS frame (down-edge).
    /// `key` is the raylib-compatible `KeyboardKey` code.
    pub const key_pressed = struct {
        key: u32,
    };

    /// Fired when a key transitioned to up this frame (up-edge).
    /// `key` is the raylib-compatible `KeyboardKey` code.
    pub const key_released = struct {
        key: u32,
    };

    /// Fired on a mouse-button down-edge, carrying the cursor position
    /// (screen coordinates, Y-down) at the moment of the press.
    /// `button` is the raylib-compatible `MouseButton` code.
    pub const mouse_button_pressed = struct {
        button: u32,
        x: f32,
        y: f32,
    };

    /// Fired on a mouse-button up-edge, carrying the cursor position
    /// (screen coordinates, Y-down) at the moment of the release.
    /// `button` is the raylib-compatible `MouseButton` code.
    pub const mouse_button_released = struct {
        button: u32,
        x: f32,
        y: f32,
    };

    /// Fired the frame a gamepad connect event was drained from the
    /// backend / per-OS source (core#18 contract). Payload mirrors the
    /// fields of `core.GamepadEvent`:
    ///
    /// - `id` — the device slot/index. Kept (and listed first) for
    ///   backward-compat: flows / hooks that only read `.id` still
    ///   compile against the enriched payload.
    /// - `name` / `name_len` — inline, NUL-terminated device name buffer.
    ///   Stored INLINE (not as a `[]const u8`) on purpose: engine events
    ///   are COPIED into `event_buffer` and dispatched on a later frame,
    ///   so a borrowed slice into the transient drain buffer would dangle.
    ///   Read it via `nameSlice()`.
    /// - `guid` — stable per-device reconnection key when the backend
    ///   exposes one (else `null`).
    /// - `source_class` — real gamepad vs. TV/d-pad remote vs. unknown.
    /// - `type_hint` — best-guess vendor family for glyph/prompt choice.
    pub const gamepad_connected = struct {
        id: u32,
        name: [core.gamepad.NAME_CAPACITY:0]u8 = [_:0]u8{0} ** core.gamepad.NAME_CAPACITY,
        name_len: u8 = 0,
        guid: ?[16]u8 = null,
        source_class: core.GamepadSourceClass = .unknown,
        type_hint: core.GamepadTypeHint = .unknown,

        /// Borrow the device name as a slice (valid for the lifetime of
        /// the payload value).
        pub fn nameSlice(self: *const gamepad_connected) []const u8 {
            // Defensively cap to the buffer length: `name_len` is a backend-
            // reported value, and a misbehaving backend reporting a length
            // greater than NAME_CAPACITY would otherwise slice out of bounds.
            const len = @min(self.name_len, core.gamepad.NAME_CAPACITY);
            return self.name[0..len];
        }
    };

    /// Fired the frame a gamepad disconnect event was drained (core#18).
    /// Only `id` (the device slot) is carried — a disconnect needs no name
    /// or capability metadata. Kept identical to the legacy payload.
    pub const gamepad_disconnected = struct {
        id: u32,
    };

    // ── ControllerManager player↔controller events (#611) ─────────────
    //
    // Higher-altitude than the raw `gamepad_*` events above. The engine's
    // `ControllerManager` (src/controller_manager.zig) consumes the drained
    // gamepad events and emits these — the game listens to *players*, not
    // hardware slots. `controller_available`/`controller_removed` surface
    // the unassigned pool (the cue to decide); the `player_*` trio fires
    // only *after* the game assigns. All four are flow-listenable via
    // `OnEvent { name: "engine.<event>" }`. See the issue for the
    // mechanism-not-policy rationale.

    /// Fired when a connected-but-unbound controller enters the unassigned
    /// pool — the game's cue to decide whether/how it becomes a player.
    /// Carries the same identity fields as `gamepad_connected` (read the
    /// name via `nameSlice()`).
    pub const controller_available = struct {
        controller_id: u32,
        name: [core.gamepad.NAME_CAPACITY:0]u8 = [_:0]u8{0} ** core.gamepad.NAME_CAPACITY,
        name_len: u8 = 0,
        guid: ?[16]u8 = null,
        source_class: core.GamepadSourceClass = .unknown,
        type_hint: core.GamepadTypeHint = .unknown,

        pub fn nameSlice(self: *const controller_available) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    /// Fired when an unassigned controller leaves the pool (unplugged while
    /// it was never bound to a player).
    pub const controller_removed = struct {
        controller_id: u32,
    };

    /// Fired when the game assigns a controller to a player (via the
    /// `ControllerManager` assignment API or an opt-in policy helper).
    /// Emitted only *after* the game decides — never auto-imposed.
    pub const player_joined = struct {
        player: u32,
        controller_id: u32,
    };

    /// Fired when a player's assigned controller has been absent longer
    /// than the configurable debounce window — a real loss, not a blip. A
    /// transient drop that reconnects inside the window NEVER fires this.
    /// Gate `Controller.advance` / raise a "reconnect Player N" prompt here.
    pub const player_controller_lost = struct {
        player: u32,
    };

    /// Fired when a previously-lost (or debouncing) player gets their
    /// controller back — a same-`guid` replug, or the raylib resume
    /// heuristic. `controller_id` is the (possibly new) backing controller.
    pub const player_controller_restored = struct {
        player: u32,
        controller_id: u32,
    };

    // ── GPU surface lifecycle (Android context loss, epic #386 Phase 4) ──
    //
    // On Android, TERM_WINDOW destroys every GPU texture (game state and
    // the CPU allocator survive); INIT_WINDOW recreates the surface. The
    // backend calls `Game.surfaceLost` / `Game.surfaceRestored`, which
    // invalidate + re-upload the GPU-resident asset catalog and emit
    // these events so flows/scripts can pause/resume rendering-dependent
    // work across the gap. Both carry no payload — the transition itself
    // is the signal. Zero-cost when no listener subscribes (same gate
    // `emitEngineEvent` uses for every other engine event).

    /// Fired when the GPU surface is lost and the catalog has dropped its
    /// stale texture handles (refcounts preserved). No new GPU work
    /// should run until `surface_restored`.
    pub const surface_lost = struct {};

    /// Fired after the GPU surface is restored, the catalog has
    /// re-enqueued its GPU-resident assets, and the first frame has been
    /// pumped back to `.ready`.
    pub const surface_restored = struct {};
};

// ── Hook Types ──
pub const HookPayload = hooks_types_mod.HookPayload;
pub const GameInitInfo = hooks_types_mod.GameInitInfo;
pub const FrameInfo = hooks_types_mod.FrameInfo;
pub const SceneBeforeLoadInfo = hooks_types_mod.SceneBeforeLoadInfo;
pub const SceneInfo = hooks_types_mod.SceneInfo;
pub const StateChangeInfo = hooks_types_mod.StateChangeInfo;
pub const PauseChangedInfo = hooks_types_mod.PauseChangedInfo;
pub const EntityInfo = hooks_types_mod.EntityInfo;
pub const ComponentPayload = hooks_types_mod.ComponentPayload;

// ── Hook Dispatcher ──
pub const MergeHooks = core.MergeHooks;
pub const MergeHookPayloads = core.MergeHookPayloads;

// ── Profiler ──
/// Per-script / per-plugin frame profiler (lives in the scene module so
/// both the ScriptRunner and the SystemRegistry can reach it). Enable at
/// runtime with `LABELLE_PROFILE=1`; ranks tick costs to the log.
pub const profiler = scene_mod.profiler;

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
pub const SpriteAnimation = sprite_animation_mod.SpriteAnimation;
pub const SpriteAnimationMode = sprite_animation_mod.AnimationMode;
pub const spriteAnimationTick = sprite_animation_tick_mod.tick;
pub const SpriteByField = sprite_by_field_mod.SpriteByField;
pub const SpriteByFieldSource = sprite_by_field_mod.SpriteByFieldSource;
pub const spriteByFieldTick = sprite_by_field_tick_mod.tick;

// ── Atlas ──
pub const SpriteData = atlas_mod.SpriteData;
pub const FindSpriteResult = atlas_mod.FindSpriteResult;
pub const ComptimeAtlas = atlas_mod.ComptimeAtlas;
pub const RuntimeAtlas = atlas_mod.RuntimeAtlas;
pub const TextureManager = atlas_mod.TextureManager;
pub const SpriteCache = atlas_mod.SpriteCache;

// ── Assets (Asset Streaming RFC — #437) ──
// `AssetCatalog` is reachable from games both as this module-level
// alias and — the user-facing form the RFC is written against — as
// `game.assets` (wired into `Game` in #454). Scripts should prefer
// the `game.assets.*` path; the module alias is still useful for
// unit tests and assembler-generated init code.
pub const AssetCatalog = assets_mod.AssetCatalog;
pub const AssetEntry = assets_mod.AssetEntry;
pub const AssetState = assets_mod.AssetState;
pub const LoaderKind = assets_mod.LoaderKind;
pub const DecodedPayload = assets_mod.DecodedPayload;
pub const UploadedResource = assets_mod.UploadedResource;
pub const AssetTexture = assets_mod.Texture;
pub const AssetLoaderVTable = assets_mod.AssetLoaderVTable;
pub const AssetWorkRequest = assets_mod.WorkRequest;
pub const AssetWorkResult = assets_mod.WorkResult;
/// Runtime backend hook for the image asset loader. The assembler
/// populates this at `Game.init` via `ImageLoader.setBackend(...)`
/// with adapters that forward to labelle-gfx's `decodeImage` /
/// `uploadTexture` / `unloadTexture`. See
/// `src/assets/loaders/image.zig` for the full rationale.
pub const ImageLoader = assets_mod.image_loader;
pub const ImageBackend = assets_mod.image_loader.ImageBackend;
pub const DecodedImage = assets_mod.image_loader.DecodedImage;

// ── Preview Mode (#516) ──
// Connect-out control channel to the labelle-gui editor. Engine
// stays a library — the generated `main.zig` is what owns argv and
// instantiates `Preview` when `--preview-mode <host:port>` is set.
pub const Preview = preview_mode_mod.Preview;
pub const ByeReason = preview_mode_mod.ByeReason;
pub const preview_protocol_version = preview_mode_mod.protocol_version;
pub const preview_heartbeat_interval_ms = preview_mode_mod.heartbeat_interval_ms;
pub const parsePreviewArgs = preview_mode_mod.parseArgs;
// Phase 2 / #518 — binary state telemetry frame types.
pub const PreviewBinaryFrameKind = preview_mode_mod.BinaryFrameKind;
pub const preview_binary_magic = preview_mode_mod.binary_magic;
// #547 — macOS IOSurface producer module. Surfaced for tests +
// downstream code that wants the `ControlBlock` shape; the runtime
// API the assembler-generated `main.zig` cares about is the
// `Preview.beginFrameStreamIOSurface` / `publishFrameIOSurface` /
// `endFrameStreamIOSurface` triple.
pub const preview_iosurface_mod = preview_mode_mod.preview_iosurface;

// ── Out-of-band screenshot request (labelle-cli#227) ──
// Read by the assembler-generated `main.zig`'s frame loop after the
// game enters its main loop — when `LABELLE_SCREENSHOT_PATH` is set
// (by `labelle run --screenshot=<path>`), the loop fires
// `window.takeScreenshot(req.path)` once after `req.after_sec`.
//
// The helper itself is environment-driven so the assembler template
// stays argv-agnostic — no new pass-through wiring through every
// platform template, just one `getenv` per run.
pub const ScreenshotRequest = screenshot_request_mod.Request;
pub const requestedScreenshot = screenshot_request_mod.parse;
/// Monotonic ns counter the screenshot timing block reads each frame
/// to decide whether `after_sec` has elapsed. Lives next to
/// `requestedScreenshot` because `std.time.nanoTimestamp` is gone in
/// Zig 0.16 — see screenshot_request.zig for the libc fallback.
pub const nowNs = screenshot_request_mod.nowNs;

// ── JSONC Scene Bridge ──
pub const JsoncSceneBridge = @import("jsonc_scene_bridge.zig").JsoncSceneBridge;
pub const JsoncSceneBridgeWithGizmos = @import("jsonc_scene_bridge.zig").JsoncSceneBridgeWithGizmos;
// Subordinate modules from the #495 refactor — re-exported so tests
// (and any downstream that wants a focused entry point) can pick
// the piece they need without going through the full bridge.
pub const jsonc_deserializer = @import("jsonc/deserializer.zig");

// ── Entity-tree walker (RFC #569) ──
// The single shared traversal for every entity-tree consumer —
// crosses both `children` and prefab refs nested in component
// fields, with prefab-cycle detection. Re-exported so specs and
// downstream tooling (asset inference, editors) use one walker.
pub const tree_walker = @import("jsonc/tree_walker.zig");

// ── Scene Value & JSONC Parser ──
pub const SceneValue = jsonc_mod.Value;
pub const JsoncParser = jsonc_mod.JsoncParser;
pub const JsoncParseError = jsonc_mod.ParseError;
pub const HotReloader = jsonc_mod.HotReloader;

// ── Scheduler (flow Delay timers, #25 Stage 2) ──
pub const Scheduler = @import("scheduler.zig").Scheduler;

// ── ControllerManager (player↔controller mapping, #611) ──
// Game-facing layer over the raw gamepad events: unassigned pool +
// assignment API + player-level events, with engine-owned debounced-lost
// and identity-based resume. Mechanism, not policy — the two common
// policies ship as opt-in helpers. See src/controller_manager.zig.
pub const controller_manager_mod = @import("controller_manager.zig");
pub const ControllerManager = controller_manager_mod.ControllerManager;
pub const DefaultControllerManager = controller_manager_mod.DefaultControllerManager;
pub const ControllerManagerConfig = controller_manager_mod.Config;
pub const ControllerInfo = controller_manager_mod.ControllerInfo;
pub const ControllerManagerEvent = controller_manager_mod.ManagerEvent;
pub const NO_PLAYER = controller_manager_mod.NO_PLAYER;
pub const NO_CONTROLLER = controller_manager_mod.NO_CONTROLLER;

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

