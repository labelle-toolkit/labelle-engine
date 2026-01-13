# RFC: Shared Template Partials, Android & WASM Improvements

## Summary

Refactor the template system in `labelle-engine/tools/templates/` to extract shared code into reusable partials, reducing duplication across 9 template files. Additionally:
- Add Android platform support via a new `main_sokol_android.txt` template
- Improve WASM template with better browser integration and CLI commands

## Motivation

### Current State

The templates directory contains 9 files with significant duplication:

| Template | Lines | Purpose |
|----------|-------|---------|
| `main_raylib.txt` | 235 | Desktop (raylib) |
| `main_sdl.txt` | 194 | Desktop (SDL2) |
| `main_sokol.txt` | 350 | Desktop (sokol) |
| `main_sokol_ios.txt` | 345 | iOS (sokol) |
| `main_wasm.txt` | 266 | WebAssembly |
| `main_bgfx.txt` | 320 | Desktop (bgfx) |
| `main_zgpu.txt` | 287 | Desktop (zgpu/Dawn) |
| `main_wgpu_native.txt` | ~280 | Desktop (wgpu-native) |
| `build_zig.txt` | 306 | Build configuration |

**Estimated duplication**: ~100+ lines repeated in each `main_*.txt` file.

### Problems

1. **Maintenance burden**: Changes to registry patterns require editing 8+ files
2. **Inconsistency risk**: Templates drift apart over time (e.g., raylib has `game_id_export`, SDL doesn't)
3. **Missing platform**: No Android support despite iOS/WASM being available
4. **Feature parity**: New features (physics components, plugin binds) must be added to all templates

## Proposal

### Part 1: Shared Partials

Extract common sections into partial template files:

```
labelle-engine/tools/templates/
├── partials/
│   ├── header.txt              # Auto-generated file notice
│   ├── imports.txt             # plugin/enum/prefab/component/script imports
│   ├── registries.txt          # All registry definitions (prefab, component, script)
│   ├── hooks.txt               # Hook merging logic
│   ├── task_engine.txt         # Task engine wiring
│   ├── loader.txt              # SceneLoader setup
│   └── sokol_callbacks.txt     # Shared init/frame/cleanup/event for sokol-based
├── main_raylib.txt             # Uses .include directives
├── main_sdl.txt
├── main_sokol.txt
├── main_sokol_ios.txt
├── main_sokol_android.txt      # NEW
├── main_wasm.txt
├── main_bgfx.txt
├── main_zgpu.txt
├── main_wgpu_native.txt
├── build_zig.txt
└── build_zig_zon.txt
```

#### Partial: `partials/imports.txt`

```
.plugin_import
const {s} = @import("{s}");
.enum_import
const {s}_enum = @import("enums/{s}.zig");
.enum_export
pub const {s} = {s}_enum.{s};
.game_id_export
pub const GameId = {s};
.plugin_bind
pub const {s}Bind{s} = {s}.{s}({s});
.plugin_bind_struct_start
const {s}BindComponents = struct {{
.plugin_bind_struct_item
    pub const {s} = {s}Bind{s}.{s};
.plugin_bind_struct_end
}};
.prefab_import
const {s}_prefab = @import("prefabs/{s}.zon");
.component_import
const {s}_comp = @import("components/{s}.zig");
.component_export
pub const {s} = {s}_comp.{s};
.script_import
const {s}_script = @import("scripts/{s}.zig");
.hook_import
const {s}_hooks = @import("hooks/{s}.zig");
.main_module
const main_module = @This();
```

#### Partial: `partials/registries.txt`

```
.prefab_registry_empty
pub const Prefabs = engine.PrefabRegistry(.{{}});
.prefab_registry_start
pub const Prefabs = engine.PrefabRegistry(.{{
.prefab_registry_item
    .{s} = {s}_prefab,
.prefab_registry_end
}});
.component_registry_empty
pub const Components = engine.ComponentRegistry(struct {{
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
.physics_components
    pub const RigidBody = engine.PhysicsComponents.RigidBody;
    pub const Collider = engine.PhysicsComponents.Collider;
    pub const Velocity = engine.PhysicsComponents.Velocity;
.component_registry_empty_end
}});
.component_registry_start
pub const Components = engine.ComponentRegistry(struct {{
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
.component_registry_item
    pub const {s} = main_module.{s};
.component_registry_bind_item
    pub const {s} = {s}Bind{s}.{s};
.component_registry_physics
    pub const RigidBody = engine.PhysicsComponents.RigidBody;
    pub const Collider = engine.PhysicsComponents.Collider;
    pub const Velocity = engine.PhysicsComponents.Velocity;
.component_registry_end
}});
// ... (multi variants follow same pattern)
.script_registry_empty
pub const Scripts = engine.ScriptRegistry(struct {{}});
.script_registry_start
pub const Scripts = engine.ScriptRegistry(struct {{
.script_registry_item
    pub const {s} = {s}_script;
.script_registry_end
}});
```

#### Partial: `partials/hooks.txt`

```
.plugin_engine_hooks
const {s}_engine_hooks = {s}.{s}(GameId, {s}, {s}_hooks.{s});
pub const {s}Context = {s}_engine_hooks.Context;
.hooks_empty
const Game = engine.Game;
.hooks_start
const Hooks = engine.MergeEngineHooks(.{{
.hooks_item
    {s}_hooks,
.hooks_plugin_item
    {s}_engine_hooks,
.hooks_end
}});
const Game = engine.GameWith(Hooks);
```

#### Partial: `partials/task_engine.txt`

```
.task_engine_empty

.task_engine_start
const TaskHooks = {s}.hooks.MergeTasksHooks({s}, {s}, .{{
.task_engine_hook_item
    {s}_hooks,
.task_engine_end
}});
const TaskDispatcher = {s}.hooks.HookDispatcher({s}, {s}, TaskHooks);
pub const TaskEngine = {s}.EngineWithHooks({s}, {s}, TaskDispatcher);
```

#### Partial: `partials/loader.txt`

```
.loader
pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
pub const initial_scene = @import("scenes/{s}.zon");
```

#### Partial: `partials/sokol_state.txt`

Shared between sokol, sokol_ios, sokol_android, wasm:

```
.state
const State = struct {{
    allocator: std.mem.Allocator = undefined,
    game: ?*Game = null,
    scene: ?*engine.Scene = null,
    initialized: bool = false,
    should_quit: bool = false,
    ci_test: bool = false,
    frame_count: u32 = 0,
}};

var state: State = .{{}};
var game_storage: Game = undefined;
var scene_storage: engine.Scene = undefined;
```

### Part 2: Android Template

Create `main_sokol_android.txt` based on the iOS template with Android-specific adjustments:

```zig
.header
// ============================================================================
// AUTO-GENERATED FILE - DO NOT EDIT
// ============================================================================
// This file is generated by labelle-engine from project.labelle
// Project: {s}
//
// Any manual changes will be overwritten on next generation.
//
// To regenerate: zig build generate
// To modify settings: edit project.labelle instead
//
// This project uses the sokol backend with callback-based architecture for Android.
// The main loop is driven by sokol_app callbacks (init, frame, cleanup, event).
// Project configuration is embedded at compile time for Android compatibility.
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");

// Sokol bindings - re-exported from engine for Android callback architecture
const sokol = engine.sokol;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;

.include partials/imports.txt
.include partials/registries.txt
.include partials/hooks.txt
.include partials/task_engine.txt
.include partials/loader.txt
.include partials/sokol_state.txt

.init_cb
export fn init() void {{
    // Android logging
    std.log.info("Initializing labelle-engine on Android", .{{}});

    sg.setup(.{{
        .environment = sokol.glue.environment(),
        .logger = .{{ .func = sokol.log.func }},
    }});

    sgl.setup(.{{
        .logger = .{{ .func = sokol.log.func }},
    }});

    state.allocator = std.heap.page_allocator;

    // Initialize game with embedded config (Android uses APK assets)
    game_storage = Game.init(state.allocator, .{{
        .window = .{{
            .width = {d},
            .height = {d},
            .title = "{s}",
            .target_fps = {d},
        }},
        .clear_color = .{{ .r = 30, .g = 35, .b = 45 }},
    }}) catch |err| {{
        std.log.err("Failed to initialize game: {{}}", .{{err}});
        sapp.quit();
        return;
    }};
    state.game = &game_storage;
    state.game.?.fixPointers();

.camera_config
    state.game.?.setCameraPosition({d:.1}, {d:.1});
    state.game.?.setCameraZoom({d:.2});
.camera_config_end

    const ctx = engine.SceneContext.init(state.game.?);

    Game.HookDispatcher.emit(.{{ .scene_before_load = .{{ .name = initial_scene.name, .allocator = state.allocator }} }});

    scene_storage = Loader.load(initial_scene, ctx) catch |err| {{
        std.log.err("Failed to load scene: {{}}", .{{err}});
        sapp.quit();
        return;
    }};
    state.scene = &scene_storage;

    Game.HookDispatcher.emit(.{{ .scene_load = .{{ .name = initial_scene.name }} }});

    state.initialized = true;
    std.log.info("Sokol Android backend initialized. Screen: {{}}x{{}}", .{{ sapp.width(), sapp.height() }});
}}

.frame_cb
export fn frame() void {{
    if (!state.initialized or state.game == null or state.scene == null) return;

    state.frame_count += 1;

    const dt: f32 = @floatCast(sapp.frameDuration());

    state.scene.?.update(dt);
    state.game.?.getPipeline().sync(state.game.?.getRegistry());

    var pass_action: sg.PassAction = .{{}};
    pass_action.colors[0] = .{{
        .load_action = .CLEAR,
        .clear_value = .{{ .r = 0.118, .g = 0.137, .b = 0.176, .a = 1.0 }},
    }};
    sg.beginPass(.{{
        .action = pass_action,
        .swapchain = sokol.glue.swapchain(),
    }});

    const re = state.game.?.getRetainedEngine();
    re.beginFrame();
    re.render();
    re.endFrame();

    sg.endPass();
    sg.commit();
}}

.cleanup_cb
export fn cleanup() void {{
    if (state.initialized and state.game != null) {{
        if (state.game.?.getCurrentSceneName() == null) {{
            Game.HookDispatcher.emit(.{{ .scene_unload = .{{ .name = initial_scene.name }} }});
        }}
    }}

    if (state.scene) |scene| {{
        scene.deinit();
        state.scene = null;
    }}

    if (state.game) |game| {{
        game.deinit();
        state.game = null;
    }}

    sgl.shutdown();
    sg.shutdown();

    std.log.info("Sokol Android backend cleanup complete.", .{{}});
}}

.event_cb
export fn event(ev: ?*const sapp.Event) void {{
    const e = ev orelse return;

    switch (e.type) {{
        // Android touch events
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {{
            // Forward to game input system
            if (state.game) |game| {{
                // TODO: game.handleTouchEvent(e);
                _ = game;
            }}
        }},
        // Android back button
        .KEY_DOWN => {{
            if (e.key_code == .ESCAPE) {{
                // Back button on Android maps to ESCAPE
                // Could emit app_background hook or quit
                sapp.quit();
            }}
        }},
        // Android lifecycle events
        .SUSPENDED => {{
            std.log.info("App suspended (going to background)", .{{}});
            // TODO: Emit app_suspended hook, pause audio, save state
        }},
        .RESUMED => {{
            std.log.info("App resumed (coming to foreground)", .{{}});
            // TODO: Emit app_resumed hook, resume audio
        }},
        .QUIT_REQUESTED => {{
            std.log.info("Quit requested", .{{}});
            sapp.quit();
        }},
        else => {{}},
    }}
}}

.main_fn
pub fn main() void {{
    sapp.run(.{{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = {d},
        .height = {d},
        .window_title = "{s}",
        .high_dpi = true,
        .fullscreen = true,  // Android apps are typically fullscreen
        .icon = .{{ .sokol_default = true }},
        .logger = .{{ .func = sokol.log.func }},
        // Android-specific
        .android_native_activity = true,
    }});
}}
```

### Part 3: Generator Changes

Update `generator.zig` to support:

1. **Include directive parsing**: `.include partials/foo.txt` inlines the partial
2. **Backend detection for Android**: `backend = .sokol_android` in project.labelle
3. **Build configuration**: Add Android NDK linking to `build_zig.txt`

#### New Backend Enum

```zig
pub const Backend = enum {
    raylib,
    sokol,
    sokol_ios,
    sokol_android,  // NEW
    sdl,
    bgfx,
    zgpu,
    wgpu_native,
    wasm,
};
```

#### CLI Support

Add to labelle-cli:

```bash
labelle android build          # Build APK
labelle android install        # Install to connected device
labelle android run            # Build, install, and launch
labelle android studio         # Generate Android Studio project (optional)
```

### Part 4: Build Template Changes

Add Android section to `build_zig.txt`:

```zig
.android_exe_start
    // Android builds use sokol with OpenGL ES backend
    const exe_mod = b.createModule(.{{
        .root_source_file = b.path("../main.zig"),
        .target = target,
        .optimize = optimize,
    }});
    exe_mod.addImport("labelle-engine", engine_mod);
.android_exe_end

.android_exe_final
    const exe = b.addSharedLibrary(.{{
        .name = "{s}",
        .root_module = exe_mod,
    }});

    // Link Android system libraries
    exe.linkSystemLibrary("android");
    exe.linkSystemLibrary("log");
    exe.linkSystemLibrary("EGL");
    exe.linkSystemLibrary("GLESv3");
```

### Part 5: WASM Template Improvements

The existing `main_wasm.txt` template works but needs enhancements for production use.

#### Current WASM Template Issues

1. **Hardcoded canvas selector**: `html5_canvas_selector = "#canvas"`
2. **No asset loading**: Textures/atlases need browser fetch or embed
3. **No resize handling**: Canvas doesn't respond to window resize
4. **Missing browser APIs**: No audio context initialization, no fullscreen API

#### Enhanced WASM Template

Update `main_wasm.txt` with browser-specific features:

```zig
.header
// ============================================================================
// AUTO-GENERATED FILE - DO NOT EDIT
// ============================================================================
// This file is generated by labelle-engine from project.labelle
// Project: {s}
//
// Any manual changes will be overwritten on next generation.
//
// To regenerate: zig build generate
// To modify settings: edit project.labelle instead
//
// WASM BUILD - Uses sokol callbacks for browser compatibility.
// Config is embedded at compile time (no runtime file I/O).
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");

const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;

.include partials/imports.txt
.include partials/registries.txt
.include partials/hooks.txt
.include partials/task_engine.txt
.include partials/loader.txt

.game_id
pub const GameId = u64;

.state
var game_storage: Game = undefined;
var scene_storage: engine.Scene = undefined;
var state: struct {{
    game: ?*Game = null,
    scene: ?*engine.Scene = null,
    initialized: bool = false,
    frame_count: u32 = 0,
    canvas_width: i32 = {d},
    canvas_height: i32 = {d},
}} = .{{}};

.init_cb
export fn init() void {{
    sg.setup(.{{
        .environment = sokol.glue.environment(),
        .logger = .{{ .func = sokol.log.func }},
    }});

    sgl.setup(.{{
        .logger = .{{ .func = sokol.log.func }},
    }});

    const allocator = std.heap.page_allocator;

    game_storage = Game.init(allocator, .{{
        .window = .{{
            .width = {d},
            .height = {d},
            .title = "{s}",
            .target_fps = {d},
        }},
        .clear_color = .{{ .r = 30, .g = 35, .b = 45 }},
    }}) catch |err| {{
        std.log.err("Failed to initialize game: {{}}", .{{err}});
        sapp.quit();
        return;
    }};
    state.game = &game_storage;
    state.game.?.fixPointers();

.camera_config
    state.game.?.setCameraPosition({d:.1}, {d:.1});
    state.game.?.setCameraZoom({d:.2});
.camera_config_end

    const ctx = engine.SceneContext.init(state.game.?);

    Game.HookDispatcher.emit(.{{ .scene_before_load = .{{ .name = initial_scene.name, .allocator = allocator }} }});

    scene_storage = Loader.load(initial_scene, ctx) catch |err| {{
        std.log.err("Failed to load scene: {{}}", .{{err}});
        sapp.quit();
        return;
    }};
    state.scene = &scene_storage;

    Game.HookDispatcher.emit(.{{ .scene_load = .{{ .name = initial_scene.name }} }});

    state.initialized = true;

    // Log to browser console
    std.log.info("WASM game initialized! Canvas: {{}}x{{}}", .{{ sapp.width(), sapp.height() }});
}}

.frame_cb
export fn frame() void {{
    if (!state.initialized or state.game == null or state.scene == null) return;

    state.frame_count += 1;

    // Check for canvas resize
    const current_width = sapp.width();
    const current_height = sapp.height();
    if (current_width != state.canvas_width or current_height != state.canvas_height) {{
        state.canvas_width = current_width;
        state.canvas_height = current_height;
        // Notify game of resize
        if (state.game) |game| {{
            game.handleResize(current_width, current_height);
        }}
    }}

    const dt: f32 = @floatCast(sapp.frameDuration());

    state.scene.?.update(dt);
    state.game.?.getPipeline().sync(state.game.?.getRegistry());

    var pass_action: sg.PassAction = .{{}};
    pass_action.colors[0] = .{{
        .load_action = .CLEAR,
        .clear_value = .{{ .r = 0.118, .g = 0.137, .b = 0.176, .a = 1.0 }},
    }};
    sg.beginPass(.{{
        .action = pass_action,
        .swapchain = sokol.glue.swapchain(),
    }});

    const re = state.game.?.getRetainedEngine();
    re.beginFrame();
    re.render();
    re.endFrame();

    sg.endPass();
    sg.commit();
}}

.cleanup_cb
export fn cleanup() void {{
    if (state.initialized and state.game != null) {{
        Game.HookDispatcher.emit(.{{ .scene_unload = .{{ .name = initial_scene.name }} }});
    }}

    if (state.scene) |scene| {{
        scene.deinit();
        state.scene = null;
    }}

    if (state.game) |game| {{
        Game.HookDispatcher.emit(.{{ .game_deinit = .{{}} }});
        game.deinit();
        state.game = null;
    }}

    sgl.shutdown();
    sg.shutdown();
}}

.event_cb
export fn event(ev: [*c]const sapp.Event) void {{
    const e = ev orelse return;

    switch (e.type) {{
        // Mouse events (desktop browser)
        .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE => {{
            if (state.game) |game| {{
                _ = game;
                // TODO: game.handleMouseEvent(e);
            }}
        }},
        // Touch events (mobile browser)
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {{
            if (state.game) |game| {{
                _ = game;
                // TODO: game.handleTouchEvent(e);
            }}
        }},
        // Keyboard
        .KEY_DOWN, .KEY_UP => {{
            if (state.game) |game| {{
                _ = game;
                // TODO: game.handleKeyEvent(e);
            }}
        }},
        // Browser visibility change
        .SUSPENDED => {{
            std.log.info("Tab hidden / page suspended", .{{}});
        }},
        .RESUMED => {{
            std.log.info("Tab visible / page resumed", .{{}});
        }},
        else => {{}},
    }}
}}

.main
pub fn main() void {{
    sapp.run(.{{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = {d},
        .height = {d},
        .window_title = "{s}",
        .logger = .{{ .func = sokol.log.func }},
        .html5_canvas_selector = "{s}",  // Configurable canvas selector
        .html5_canvas_resize = true,      // Auto-resize with container
        .html5_preserve_drawing_buffer = false,
        .html5_premultiplied_alpha = true,
        .html5_ask_leave_site = false,    // Set true for games with save state
    }});
}}
```

#### HTML Shell Template

Add `templates/wasm_shell.html`:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>{PROJECT_NAME}</title>
    <style>
        * {{ margin: 0; padding: 0; }}
        html, body {{
            width: 100%;
            height: 100%;
            overflow: hidden;
            background: #1e2329;
        }}
        #canvas {{
            width: 100%;
            height: 100%;
            display: block;
        }}
        #loading {{
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            color: #888;
            font-family: sans-serif;
        }}
    </style>
</head>
<body>
    <canvas id="canvas"></canvas>
    <div id="loading">Loading...</div>
    <script>
        // Hide loading indicator when WASM starts
        window.addEventListener('load', () => {{
            document.getElementById('loading').style.display = 'none';
        }});
    </script>
    <script src="{PROJECT_NAME}.js"></script>
</body>
</html>
```

#### WASM Build Template Addition

Add to `build_zig.txt`:

```zig
.wasm_exe_start
    const exe_mod = b.createModule(.{{
        .root_source_file = b.path("../main.zig"),
        .target = b.resolveTargetQuery(.{{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        }}),
        .optimize = optimize,
    }});
    exe_mod.addImport("labelle-engine", engine_mod);

    // Get sokol for WASM
    const labelle_dep = engine_dep.builder.dependency("labelle-gfx", .{{
        .target = target,
        .optimize = optimize,
    }});
    const sokol_dep = labelle_dep.builder.dependency("sokol", .{{
        .target = target,
        .optimize = optimize,
    }});
    exe_mod.addImport("sokol", sokol_dep.module("sokol"));
.wasm_exe_end

.wasm_exe_final
    const exe = b.addExecutable(.{{
        .name = "{s}",
        .root_module = exe_mod,
    }});

    // Emscripten settings
    exe.link_args = &.{{
        "-sUSE_WEBGL2=1",
        "-sFULL_ES3=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sSTACK_SIZE=1048576",  // 1MB stack
        "-sINITIAL_MEMORY=67108864",  // 64MB initial
    }};
```

#### WASM CLI Commands

Add to labelle-cli:

```bash
labelle wasm build             # Build WASM + JS + HTML
labelle wasm serve             # Build and start local dev server (port 8080)
labelle wasm serve --port 3000 # Custom port
labelle wasm clean             # Remove WASM build artifacts
labelle wasm optimize          # Build with -Doptimize=ReleaseSmall + wasm-opt
```

#### Project Configuration for WASM

Add WASM-specific options to `project.labelle`:

```zig
.{
    .name = "my_game",
    .backend = .wasm,
    // ... other config ...

    .wasm = .{
        .canvas_selector = "#game-canvas",  // Default: "#canvas"
        .initial_memory_mb = 64,            // Default: 64
        .allow_memory_growth = true,        // Default: true
        .shell_template = "custom.html",    // Default: built-in template
        .embed_assets = true,               // Embed textures in WASM (default: false)
    },
}
```

## Implementation Plan

### Phase 1: Extract Partials (non-breaking)

1. Create `partials/` directory
2. Extract common sections into partial files
3. Update generator to support `.include` directive
4. Refactor existing templates to use includes
5. Verify all backends still generate correctly

### Phase 2: Android Template

1. Create `main_sokol_android.txt`
2. Add `sokol_android` backend option
3. Update build template with Android linking
4. Test on Android emulator

### Phase 3: WASM Improvements

1. Enhance `main_wasm.txt` with resize handling and lifecycle events
2. Add HTML shell template (`wasm_shell.html`)
3. Add WASM-specific project.labelle options
4. Update build template with Emscripten settings

### Phase 4: CLI Integration

1. Add `labelle android` commands to labelle-cli
2. Add `labelle wasm` commands (build, serve, optimize)
3. Document Android setup requirements (NDK path, etc.)
4. Add example projects for both platforms

## Compatibility

- **Backward compatible**: Existing projects continue to work
- **No API changes**: Project.labelle format unchanged (new backend value only)
- **Generator internal**: Partial extraction is implementation detail

## Testing

### Partials
1. Generate projects for all backends, verify output unchanged
2. Diff generated output before/after refactor

### Android
3. Build and run on Android emulator (API 24+)
4. Test touch input on physical Android device
5. Verify lifecycle events (suspend/resume, back button)
6. Test with different screen densities

### WASM
7. Build and test in Chrome, Firefox, Safari
8. Test canvas resize behavior
9. Test on mobile browsers (iOS Safari, Chrome Android)
10. Verify `labelle wasm serve` works correctly
11. Test asset loading (embedded vs. fetched)

## Open Questions

### Partials
1. Should `.include` be recursive (partials including partials)?
2. Should partials support conditional sections (e.g., `#if physics`)?

### Android
3. Should we support Android Studio project generation, or just APK builds?
4. Minimum Android API level? (Suggest API 24 / Android 7.0)
5. Asset loading on Android - embed in APK or separate asset directory?

### WASM
6. Should `labelle wasm serve` use a built-in HTTP server or require Python/Node?
7. Asset loading strategy - embed in WASM binary, fetch from server, or both?
8. Should we support `wasm-opt` optimization automatically if installed?
9. Progressive Web App (PWA) support - generate manifest.json and service worker?

## References

### Sokol
- [sokol_app platforms](https://github.com/floooh/sokol#sokol_appph) - Android, iOS, WASM support
- [sokol samples](https://github.com/floooh/sokol-samples) - Cross-platform examples

### Android
- [Zig cross-compilation](https://ziglang.org/documentation/master/#Cross-compiling)
- [Android NDK](https://developer.android.com/ndk)
- Existing iOS template: `main_sokol_ios.txt`

### WASM
- [Emscripten](https://emscripten.org/) - WASM toolchain
- [sokol WASM samples](https://floooh.github.io/sokol-html5/) - Live demos
- [WebGL2 spec](https://www.khronos.org/webgl/)
- Existing WASM template: `main_wasm.txt`
