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
        // Shape entity (position inside .shape block):
        .{ .shape = .{ .type = .circle, .x = 100, .y = 100, .radius = 50, .color = .{ .r = 255 } } },
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
}
```

**Pivot values:**
`.center`, `.top_left`, `.top_center`, `.top_right`, `.center_left`, `.center_right`, `.bottom_left`, `.bottom_center`, `.bottom_right`, `.custom`

For `.custom`, also specify `.pivot_x` and `.pivot_y` (0.0-1.0).

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
}
```

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

### Project Generator

The `zig build generate` command reads `project.labelle` and scans prefabs/, components/, scripts/ folders to generate:
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

Named camera slots: `main` (0), `player2` (1), `minimap` (2), `camera3` (3).

### Important Patterns

- Lifecycle hooks use `u64` for entity and `*anyopaque` for game to avoid circular imports
- Use `engine.entityFromU64()` and `engine.entityToU64()` for entity conversion in hooks
- `Game.fixPointers()` must be called after init when struct moves to final stack location
- Position changes require `pipeline.markPositionDirty(entity)` for sync to graphics
- Scripts support `init()` and `deinit()` lifecycle hooks for resource management
