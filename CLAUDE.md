# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build test          # Run all tests (zspec BDD tests)
zig build unit-test     # Run unit tests only
zig build generate      # Generate project files from project.labelle
zig build bench         # Run ECS performance benchmarks

# Run example projects (each has its own build.zig)
cd usage/example_1 && zig build run

# CI test mode (runs without window, exits immediately)
CI_TEST=1 zig build run  # in example directories

# Build with specific backend
zig build -Dbackend=sokol           # Use sokol graphics backend
zig build -Decs_backend=zflecs      # Use zflecs ECS backend
```

## Architecture

labelle-engine is a 2D game engine for Zig built on top of labelle-gfx (graphics) and pluggable ECS backends (zig_ecs or zflecs). It provides a declarative scene system using comptime .zon files.

### Coordinate System

The engine uses a **Y-up coordinate system** (origin at bottom-left, positive Y = up, CCW rotation). The engine transforms coordinates at boundaries:

- **Render boundary**: Y-up game coords → Y-down screen coords (in `RenderPipeline.sync()`)
- **Input boundary**: Y-down screen coords → Y-up game coords. Use `game.input_mixin.getMousePosition()` and `game.input_mixin.getTouch()` to get coordinates in the game's Y-up system.
- For raw screen coordinates (Y-down), use `game.getInput().getMousePosition()`.
- All Position components and .zon files use Y-up game coordinates.

### Core Modules (src/)

- **scene.zig** - Main module, re-exports all public types. Entry point for `@import("labelle-engine")`
- **game.zig** - `Game` facade: window init, entity management, scene transitions, game loop
- **render_pipeline.zig** - Bridges ECS components to RetainedEngine, dirty tracking and visual sync
- **loader.zig** - `SceneLoader` parses comptime .zon scene data, creates entities from prefabs or inline definitions
- **prefab.zig** - `Prefab` templates with sprite config and optional lifecycle hooks (onCreate/onUpdate/onDestroy)
- **component.zig** - `ComponentRegistry` maps component names to types for .zon scene loading
- **script.zig** - `ScriptRegistry` maps script names to update/init/deinit functions
- **generator.zig** - Generates build.zig, build.zig.zon, main.zig from project.labelle config using zts templates
- **project_config.zig** - Parses .labelle project files (ZON format)
- **ecs/** - ECS abstraction layer supporting multiple backends (zig_ecs, zflecs)

### Key Abstractions

**Registries** (comptime type maps):
```zig
const Prefabs = engine.PrefabRegistry(.{ player_prefab, enemy_prefab });
const Components = engine.ComponentRegistry(struct {
    pub const Health = health_comp.Health;
});
const Scripts = engine.ScriptRegistry(struct {
    pub const gravity = gravity_script;
});
const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
```

**Scene .zon format** (scenes/*.zon):
```zig
.{
    .name = "level1",
    .scripts = .{"gravity"},
    .gui_views = .{"hud", "minimap"},        // optional
    .camera = .{ .x = 0, .y = 0, .zoom = 1.0 },  // or .cameras for multi-camera
    .entities = .{
        .{ .prefab = "player", .components = .{ .Position = .{ .x = 400, .y = 300 } } },
        .{ .components = .{ .Position = .{ .x = 100, .y = 100 }, .Shape = .{ .type = .circle, .radius = 50, .color = .{ .r = 255 } } } },
        .{ .components = .{ .Position = .{ .x = 300, .y = 150 }, .Sprite = .{ .name = "gem.png" }, .Health = .{ .current = 50 } } },
    },
}
```

Scene-level `.Position` overrides prefab Position.

**Prefab definition** (prefabs/*.zon):
```zig
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "idle", .pivot = .bottom_center },
        .Health = .{ .current = 100, .max = 100 },
    },
    .gizmos = .{  // debug-only, stripped in release builds
        .Text = .{ .text = "Player", .size = 12, .y = -20 },
        .Shape = .{ .shape = .{ .circle = .{ .radius = 5 } }, .color = .{ .r = 255 } },
    },
}
```

**Pivot values:** `.center`, `.top_left`, `.top_center`, `.top_right`, `.center_left`, `.center_right`, `.bottom_left`, `.bottom_center`, `.bottom_right`, `.custom` (with `.pivot_x`/`.pivot_y` 0.0-1.0)

**Script definition** (scripts/*.zig):
```zig
pub fn init(game: *Game, scene: *Scene) void { ... }    // optional
pub fn update(game: *Game, scene: *Scene, dt: f32) void { ... }
pub fn deinit(game: *Game, scene: *Scene) void { ... }  // optional
```

### Entity References and Composition

**Prefab composition**: Components with `Entity` or `[]const Entity` fields can use prefab references with component overrides in .zon files. See loader.zig for details.

**Parent references** (RFC #169): Components with `Entity` fields matching a parent component name (lowercased) are auto-populated when nested. Components can define `pub fn onReady(payload: loader.ComponentPayload)` for post-hierarchy setup.

**Entity references** (Issue #242): Use `.ref` syntax to reference other scene entities:
- `.{ .ref = .{ .id = "unique_id" } }` - by unique ID (recommended)
- `.{ .ref = .{ .entity = "name" } }` - by display name
- `.{ .ref = .self }` - self-reference

References are resolved in a second pass after all entities are created (forward refs work). Entity `.id` is auto-generated if not specified (`_e0`, `_e1`, ...). `.name` is for display/lookup.

### Gizmos

Debug-only visualizations (stripped in release builds). Types: Text, Shape, BoundingBox. Features: visibility modes (`.always`, `.selected_only`, `.never`), runtime toggle via `game.gizmos.setEnabled()`, standalone drawing via `game.gizmos.drawArrow()`/`drawRay()`/`drawLine()`/`drawCircle()`/`drawRect()`.

### Layers

Three built-in layers: `.background` (screen-space, behind), `.world` (camera-transformed, default), `.ui` (screen-space, on top). Set via `.layer` field on Sprite or Shape components.

### Sprite Sizing

CSS-like sizing modes (`.none`, `.stretch`, `.cover`, `.contain`, `.scale_down`, `.repeat`) with container options (`.infer`, `.viewport`, `.camera_viewport`, or explicit dimensions). Set via `.size_mode` and `.container` on Sprite components.

### Hook System

Comptime-based lifecycle hooks with zero runtime overhead:
- `game_init` / `game_deinit` - Game lifecycle
- `frame_start` / `frame_end` - Frame boundaries
- `scene_before_load` / `scene_load` / `scene_unload` - Scene transitions
- `entity_created` / `entity_destroyed` - Entity lifecycle

Usage: `const Game = engine.GameWith(MyHooks);` where `MyHooks` exports functions matching hook names.

**Caveats:**
- `game_init` fires before struct is in final memory location — don't store `*Game` pointers
- `scene_before_load` fires before entities exist — use for scene-scoped subsystem init
- Generator auto-scans `hooks/` folder and merges via `MergeEngineHooks`
- Plugins use `MergeEngineHooks` for two-way hook binding (see `usage/example_hooks/`)

### Project Configuration (project.labelle)

```zig
.{
    .version = 1,
    .name = "my_game",
    .initial_scene = "main_scene",
    .backend = .raylib,        // or .sokol
    .ecs_backend = .zig_ecs,   // or .zflecs
    .window = .{ .width = 800, .height = 600, .title = "My Game" },
    .camera = .{ .x = 0, .y = 0, .zoom = 1.0 },
    .physics = .{ .enabled = true, .gravity = .{ 0, 980 }, .pixels_per_meter = 100.0 },
    .plugins = .{
        .{ .name = "labelle-tasks", .version = "0.5.0" },         // version tag
        .{ .name = "labelle-gui", .branch = "main" },             // branch ref
        .{ .name = "labelle-pathfinding", .commit = "abc123def" }, // commit SHA
    },
}
```

Plugin reference types (mutually exclusive): `.version`, `.branch`, `.commit`. Optional fields: `.module`, `.components`, `.bind`, `.engine_hooks`, `.url`.

**Plugin bind**: Parameterized component types — `.bind = .{ .{ .func = "bind", .arg = "Items", .components = "Storage,Worker" } }` generates `labelle_tasks.bind(Items)`.

**Plugin engine_hooks**: Auto-wire plugin hooks — `.engine_hooks = .{ .create = "createEngineHooks", .task_hooks = "task_hooks.GameHooks" }`.

### Project Generator

`zig build generate` reads `project.labelle` and scans prefabs/, components/, scripts/, hooks/ folders to generate `.labelle/build.zig.zon`, `.labelle/build.zig`, and `main.zig`. Templates in `src/templates/`.

### Entity Lifecycle

1. Scene loader creates entities via `Game.createEntity()`
2. Components added: Position, Sprite/Shape/Text, custom components
3. Visual tracked via `RenderPipeline.trackEntity()`
4. Prefab `onCreate()` hook called if defined
5. Each frame: scripts update, `RenderPipeline.sync()` pushes dirty state to graphics
6. On destroy: `onDestroy()` hook, `RenderPipeline.untrackEntity()`

### Physics

Optional Box2D integration. Enable with `physics.enabled = true` in project.labelle or `zig build -Dphysics=true`. Components: `RigidBody`, `Collider`, `Velocity`. See `usage/example_physics/`.

### GUI Module

Optional immediate-mode GUI (`zig build -Dgui_backend=raygui`). Declarative .zon views with ViewRegistry. Elements: Label, Button, ProgressBar, Panel, Checkbox, Slider. Runtime state via VisibilityState/ValueState/FormBinder. See `usage/example_gui/`.

### Important Patterns

- Lifecycle hooks use `u64` for entity and `*anyopaque` for game to avoid circular imports
- Use `engine.entityFromU64()` and `engine.entityToU64()` for entity conversion in hooks
- `Game.fixPointers()` must be called after init when struct moves to final stack location
- Position changes require `pipeline.markPositionDirty(entity)` for sync to graphics
- Scripts support `init()` and `deinit()` lifecycle hooks for resource management
