# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Run all tests (zspec BDD tests)
zig build test

# Run unit tests only
zig build unit-test

# Generate project files from project.labelle
zig build generate

# Run ECS performance benchmarks
zig build bench

# Run example projects (each has its own build.zig)
cd usage/example_1 && zig build run
cd usage/example_2 && zig build run
cd usage/example_3 && zig build run

# CI test mode (runs without window, exits immediately)
CI_TEST=1 zig build run  # in example directories

# Build with specific backend
zig build -Dbackend=sokol           # Use sokol graphics backend
zig build -Decs_backend=zflecs      # Use zflecs ECS backend
```

## Architecture

labelle-engine is a 2D game engine for Zig built on top of labelle-gfx (graphics) and pluggable ECS backends (zig_ecs or zflecs). It provides a declarative scene system using comptime .zon files.

### Core Modules (src/)

- **scene.zig** - Main module, re-exports all public types. Entry point for `@import("labelle-engine")`
- **game.zig** - `Game` facade providing high-level API: window init, entity management, scene transitions, game loop
- **render_pipeline.zig** - Bridges ECS components to RetainedEngine, handles dirty tracking and visual sync
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

    // GUI views to render with this scene (optional):
    .gui_views = .{"hud", "minimap"},

    // Single camera (configures primary camera):
    .camera = .{ .x = 0, .y = 0, .zoom = 1.0 },

    // OR named cameras for multi-camera/split-screen:
    // .cameras = .{
    //     .main = .{ .x = 0, .y = 0 },        // camera 0
    //     .player2 = .{ .x = 100, .y = 0 },   // camera 1
    //     .minimap = .{ .zoom = 0.25 },       // camera 2
    // },

    .entities = .{
        // Prefab with position:
        .{ .prefab = "player", .components = .{ .Position = .{ .x = 400, .y = 300 } } },
        // Shape entity (Shape component with Position):
        .{ .components = .{ .Position = .{ .x = 100, .y = 100 }, .Shape = .{ .type = .circle, .radius = 50, .color = .{ .r = 255 } } } },
        // Sprite entity with position in .components:
        .{ .components = .{ .Position = .{ .x = 300, .y = 150 }, .Sprite = .{ .name = "gem.png" }, .Health = .{ .current = 50 } } },
        // Data-only entity (no visual):
        .{ .components = .{ .Position = .{ .x = 100, .y = 100 }, .Health = .{ .current = 100 } } },
    },
}
```

**Position:** Use `.Position` component in the `.components` block. Scene-level Position overrides prefab Position.

**Prefab definition** (prefabs/*.zon):
```zig
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },  // default position, can be overridden in scene
        .Sprite = .{ .name = "idle", .pivot = .bottom_center },
        .Health = .{ .current = 100, .max = 100 },  // optional custom components
    },
    .gizmos = .{  // debug-only visualizations (stripped in release builds)
        .Text = .{ .text = "Player", .size = 12, .y = -20 },
        .Shape = .{ .shape = .{ .circle = .{ .radius = 5 } }, .color = .{ .r = 255 } },
    },
}
```

**Gizmos** (debug visualizations):

Gizmos are debug-only visualizations attached to entities. They are:
- Only created in debug builds (stripped in release via `@import("builtin").mode`)
- Can be toggled at runtime via `game.setGizmosEnabled(false)`
- Inherit position from their parent entity with optional offset
- Support visibility modes: `.always`, `.selected_only`, `.never`

```zig
// In prefab or scene entity definition
.gizmos = .{
    .Text = .{ .text = "Entity Name", .size = 10, .y = -15 },  // label above entity
    .Shape = .{ .shape = .{ .circle = .{ .radius = 3 } }, .color = .{ .r = 255 } },  // origin marker
    .BoundingBox = .{ .color = .{ .r = 0, .g = 255, .b = 0, .a = 200 }, .padding = 2 },  // auto-sized outline
},

// Toggle at runtime
game.setGizmosEnabled(false);  // Hide all gizmos
game.setGizmosEnabled(true);   // Show all gizmos
const enabled = game.areGizmosEnabled();
```

**BoundingBox Gizmo** (auto-sized from parent visual):

The BoundingBox gizmo automatically calculates its size from the parent entity's visual component (Sprite or Shape) and draws an outline rectangle:

```zig
// In prefab or scene gizmos
.gizmos = .{
    // Simple bounding box (green outline)
    .BoundingBox = .{},  // defaults: green, no padding, 1px thickness

    // Customized bounding box
    .BoundingBox = .{
        .color = .{ .r = 255, .g = 50, .b = 50, .a = 180 },  // red, semi-transparent
        .padding = 5,      // extra pixels around visual bounds
        .thickness = 2,    // line thickness
        .visible = true,   // can be toggled
        .z_index = 255,    // draw on top
        .layer = .ui,      // render in UI layer (screen-space)
    },
},
```

BoundingBox bounds are calculated from:
- **Shape components**: Uses shape dimensions (circle radius×2, rectangle width/height, etc.)
- **Sprite components**: Looks up sprite dimensions from texture atlas, scaled by sprite.scale

**Standalone Gizmos** (not bound to entities):

Draw gizmos directly without creating entities. Useful for velocity vectors, debug rays, etc.

```zig
// In script update()
pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    // Clear previous frame's gizmos
    game.clearGizmos();

    // Draw arrow from point A to point B (e.g., velocity vector)
    game.drawArrow(pos.x, pos.y, pos.x + vel.x, pos.y + vel.y, Color{ .r = 255, .g = 0, .b = 0, .a = 255 });

    // Draw ray from origin in direction for length (e.g., raycast)
    game.drawRay(pos.x, pos.y, dir_x, dir_y, 100, Color{ .r = 0, .g = 255, .b = 0, .a = 255 });

    // Draw basic shapes
    game.drawLine(x1, y1, x2, y2, Color{ .r = 255, .g = 255, .b = 255, .a = 255 });
    game.drawCircle(x, y, radius, Color{ .r = 0, .g = 0, .b = 255, .a = 200 });
    game.drawRect(x, y, width, height, Color{ .r = 255, .g = 100, .b = 0, .a = 150 });
}

// In main loop - render gizmos after scene render
re.beginFrame();
re.render();
game.renderStandaloneGizmos();  // Draw standalone gizmos on top
re.endFrame();
```

**Gizmo Visibility Modes:**
- `.always` - Show when gizmos are enabled (default)
- `.selected_only` - Only show when parent entity is selected
- `.never` - Never show (disabled)

**Entity Selection** (for selected-only gizmos):
```zig
game.selectEntity(entity);     // Mark entity as selected
game.deselectEntity(entity);   // Deselect entity
game.clearSelection();         // Clear all selections
const selected = game.isEntitySelected(entity);  // Check selection state
```

**Pivot values:**
`.center`, `.top_left`, `.top_center`, `.top_right`, `.center_left`, `.center_right`, `.bottom_left`, `.bottom_center`, `.bottom_right`, `.custom`

For `.custom`, also specify `.pivot_x` and `.pivot_y` (0.0-1.0).

**Prefab composition** (using prefabs inside entity fields):

Components can have `Entity` or `[]const Entity` fields that reference other entities. These can use prefab references with optional component overrides:

```zig
// Component definitions
const Room = struct {
    movement_nodes: []const Entity = &.{},  // entity list
};

const Weapon = struct {
    projectile: Entity = Entity.invalid,     // single entity
};
```

In prefabs or scenes, use prefab references in entity fields:
```zig
// Entity list with prefab references
.Room = .{
    .movement_nodes = .{
        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 26 } } },
        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 78 } } },
    },
},

// Single entity with prefab reference
.Weapon = .{
    .projectile = .{ .prefab = "bullet", .components = .{ .Damage = .{ .value = 20 } } },
},

// Mix prefab references with inline definitions
.Room = .{
    .movement_nodes = .{
        .{ .prefab = "movement_node" },
        .{ .components = .{ .Position = .{ .x = 50 }, .Shape = .{ .type = .circle, .radius = 5 } } },
    },
},
```

**Parent references and onReady callbacks** (RFC #169):

Components with `Entity` fields matching a parent component name (lowercased) are auto-populated:

```zig
// Component with parent reference
const Storage = struct {
    role: enum { eis, iis, ios, eos } = .ios,
    workstation: Entity = Entity.invalid,  // Auto-populated when nested under Workstation

    // Called after entity hierarchy is complete
    pub fn onReady(payload: loader.ComponentPayload) void {
        // Access parent via payload.entity, payload.registry, payload.game
    }
};

const Workstation = struct {
    process_duration: u32 = 60,
    output_storages: []const Entity = &.{},  // Child entities created from prefab refs
};
```

In scenes/prefabs, nested entities get parent references auto-populated:
```zig
.{
    .prefab = "workstation",
    .components = .{
        .Workstation = .{
            .output_storages = .{
                .{ .prefab = "storage" },  // Storage.workstation auto-set to parent
            },
        },
    },
}
```

**Script definition** (scripts/*.zig):
```zig
pub fn init(game: *Game, scene: *Scene) void { ... }  // optional
pub fn update(game: *Game, scene: *Scene, dt: f32) void { ... }
pub fn deinit(game: *Game, scene: *Scene) void { ... }  // optional
```

**Project configuration** (project.labelle):
```zig
.{
    .version = 1,
    .name = "my_game",
    .initial_scene = "main_scene",
    .backend = .raylib,        // or .sokol
    .ecs_backend = .zig_ecs,   // or .zflecs
    .window = .{ .width = 800, .height = 600, .title = "My Game" },
    .camera = .{ .x = 0, .y = 0, .zoom = 1.0 },  // optional - default camera position
    .physics = .{  // optional - enables Box2D physics
        .enabled = true,
        .gravity = .{ 0, 980 },    // pixels/sec² (positive Y = down)
        .pixels_per_meter = 100.0, // Box2D scale factor
        .debug_draw = false,       // render collision shapes
    },
    .plugins = .{
        // Version tag (recommended for production)
        .{ .name = "labelle-tasks", .version = "0.5.0" },

        // Branch reference (development/CI)
        .{ .name = "labelle-gui", .branch = "main" },

        // Commit SHA (pinned to specific commit)
        .{ .name = "labelle-pathfinding", .commit = "abc123def456" },

        // Custom URL with fork
        .{
            .name = "labelle-tasks",
            .url = "github.com/myuser/labelle-tasks-fork",
            .branch = "my-feature",
        },
    },
}
```

**Plugin reference types** (mutually exclusive - exactly one required):

| Field | Format | Generated URL |
|-------|--------|---------------|
| `.version` | Semver string | `#v{version}` (e.g., `#v0.5.0`) |
| `.branch` | Branch name | `#{branch}` (e.g., `#main`) |
| `.commit` | 7-40 hex chars | `#{commit}` (e.g., `#abc123f`) |

**Important notes:**
- `version` is recommended for production (stable, reproducible)
- `commit` is good for CI pinning without a release tag (stable)
- `branch` requires regenerating `build.zig.zon` to pick up new commits (hash changes)
- `url` must be host/path format (no `https://` or `git+` prefix)

**Optional plugin fields:**
- `.module` - Override the module name (default: plugin name with `-` replaced by `_`)
- `.components` - Include plugin's Components in ComponentRegistryMulti
- `.bind` - Component parameterization (see below)
- `.engine_hooks` - Plugin-provided engine lifecycle hooks (see below)

**Plugin bind declarations:**

Bind allows plugins to export parameterized component types:

```zig
.plugins = .{
    .{
        .name = "labelle-tasks",
        .version = "1.0.0",
        .bind = .{
            .{ .func = "bind", .arg = "Items", .components = "Storage,Worker,Workstation" },
        },
    },
},
```

Generates: `const labelle_tasksBindItems = labelle_tasks.bind(Items);`

Components are then available as `labelle_tasksBindItems.Storage`, etc.

**Plugin engine_hooks:**

Auto-wire plugin lifecycle hooks into the engine:

```zig
.plugins = .{
    .{
        .name = "labelle-tasks",
        .version = "1.0.0",
        .bind = .{
            .{ .func = "bind", .arg = "Items", .components = "Storage,Worker" },
        },
        .engine_hooks = .{
            .create = "createEngineHooks",
            .task_hooks = "task_hooks.GameHooks",
            .item_arg = "Items",  // optional: explicit item type
        },
    },
},
```

Generates:
```zig
const labelle_tasks_engine_hooks = labelle_tasks.createEngineHooks(GameId, Items, task_hooks_hooks.GameHooks);
pub const labelle_tasksContext = labelle_tasks_engine_hooks.Context;
```

The engine hooks are automatically merged into `MergeEngineHooks`.

### Graphics Backends

Supports raylib (default) and sokol backends, selected at build time:
```bash
zig build -Dbackend=sokol
```

The `RetainedEngine` type is selected based on backend via build_options.

### ECS Backends

Supports zig_ecs (default) and zflecs backends:
```bash
zig build -Decs_backend=zflecs
```

Both backends implement a common interface defined in `src/ecs/`.

### Physics Module

Optional Box2D physics integration, enabled via `physics.enabled = true` in project.labelle.

#### ECS Integration Design Decisions

Based on benchmark results (run with `zig build bench-all` in `physics/`), these are the recommended patterns for ECS integration:

| Pattern | Recommendation | Rationale |
|---------|----------------|-----------|
| **Compound Shapes** | Shapes array in Collider | 2400x faster create, 3-5x faster update, 3x less memory |
| **Velocity Control** | Component sync for mixed R/W | 1.66x faster for read-modify-write loops vs direct methods |
| **Collision State** | Bitmask for ≤64 entities, per-entity list otherwise | Bitmask is 9x faster but limited to 64 entities |

**Compound Shapes** - Use a fixed-size shapes array within the Collider component:
```zig
const Collider = struct {
    shapes: [MAX_SHAPES]Shape = undefined,
    shape_count: usize = 0,
    // ...
};
```

**Velocity Control** - For systems that read-modify-write velocities frequently (damping, forces), use a synced Velocity component rather than direct world method calls:
```zig
// Preferred for mixed read/write patterns
for (velocities) |*v| {
    v.linear = .{ v.linear[0] * 0.99, v.linear[1] * 0.99 };
}
// Sync to Box2D once per frame
```

**Collision State** - For small entity pools (≤64), bitmasks provide excellent performance:
```zig
const CollisionMask = u64;  // Each bit = touching entity ID
```
For larger scenes, use per-entity touching lists (Option A pattern).

```bash
zig build -Dphysics=true   # Enable physics at build time
```

**Physics components** (from `engine.physics`):
- `RigidBody` - Dynamic, static, or kinematic body type
- `Collider` - Box or circle collision shape with friction/restitution
- `Velocity` - Linear and angular velocity

**Usage pattern:**
```zig
const physics = @import("labelle-physics");

// Create physics world
var physics_world = try physics.PhysicsWorld.init(allocator, .{ 0, 980 });
defer physics_world.deinit();

// Create body and collider
try physics_world.createBody(entity.toU64(), RigidBody{ .body_type = .dynamic }, .{ .x = x, .y = y });
try physics_world.addCollider(entity.toU64(), Collider{
    .shape = .{ .box = .{ .width = 50, .height = 50 } },
    .restitution = 0.4,
});

// In game loop
physics_world.update(dt);
for (physics_world.entities()) |entity_id| {
    if (physics_world.getPosition(entity_id)) |pos| {
        game.setPosition(engine.Entity.fromU64(entity_id), pos[0], pos[1]) catch {};
    }
}
```

See `usage/example_physics/` for a complete demo.

### Project Generator

The `labelle generate` command reads `project.labelle` and scans prefabs/, components/, scripts/ folders to generate:
- `.labelle/build.zig.zon` (dependencies)
- `.labelle/build.zig` (build configuration)
- `main.zig` (wires up registries and game loop - stays in project root for imports)

Uses zts templates from `src/templates/`.

The output directory can be customized via `output_dir` in `project.labelle` (default: `.labelle`).

**CLI Commands:**
- `labelle generate` - Regenerate build files
- `labelle build` - Build the project (runs from output directory)
- `labelle run` - Build and run the project
- `labelle update` - Clear caches and regenerate for current CLI version

### Entity Lifecycle

1. Scene loader creates entities via `Game.createEntity()`
2. Components added: Position, Sprite/Shape/Text, custom components
3. Visual tracked via `RenderPipeline.trackEntity()`
4. Prefab `onCreate()` hook called if defined
5. Each frame: scripts update components, `RenderPipeline.sync()` pushes dirty state to graphics
6. On destroy: prefab `onDestroy()` hook called, `RenderPipeline.untrackEntity()` removes visual

### Hook System

The engine provides a type-safe, comptime-based hook system for observing engine lifecycle events with zero runtime overhead.

**Engine hooks:**
- `game_init` / `game_deinit` - Game lifecycle
- `frame_start` / `frame_end` - Frame boundaries
- `scene_before_load` / `scene_load` / `scene_unload` - Scene transitions
- `entity_created` / `entity_destroyed` - Entity lifecycle

> **Note on `game_init`:** This hook fires during `Game.init()` before the struct is in its final memory location. Handlers should not store or use `*Game` pointers. For logic requiring a stable Game pointer, use `scene_load` or call after `game.fixPointers()`. The `game_init` payload includes an allocator for initializing subsystems.

> **Note on `scene_before_load`:** This hook fires before entities are created, providing the scene name and an allocator. Use it to initialize scene-scoped subsystems (like task engines) that components need during their `onAdd` callbacks.

**Basic usage:**
```zig
const engine = @import("labelle-engine");

// Define hook handlers
const MyHooks = struct {
    pub fn game_init(payload: engine.HookPayload) void {
        const info = payload.game_init;
        // Allocator available for early initialization
        _ = info.allocator;
        std.log.info("Game started!", .{});
    }

    pub fn scene_before_load(payload: engine.HookPayload) void {
        const info = payload.scene_before_load;
        // Initialize scene-scoped subsystems before entities are created
        // info.allocator is available for dynamic allocations
        std.log.info("Loading scene: {s}", .{info.name});
    }

    pub fn scene_load(payload: engine.HookPayload) void {
        const info = payload.scene_load;
        std.log.info("Scene loaded: {s}", .{info.name});
    }
};

// Create Game with hooks enabled
const Game = engine.GameWith(MyHooks);
```

**Hooks folder (generator):** When using the project generator, hooks are automatically scanned from the `hooks/` folder. Each `.zig` file should export public functions matching hook names:

```zig
// hooks/game_hooks.zig
const std = @import("std");
const engine = @import("labelle-engine");

pub fn game_init(payload: engine.HookPayload) void {
    const info = payload.game_init;
    // Use allocator for early subsystem initialization
    _ = info.allocator;
    std.log.info("Game started!", .{});
}

pub fn scene_load(payload: engine.HookPayload) void {
    const info = payload.scene_load;
    std.log.info("Scene loaded: {s}", .{info.name});
}
```

The generator automatically merges all hook files using `MergeEngineHooks`.

**Two-way plugin binding:** Use `MergeEngineHooks` to combine game hooks with plugin hooks:
```zig
// Plugin defines engine hooks it wants to receive
const TasksPlugin = struct {
    pub const EngineHooks = struct {
        pub fn frame_start(payload: engine.HookPayload) void {
            // Plugin updates each frame
        }
    };

    // Plugin's own hook types for game to subscribe to
    pub const Hook = enum { task_completed, task_started };
    pub const Payload = union(Hook) {
        task_completed: TaskInfo,
        task_started: TaskInfo,
    };

    pub fn Dispatcher(comptime GameHandlers: type) type {
        return engine.HookDispatcher(Hook, Payload, GameHandlers);
    }
};

// Game merges its hooks with plugin hooks
const GameHooks = struct {
    pub fn game_init(_: engine.HookPayload) void {
        std.log.info("Game started!", .{});
    }
};

// Both GameHooks.game_init AND TasksPlugin.EngineHooks.frame_start will be called
const AllHooks = engine.MergeEngineHooks(.{ GameHooks, TasksPlugin.EngineHooks });
const Game = engine.GameWith(AllHooks);

// Game subscribes to plugin events
const GameTasksHandlers = struct {
    pub fn task_completed(payload: TasksPlugin.Payload) void {
        const info = payload.task_completed;
        std.log.info("Task done: {s}", .{info.name});
    }
};
const TasksDispatcher = TasksPlugin.Dispatcher(GameTasksHandlers);

// The plugin emits events using the dispatcher:
// TasksDispatcher.emit(.{ .task_completed = .{ .name = "build_house" } });
```

See `usage/example_hooks/` for a complete two-way binding example.

### Camera System

The Game facade provides direct camera control methods:

```zig
// Single camera (primary)
game.setCameraPosition(0, 0);    // Center camera at origin
game.setCameraZoom(2.0);         // 2x zoom
game.getCamera();                // Access camera for advanced use

// Multi-camera (split-screen, minimap)
game.setupSplitScreen(.vertical_split);  // Enable split-screen
game.getCameraAt(0).setPosition(x, y);   // Control individual cameras
game.setActiveCameras(0b0011);           // Enable cameras 0 and 1
game.disableMultiCamera();               // Return to single camera
```

Camera priority: Scene `.cameras`/`.camera` overrides project `.camera` settings.

### Fullscreen and Screen Resize

The Game facade provides fullscreen control and screen resize detection:

```zig
// Fullscreen control
game.toggleFullscreen();           // Toggle between fullscreen and windowed
game.setFullscreen(true);          // Explicit fullscreen control
game.setFullscreen(false);
const is_fs = game.isFullscreen(); // Query fullscreen state

// Screen size detection
if (game.screenSizeChanged()) {
    const size = game.getScreenSize();
    // Reposition UI elements, recalculate layouts, etc.
    // size.width, size.height
}
```

**Use case: Fullscreen toggle key**
```zig
// In a script
pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    if (game.getInput().isKeyPressed(.f11)) {
        game.toggleFullscreen();
    }
}
```

Named camera slots: `main` (0), `player2` (1), `minimap` (2), `camera3` (3).

### Screenshot

Capture screenshots of the game window:

```zig
// Take a screenshot (saves to working directory)
game.takeScreenshot("screenshot.png");

// With counter for multiple screenshots
var counter: u32 = 0;
// ...
if (game.getInput().isKeyPressed(.f12)) {
    counter += 1;
    var buf: [64]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&buf, "screenshot_{d:0>4}.png", .{counter}) catch "screenshot.png";
    game.takeScreenshot(filename);
}
```

**Note:** Screenshots are captured at the end of the frame after all rendering is complete. You can call `game.takeScreenshot()` at any point in your game logic.

### Touch Input (Mobile)

The engine provides multi-touch support for iOS, Android, and touch-enabled devices:

```zig
// Check for any touch activity
if (game.isTouching()) {
    // Process all active touches
    var i: u32 = 0;
    while (i < game.getTouchCount()) : (i += 1) {
        if (game.getTouch(i)) |touch| {
            switch (touch.phase) {
                .began => handleTouchBegan(touch.x, touch.y, touch.id),
                .moved => handleTouchMoved(touch.x, touch.y, touch.id),
                .ended => handleTouchEnded(touch.x, touch.y, touch.id),
                .cancelled => handleTouchCancelled(touch.id),
            }
        }
    }
}

// Or access via Input directly
const input = game.getInput();
const count = input.getTouchCount();
```

**Touch types:**
- `Touch` - Touch point with `id`, `x`, `y`, `phase`
- `TouchPhase` - Lifecycle: `.began`, `.moved`, `.ended`, `.cancelled`
- `MAX_TOUCHES` - Maximum simultaneous touches (10)

**Backend notes:**
- **Sokol** (iOS/Android): Full touch lifecycle with proper phase tracking
- **raylib**: Touch positions available, but phases always report as `.moved`
- **SDL2**: Full touch support via finger events

### Gesture Recognition

High-level gesture detection built on top of raw touch input. Automatically updated each frame in the game loop.

**Supported gestures:**

| Gesture | Description | Data |
|---------|-------------|------|
| **Pinch** | Two-finger zoom | `scale`, `center_x`, `center_y`, `distance` |
| **Pan** | Single-finger drag | `delta_x`, `delta_y`, `x`, `y` |
| **Swipe** | Quick directional movement | `direction`, `velocity`, `start_x/y`, `end_x/y` |
| **Tap** | Quick touch and release | `x`, `y` |
| **Double Tap** | Two quick taps | `x`, `y` |
| **Long Press** | Touch held for duration | `x`, `y`, `duration` |
| **Rotation** | Two-finger twist | `angle_delta`, `angle`, `center_x`, `center_y` |

**Usage:**
```zig
pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    // Pinch to zoom
    if (game.getPinch()) |pinch| {
        const current_zoom = game.getCamera().getZoom();
        game.setCameraZoom(current_zoom * pinch.scale);
    }

    // Swipe to change scenes
    if (game.getSwipe()) |swipe| {
        if (swipe.direction == .left) {
            game.queueSceneChange("next_level");
        }
    }

    // Tap to interact
    if (game.getTap()) |tap| {
        spawnEntity(game, tap.x, tap.y);
    }

    // Pan to scroll
    if (game.getPan()) |pan| {
        const cam = game.getCamera();
        cam.setPosition(cam.getX() - pan.delta_x, cam.getY() - pan.delta_y);
    }

    // Rotation gesture
    if (game.getRotation()) |rotation| {
        rotateSelection(rotation.angle_delta);
    }
}
```

**Configuration:**
```zig
const gestures = game.getGestures();
gestures.setSwipeThreshold(50.0);       // min pixels for swipe
gestures.setLongPressDuration(0.5);     // seconds
gestures.setDoubleTapInterval(0.3);     // max seconds between taps
gestures.setPinchThreshold(5.0);        // min distance change
gestures.setRotationThreshold(0.05);    // min angle change (radians)
```

**Gesture types:**
- `Gestures` - Gesture recognizer with state tracking
- `SwipeDirection` - `.up`, `.down`, `.left`, `.right`
- `Pinch`, `Pan`, `Swipe`, `Tap`, `DoubleTap`, `LongPress`, `Rotation` - Gesture data structs

### Layer System

The engine provides three built-in layers for organizing rendering:

- `.background` - Screen-space, rendered first (behind everything)
- `.world` - World-space, camera-transformed (default for game objects)
- `.ui` - Screen-space, rendered last (always on top)

**Using layers in .zon files:**
```zig
// In scene .zon
.entities = .{
    // Background image (screen-space, doesn't move with camera)
    .{ .components = .{ .Position = .{ .x = 0, .y = 0 }, .Sprite = .{ .name = "bg.png", .layer = .background } } },
    // Game object (world-space, moves with camera)
    .{ .prefab = "player" },  // defaults to .world layer
    // UI element (screen-space, always visible)
    .{ .components = .{ .Position = .{ .x = 10, .y = 10 }, .Sprite = .{ .name = "health_bar.png", .layer = .ui } } },
}

// In prefab .zon - set default layer for all instances
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "ui_button.png", .layer = .ui },
    },
}
```

**Using layers in Shape components:**
```zig
.Shape = .{ .type = .circle, .radius = 50, .color = .{ .r = 255 }, .layer = .ui }
```

Layer behavior:
- `.background` and `.ui` use screen coordinates (fixed to screen, ignores camera)
- `.world` uses world coordinates (affected by camera position and zoom)
- Z-index within each layer determines draw order

### Sprite Sizing Modes

Sprites can be sized to fill a container using CSS-like sizing modes:

| Mode | Behavior |
|------|----------|
| `.none` | Default - use sprite's natural size |
| `.stretch` | Stretch to fill container exactly (may distort) |
| `.cover` | Scale uniformly to cover entire container (may crop) |
| `.contain` | Scale uniformly to fit inside container (may letterbox) |
| `.scale_down` | Like contain but never scales up |
| `.repeat` | Tile the sprite to fill container |

**Container options:**
- `.infer` - Infer from layer space (screen-space uses screen size)
- `.viewport` - Use full screen dimensions
- `.camera_viewport` - Use camera's visible world area
- `.{ .width = W, .height = H }` - Explicit size at origin
- `.{ .x = X, .y = Y, .width = W, .height = H }` - Explicit rectangle

**Usage in .zon files:**
```zig
// Fullscreen background that covers the screen
.{ .components = .{
    .Position = .{ .x = 0, .y = 0 },
    .Sprite = .{
        .name = "background.png",
        .layer = .background,
        .size_mode = .cover,
        .container = .viewport,
    },
}},

// Tiled background pattern
.{ .components = .{
    .Position = .{ .x = 0, .y = 0 },
    .Sprite = .{
        .name = "grass_tile.png",
        .layer = .background,
        .size_mode = .repeat,
        .container = .viewport,
    },
}},

// UI panel with explicit size
.{ .components = .{
    .Position = .{ .x = 100, .y = 100 },
    .Sprite = .{
        .name = "panel.png",
        .size_mode = .stretch,
        .container = .{ .width = 400, .height = 300 },
    },
}},
```

### GUI Module

Optional immediate-mode GUI system with multi-backend support. Currently supports raylib-based rendering (raygui backend).

**Build options:**
```bash
zig build -Dgui_backend=raygui  # Enable GUI (default: none)
```

**GUI element types:**
- `Label` - Text display
- `Button` - Clickable button with optional callback
- `ProgressBar` - Value bar (0.0-1.0)
- `Panel` - Container with background and children
- `Checkbox` - Toggle with label
- `Slider` - Value slider with min/max
- `Image` - Texture display (planned)

**Declarative GUI views (.zon files):**
```zig
// gui/hud.zon
.{
    .name = "hud",
    .elements = .{
        .{ .Label = .{ .id = "score", .text = "Score: 0", .position = .{ .x = 10, .y = 10 }, .font_size = 20 } },
        .{ .ProgressBar = .{ .id = "health", .position = .{ .x = 10, .y = 40 }, .value = 0.75 } },
        .{ .Button = .{ .id = "pause", .text = "Pause", .position = .{ .x = 350, .y = 560 }, .on_click = "onPause" } },
        .{ .Panel = .{
            .id = "stats",
            .position = .{ .x = 590, .y = 10 },
            .size = .{ .width = 200, .height = 100 },
            .children = .{
                .{ .Label = .{ .text = "FPS: 60", .position = .{ .x = 600, .y = 20 } } },
            },
        }},
    },
}
```

**Using ViewRegistry:**
```zig
const labelle = @import("labelle-engine");

// Import GUI views
const Views = labelle.ViewRegistry(.{
    .hud = @import("gui/hud.zon"),
    .pause_menu = @import("gui/pause_menu.zon"),
});

// Empty Scripts for callbacks (currently just logged)
const Scripts = struct {
    pub fn has(comptime _: []const u8) bool { return false; }
};

// In game loop - render GUI on top of scene
const re = game.getRetainedEngine();
re.beginFrame();
re.render();
game.renderGuiView(Views, Scripts, "hud");  // Render single view
re.endFrame();
```

**Scene-based GUI loading:**

Scenes can specify which GUI views to render via the `.gui_views` field:

```zig
// scenes/main.zon
.{
    .name = "main",
    .gui_views = .{"hud", "minimap"},  // Views to render with this scene
    .entities = .{ ... },
}
```

```zig
// In main.zig - load scene and render its GUI views
var scene = try Loader.load(@import("scenes/main.zon"), labelle.SceneContext.init(&game));
defer scene.deinit();

while (game.isRunning()) {
    const re = game.getRetainedEngine();
    re.beginFrame();
    re.render();
    game.renderSceneGui(&scene, Views, Scripts);  // Renders hud + minimap
    re.endFrame();
}
```

**Game API:**
```zig
game.setGuiEnabled(false);  // Disable GUI rendering
game.setGuiEnabled(true);   // Enable GUI rendering
const enabled = game.isGuiEnabled();

// Render specific view (manual)
game.renderGuiView(Views, Scripts, "hud");

// Render multiple views (manual)
game.renderGui(Views, Scripts, &.{"hud", "minimap"});

// Render views from scene's .gui_views field
game.renderSceneGui(&scene, Views, Scripts);
```

**GUI Runtime State:**

For dynamic GUI updates without redefining comptime views, use `VisibilityState` and `ValueState`:

```zig
const labelle = @import("labelle-engine");

// Visibility state for conditional rendering
var visibility_state = labelle.VisibilityState.init(allocator);
defer visibility_state.deinit();

try visibility_state.setVisible("boss_panel", is_boss_mode);  // Show/hide elements
const visible = visibility_state.isVisible("health_bar", true);  // Check with default

// Value state for runtime text/checkbox/slider updates
var value_state = labelle.ValueState.init(allocator);
defer value_state.deinit();

try value_state.setText("score_label", "Score: 1000");  // Update text
try value_state.setCheckbox("sound_enabled", true);     // Update checkbox
try value_state.setSlider("volume", 0.75);              // Update slider

const text = value_state.getText("score_label", "Score: 0");  // Get with default
const checked = value_state.getCheckbox("sound_enabled", false);
const volume = value_state.getSlider("volume", 1.0);
```

**FormBinder:**

Auto-bind form fields to a state struct:

```zig
const MonsterFormState = struct {
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,

    // Optional visibility rules
    pub fn isVisible(self: @This(), element_id: []const u8) bool {
        if (std.mem.eql(u8, element_id, "boss_options")) {
            return self.is_boss;
        }
        return true;
    }
};

const MonsterBinder = labelle.FormBinder(MonsterFormState, "monster_form");

var form_state = MonsterFormState{};
const binder = MonsterBinder.init(&form_state);

// Use binder to sync GUI <-> state
```

See `usage/example_gui/` and `usage/example_conditional_form/` for complete demos.

### Important Patterns

- Lifecycle hooks use `u64` for entity and `*anyopaque` for game to avoid circular imports
- Use `engine.entityFromU64()` and `engine.entityToU64()` for entity conversion in hooks
- `Game.fixPointers()` must be called after init when struct moves to final stack location
- Position changes require `pipeline.markPositionDirty(entity)` for sync to graphics
- Scripts support `init()` and `deinit()` lifecycle hooks for resource management
