# RFC 001: Hook System for labelle-engine

**Status**: Implemented
**Created**: 2025-12-24
**Updated**: 2025-12-25

## Summary

Add a type-safe hook/event system to labelle-engine that allows:
1. Games to register callbacks for engine lifecycle events
2. Plugins (like labelle-tasks) to define and emit custom hooks
3. Games to subscribe to plugin hooks

## Motivation

Currently, labelle-engine has scattered callback patterns:
- `SceneHooks` (onLoad/onUnload) in game.zig
- `EntityInstance` hooks (onUpdate/onDestroy) in scene.zig
- `ScriptFns` lifecycle (init/update/deinit) in script.zig
- labelle-tasks uses its own callback system (FindBestWorkerFn, OnStepStartedFn, etc.)

A unified hook system would:
- Provide consistent API across engine and plugins
- Enable type-safe enum-based event dispatch
- Allow plugins to define extensible hook points
- Reduce boilerplate for common patterns

## Design

### Core Concepts

```
┌─────────────────────────────────────────────────────────────┐
│                         Game                                 │
│  ┌──────────────────────────────┐  ┌──────────────────────┐ │
│  │ Engine HookMap (comptime)    │  │ Plugin HookMap        │ │
│  │ - struct of handler fns      │  │ - struct of handler fns│ │
│  └──────────────┬───────────────┘  └──────────┬───────────┘ │
│                 │                              │             │
│                 ▼                              ▼             │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ HookDispatcher (comptime)                              │  │
│  │ - emit(payload_union)                                 │  │
│  │ - hasHandler(hook_tag)                                │  │
│  │ - MergeHooks(...) to combine multiple HookMaps         │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1. Engine Hook Enum

Built-in hooks for engine lifecycle events:

```zig
pub const EngineHook = enum {
    // Game lifecycle
    game_init,
    game_deinit,
    frame_start,
    frame_end,

    // Scene lifecycle
    scene_load,
    scene_unload,
    // Entity lifecycle
    entity_created,
    entity_destroyed,
};
```

Notes:
- This RFC originally proposed additional hooks (`scene_update`, input, render). Those are still good candidates, but **are not implemented in the current PR**.

### 2. Hook Payload

Type-safe payload for each hook type:

```zig
pub const HookPayload = union(EngineHook) {
    game_init: void,
    game_deinit: void,
    frame_start: FrameInfo,
    frame_end: FrameInfo,

    scene_load: SceneInfo,
    scene_unload: SceneInfo,

    entity_created: EntityInfo,
    entity_destroyed: EntityInfo,
};

pub const FrameInfo = struct {
    frame_number: u64,
    dt: f32,
};

pub const SceneInfo = struct {
    name: []const u8,
};

pub const EntityInfo = struct {
    /// Engine uses `u64` for backend compatibility (zig_ecs vs zflecs).
    /// Use `engine.entityFromU64()` / `engine.entityToU64()` when converting.
    entity_id: u64,
    prefab_name: ?[]const u8,
};
```

### 3. Hook Registry (Comptime)

Similar to existing registries, define hooks at compile time. Handler functions receive
the full `HookPayload` union and extract the relevant field:

```zig
// In game's main.zig
const MyHooks = struct {
    pub fn scene_load(payload: engine.HookPayload) void {
        const info = payload.scene_load;
        std.log.info("Scene loaded: {s}", .{info.name});
    }

    pub fn entity_created(payload: engine.HookPayload) void {
        const info = payload.entity_created;
        std.log.info("Entity created: {d}", .{info.entity_id});
    }

    pub fn frame_start(payload: engine.HookPayload) void {
        const info = payload.frame_start;
        // Only log every 60 frames
        if (info.frame_number % 60 == 0) {
            std.log.info("Frame {d}", .{info.frame_number});
        }
    }
};

// Create Game type with hooks enabled
const Game = engine.GameWith(MyHooks);
```

### 4. Plugin Hook Definition

Plugins define their own hook enums:

```zig
// In labelle-tasks/hooks.zig
pub const TasksHook = enum {
    step_started,
    step_completed,
    worker_assigned,
    worker_released,
    workstation_blocked,
    workstation_activated,
    cycle_completed,
};

pub const TasksPayload = union(TasksHook) {
    step_started: StepInfo,
    step_completed: StepInfo,
    worker_assigned: WorkerAssignment,
    worker_released: WorkerInfo,
    workstation_blocked: WorkstationInfo,
    workstation_activated: WorkstationInfo,
    cycle_completed: CycleInfo,
};
```

### 5. Comptime Hook Dispatcher

Zero-overhead hook dispatch via comptime:

```zig
/// Creates a hook dispatcher from a comptime hook map.
/// Each field in HookMap should be a function taking (payload: PayloadUnion) -> void.
pub fn HookDispatcher(comptime HookEnum: type, comptime PayloadUnion: type, comptime HookMap: type) type {
    return struct {
        /// Emit a hook event. Resolved entirely at comptime - no runtime overhead.
        pub inline fn emit(payload: PayloadUnion) void {
            // Use inline switch to resolve hook name at comptime
            switch (payload) {
                inline else => |_, tag| {
                    const hook_name = @tagName(tag);
                    if (@hasDecl(HookMap, hook_name)) {
                        const handler = @field(HookMap, hook_name);
                        handler(payload);
                    }
                    // No handler registered - that's fine, just a no-op
                },
            }
        }

        /// Check at comptime if a hook has a handler registered.
        pub fn hasHandler(comptime hook: HookEnum) bool {
            return @hasDecl(HookMap, @tagName(hook));
        }
    };
}
```

### 6. Integration with Existing Systems

#### Scene Hooks Migration
```zig
// Before (game.zig)
pub const SceneHooks = struct {
    onLoad: ?*const fn (*Game) void = null,
    onUnload: ?*const fn (*Game) void = null,
};

// Now: the engine emits `scene_load` / `scene_unload` automatically
// when you call `game.setScene(...)` / when the current scene unloads.
//
// To observe it, define handlers and use GameWith:
const MyHooks = struct {
    pub fn scene_load(payload: engine.HookPayload) void {
        const info = payload.scene_load;
        std.log.info("Scene loaded: {s}", .{info.name});
    }
};
const Game = engine.GameWith(MyHooks);
```

#### Entity Lifecycle Migration
```zig
// Before (scene.zig EntityInstance)
onUpdate: ?*const fn (u64, *anyopaque, f32) void = null,
onDestroy: ?*const fn (u64, *anyopaque) void = null,

// Now: the engine emits `entity_created` / `entity_destroyed` automatically
// from `Game.createEntity()` / `Game.destroyEntity()`.
//
// Note: at the Game layer, `prefab_name` is not known, so it is currently null.
```

## Usage Examples

### Basic Game with Hooks

```zig
// main.zig
const std = @import("std");
const engine = @import("labelle-engine");

// Define hook handlers - only implement the hooks you care about
const MyHooks = struct {
    pub fn game_init(_: engine.HookPayload) void {
        std.log.info("[hook] Game initialized", .{});
    }

    pub fn game_deinit(_: engine.HookPayload) void {
        std.log.info("[hook] Game shutting down", .{});
    }

    pub fn frame_start(payload: engine.HookPayload) void {
        const info = payload.frame_start;
        // Only log every 60 frames to avoid spam
        if (info.frame_number % 60 == 0) {
            std.log.info("[hook] Frame {d} started (dt: {d:.3}ms)", .{
                info.frame_number,
                info.dt * 1000,
            });
        }
    }

    pub fn scene_load(payload: engine.HookPayload) void {
        const info = payload.scene_load;
        std.log.info("[hook] Scene loaded: {s}", .{info.name});
    }
};

// Create Game type with hooks enabled
const Game = engine.GameWith(MyHooks);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize game - game_init hook fires automatically
    var game = try Game.init(allocator, .{
        .window = .{ .width = 800, .height = 600, .title = "My Game" },
    });
    game.fixPointers();
    defer game.deinit(); // game_deinit hook fires

    try game.registerSceneSimple("main", loadMainScene);
    try game.setScene("main"); // scene_load hook fires

    // Run game loop - frame_start/frame_end hooks fire each frame
    try game.run();
}

fn loadMainScene(_: *Game) !void {
    std.log.info("Loading main scene...", .{});
}
```

### Game Without Hooks (Default)

```zig
// For games that don't need hooks, just use engine.Game directly
const engine = @import("labelle-engine");

pub fn main() !void {
    var game = try engine.Game.init(allocator, config);
    defer game.deinit();
    try game.run();
}
```

### Plugin Hook Pattern

Plugins can define their own hook systems following the same pattern:

```zig
// In your plugin
pub const MyPluginHook = enum {
    on_task_complete,
    on_state_change,
};

pub const MyPluginPayload = union(MyPluginHook) {
    on_task_complete: TaskInfo,
    on_state_change: StateInfo,
};

// Games create dispatchers for plugin hooks
const PluginDispatcher = engine.hooks.HookDispatcher(
    MyPluginHook,
    MyPluginPayload,
    MyPluginHandlers
);
```

## Implementation Plan

### Phase 1: Core Hook Infrastructure ✅
1. Create `src/hooks.zig` with:
   - `EngineHook` enum (game_init, game_deinit, scene_load, scene_unload, entity_created, entity_destroyed, frame_start, frame_end)
   - `HookPayload` tagged union with payload types for each hook
   - `HookDispatcher` comptime generic type
   - Payload structs (FrameInfo, SceneInfo, EntityInfo)

2. Create `src/hooks/` directory structure:
   - `src/hooks/types.zig` - Core types, enums, and payload structs
   - `src/hooks/dispatcher.zig` - HookDispatcher implementation

### Phase 2: Engine Integration ✅
1. Add `GameWith(Hooks)` type parameter to Game:
   ```zig
   pub fn GameWith(comptime Hooks: type) type { ... }
   pub const Game = GameWith(void); // Default: no hooks (compiles to no-ops)
   ```

2. Add emit points in game.zig:
   - `game_init` after initialization ✅
   - `game_deinit` before cleanup ✅
   - `frame_start` at beginning of frame ✅
   - `frame_end` at end of frame ✅
   - `scene_load` after scene loads ✅
   - `scene_unload` before scene unloads ✅

3. Entity hooks:
   - `entity_created` ✅ (emitted by `Game.createEntity()`, prefab_name currently null)
   - `entity_destroyed` ✅ (emitted by `Game.destroyEntity()`, prefab_name currently null)

### Phase 3: Plugin Hook Pattern ✅
1. Document pattern for plugins to define their own hooks:
   ```zig
   // In plugin: define hook enum and payloads
   pub const MyPluginHook = enum { ... };
   pub const MyPluginPayload = union(MyPluginHook) { ... };

   // Game creates dispatcher for plugin hooks
   const PluginHooks = hooks.HookDispatcher(
       MyPluginHook,
       MyPluginPayload,
       MyHandlers
   );
   ```

2. Two-way plugin binding with `MergeHooks` / `MergeEngineHooks`:
   ```zig
   // Merge game hooks with plugin's engine hooks
   const AllHooks = engine.MergeEngineHooks(.{ GameHooks, PluginHooks });
   const Game = engine.GameWith(AllHooks);
   ```

3. Full example in `usage/example_hooks/` demonstrating plugin integration

### Phase 4: Testing & Documentation ✅
1. Create `test/hooks_test.zig` with tests for:
   - Hook dispatch with handlers
   - Hook dispatch without handlers (no-op)
   - Multiple hooks in same HookMap
   - Payload data correctness

2. Add documentation in CLAUDE.md for hook system usage

### Phase 5: Generator Integration ✅
1. Generator scans `hooks/` folder for `.zig` files
2. Each hook file should export public functions matching hook names
3. Generated code merges all hook files using `MergeEngineHooks`
4. Projects without a hooks folder use `engine.Game` directly

Example hook file (`hooks/game_hooks.zig`):
```zig
const engine = @import("labelle-engine");

pub fn game_init(_: engine.HookPayload) void {
    // Handle game init
}

pub fn scene_load(payload: engine.HookPayload) void {
    const info = payload.scene_load;
    std.log.info("Scene loaded: {s}", .{info.name});
}
```

## Files Created/Modified

### New Files ✅
- `src/hooks.zig` - Main module, re-exports all hook types
- `src/hooks/types.zig` - EngineHook enum, HookPayload union, payload structs
- `src/hooks/dispatcher.zig` - HookDispatcher comptime generic
- `usage/example_hooks/` - Working example demonstrating hook system
- `docs/rfcs/001-hook-system.md` - This RFC document

### Modified Files ✅
- `src/game.zig` - Add GameWith(Hooks) parameterization, emit lifecycle hooks
- `src/scene.zig` (module entry) - Re-export hook types and GameWith
- `src/generator.zig` - Scan hooks/ folder, generate MergeEngineHooks code
- `src/templates/main_raylib.txt` - Hook import and registry template sections
- `CLAUDE.md` - Document hook system usage

## Design Decisions

1. **Comptime Registration**: Prioritize comptime hooks for zero overhead. Hooks are defined at compile time and inlined, matching existing registry patterns (ComponentRegistry, ScriptRegistry, PrefabRegistry).

2. **No Cancellation**: Hooks are purely observational - they react to events but cannot prevent or modify them. This keeps the system simple and predictable.

3. **Separate Dispatchers**: Each plugin has its own HookDispatcher. Games subscribe to each plugin's hooks separately. This provides clear namespacing and avoids coordination issues.

4. **No Priority/Async**: Keep initial implementation simple. Priority ordering and async hooks can be added later if needed.

5. **game_init Timing**: The `game_init` hook fires at the end of `Game.init()` before the struct is moved to its final stack location. Handlers should not rely on `*Game` pointers at this point. For operations requiring a stable Game pointer, use `scene_load` or wait until after `fixPointers()` is called.

## Alternatives Considered

### 1. Signal/Slot Pattern
- More traditional but requires more boilerplate
- Harder to make type-safe in Zig

### 2. Observer Pattern with Interfaces
- Zig doesn't have interfaces, would require vtables
- More runtime overhead

### 3. Keep Current Scattered Callbacks
- Works but inconsistent API
- Harder for plugins to integrate

## References

- Current labelle-engine patterns: `src/script.zig`, `src/scene.zig`
- labelle-tasks callbacks: `labelle-tasks/src/engine.zig`
- labelle-gui plugin pattern: `labelle-gui/spikes/05-dynamic-imgui/`
