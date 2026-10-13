# labelle-engine

Declarative 2D game engine for Zig with comptime scenes, ECS abstraction, prefabs, and scripts.

Part of the [labelle-toolkit](https://github.com/labelle-toolkit) ecosystem.

## Features

- **Declarative Scenes** — define entities in `.zon` files at compile time, no runtime parsing
- **ECS Abstraction** — pluggable backends (zig-ecs, zflecs, mr-ecs) behind a unified interface
- **Prefab System** — reusable entity templates with comptime registries
- **Script System** — lifecycle hooks (init, update, deinit) for game logic
- **Scene Loader** — automatic entity spawning with component assignment, nested entities, and parent-child hierarchies
- **GUI Views** — declarative UI definitions bound to scenes
- **Hook System** — type-safe, zero-overhead lifecycle hooks
- **Game Events** — buffered `emit` plus fallible `tryEmit` for producers that must observe a dropped notification ([guide](rfc/EVENTS-FALLIBLE-ENQUEUE.md))
- **Input & Gestures** — abstracted input handling with gesture recognition
- **Audio** — audio playback types and management
- **Query System** — ECS queries with filtering and iteration

## Requirements

- Zig 0.15.2+
- [labelle-core](https://github.com/labelle-toolkit/labelle-core) (sibling dependency)

## Build

```bash
zig build        # build the library
zig build test   # run tests (64 tests)
```

## Project Structure

```
src/
  game.zig          # Core game loop and lifecycle
  scene.zig         # Scene management
  query.zig         # ECS query abstraction
  input.zig         # Input handling
  audio.zig         # Audio system
  gui.zig           # GUI runtime
  gestures.zig      # Gesture recognition
  hooks_types.zig   # Hook system types
  form_binder.zig   # Form data binding
scene/
  src/
    core.zig        # Scene runtime (entities, scripts)
    loader.zig      # Scene loader (comptime entity spawning)
    prefab.zig      # Prefab registry and instantiation
    script.zig      # Script function table
    types.zig       # Scene configuration types
test/               # 64 tests across 9 test files
```

## Usage with labelle-cli

The recommended way to use this engine is through the [labelle-cli](https://github.com/labelle-toolkit/labelle-cli):

```bash
# Install the CLI
curl -fsSL https://labelle.games/install.sh | bash

# Create a new project
labelle init my-game --backend=raylib --ecs=zig_ecs

# Build and run
cd my-game && labelle run
```

## Reference documents

| Document | Covers |
|----------|--------|
| [HOOK-DELIVERY-CONTRACT.md](HOOK-DELIVERY-CONTRACT.md) | When hooks and events are delivered: drain points, ordering, handler-emitted timing, payload lifetime/ownership, scene-reset and shutdown behaviour, and the lifecycle caveats. |

## Integration

labelle-engine works with other labelle-toolkit libraries:

| Library | Role |
|---------|------|
| [labelle-core](https://github.com/labelle-toolkit/labelle-core) | Shared types, ECS interface, components |
| [labelle-gfx](https://github.com/labelle-toolkit/labelle-gfx) | 2D rendering, animations, cameras |
| [labelle-cli](https://github.com/labelle-toolkit/labelle-cli) | Project scaffolding and build orchestration |

## License

See [LICENSE](LICENSE) for details.

## Custom mouse pointers

Game scripts use `game.setCursorVisible(visible) bool` and
`game.isCursorOverWindow() bool`. They never import a platform window backend.
The visibility call is synchronous: a false result means the pointer could not
be hidden, so do not draw a replacement. The query is false outside the focused
game surface or on an unsupported/touch-only backend.

For a script's draw callback:

```zig
pub fn drawGui(game: anytype) void {
    const show = game.isCursorOverWindow();
    if (!game.setCursorVisible(!show) or !show) return;
    // Draw your cursor artwork on the GUI foreground layer, with its scaled
    // hotspot at the GUI mouse position. Keep ImGui MouseDrawCursor disabled.
}
```

The overlay and its mouse coordinates must use the same space. For design-space
rendering use `game.getMouseDesign()`; for an ImGui foreground overlay use ImGui's
mouse position. Do not apply the world camera to the pointer. Restore with
`game.setCursorVisible(true)` before disabling the overlay. Game teardown and
rebinding also restore the previous pointer.

The host binds once, after creating the window and before script setup:
`game.bindCursorWindow(window)`. The companion assembler change generates this
call for both loop and callback platforms, guarded for older engines. Handwritten
hosts must bind explicitly. Without binding, both methods return false safely.
The core dependency must include `CursorControls`; older window backends need no
changes. labelle-bgfx's companion implementation supports desktop and web.
