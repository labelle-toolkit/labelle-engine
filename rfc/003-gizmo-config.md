# RFC 003: Decouple Gizmos from Prefabs and Scenes

**Status**: Draft
**Issue**: [#319](https://github.com/labelle-toolkit/labelle-engine/issues/319)
**Date**: 2026-03-03

## Problem

Gizmo definitions are embedded inline in prefab and scene `.zon` files via
`.gizmos` blocks. This couples debug visualization config to game data and
creates three concrete issues:

1. **Runtime-created entities never get gizmos.** `instantiatePrefab()` skips
   gizmo creation entirely. Entities created via `registry.createEntity()` +
   manual component adds (common in game scripts) have no path to gizmos at all.

2. **Save/load breaks gizmos.** Gizmo entities are transient ECS entities
   created during scene loading. After restoring game state, dynamic entities
   lose their gizmos and there is no API to recreate them.

3. **Debug data pollutes game data.** Prefab `.zon` files mix gizmo definitions
   (debug-only, stripped in release) with actual game components, violating
   separation of concerns.

## Current Architecture

```
prefab.zon
  .components = { Position, Sprite, Workstation { .storages = .{ .{ .components, .gizmos }, ... } } }
  .gizmos = { Text, Shape, BoundingBox }
```

- `loadPrefabEntity()` reads `.gizmos` from the prefab/scene definition and
  calls `createGizmoEntities()` to create separate ECS entities with `Gizmo`
  marker + visual component (Text, Shape, Icon, BoundingBox).
- `Gizmo.parent_entity` links gizmo to parent; position resolved as
  `parent_pos + offset` each frame in `RenderPipeline.resolveGfxPosition()`.
- `instantiatePrefab()` does NOT create gizmos.
- Nested child entities (e.g., workstation storage slots) can also have
  `.gizmos` defined inline in their array entries.
- `PrefabRegistry` exposes `hasGizmos()` / `getGizmos()` for fallback lookup.

### Touch Points

| File | Role |
|------|------|
| `scene/src/loader.zig` | `loadPrefabEntity()` and `loadComponentEntity()` read `.gizmos` |
| `scene/src/loader/entity_components.zig` | `createGizmoEntities()` and `createChildEntity()` |
| `scene/src/prefab.zig` | `PrefabRegistry.hasGizmos()` / `getGizmos()` |
| `render/src/components.zig` | `Gizmo` struct, `GizmoVisibility` enum |
| `render/src/pipeline.zig` | `resolveGfxPosition()` for parent-relative positioning |
| `engine/game/gizmos.zig` | Visibility management, standalone gizmo drawing |
| `tools/generator/` | Project generator — scans dirs, generates registries |

## Proposed Architecture

```
project-root/
├── prefabs/
│   ├── oven.zon          # components only, no .gizmos
│   └── baker.zon
├── gizmos/               # NEW — gizmo config per prefab
│   ├── oven.zon
│   └── baker.zon
```

Gizmo definitions move to a `gizmos/` directory with one `.zon` file per prefab.
The project generator scans this directory and builds a `GizmoRegistry` (same
pattern as `PrefabRegistry`). The scene loader and `instantiatePrefab()` both
use `GizmoRegistry` to create gizmo entities.

### Gizmo File Format

Simple prefab (no children):

```zig
// gizmos/baker.zon
.{
    .entity = .{
        .Text = .{ .text = "Baker", .size = 12, .y = -25,
                    .color = .{ .r = 255, .g = 255, .b = 0, .a = 255 } },
        .Shape = .{ .shape = .{ .circle = .{ .radius = 3 } },
                    .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    },
}
```

Prefab with nested child entities:

```zig
// gizmos/oven.zon
.{
    .entity = .{
        .Text = .{ .text = "Oven", .size = 14, .y = -40,
                    .color = .{ .r = 255, .g = 100, .b = 100, .a = 255 } },
    },
    .children = .{
        .storages = .{
            .{ .Text = .{ .text = "EIS-F", .size = 12, .y = 30,
                          .color = .{ .r = 100, .g = 200, .b = 100, .a = 255 } } },
            .{ .Text = .{ .text = "EIS-W", .size = 12, .y = 30,
                          .color = .{ .r = 100, .g = 200, .b = 100, .a = 255 } } },
            // ... indexed by position in the component array
        },
    },
}
```

- `.entity` — gizmos for the top-level prefab entity (required)
- `.children` — gizmos for nested child entities (optional)
  - Keyed by the component field name (e.g., `.storages`)
  - Array-indexed to match the component array positions

### GizmoRegistry

New comptime type, same pattern as `PrefabRegistry`:

```zig
pub fn GizmoRegistry(comptime gizmo_map: anytype) type {
    return struct {
        pub fn has(comptime name: []const u8) bool {
            return @hasField(@TypeOf(gizmo_map), name);
        }

        pub fn get(comptime name: []const u8) @TypeOf(@field(gizmo_map, name)) {
            return @field(gizmo_map, name);
        }

        /// Returns the .entity gizmos for a prefab, or null if none.
        pub fn getEntityGizmos(comptime name: []const u8) ... {
            const data = get(name);
            if (@hasField(@TypeOf(data), "entity")) return data.entity;
            return null;
        }

        /// Returns the .children gizmos for a prefab, or null if none.
        pub fn getChildrenGizmos(comptime name: []const u8) ... {
            const data = get(name);
            if (@hasField(@TypeOf(data), "children")) return data.children;
            return null;
        }
    };
}
```

Generated in `main.zig`:

```zig
pub const Gizmos = engine.GizmoRegistry(.{
    .baker = @import("gizmos/baker.zon"),
    .oven = @import("gizmos/oven.zon"),
    .flour = @import("gizmos/flour.zon"),
    .water = @import("gizmos/water.zon"),
    .bread = @import("gizmos/bread.zon"),
    .water_well = @import("gizmos/water_well.zon"),
});
```

### SceneLoader Changes

`SceneLoader` gains a 4th comptime parameter:

```zig
// Before:
pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

// After:
pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts, Gizmos);
```

### Loader Behavior Changes

**`loadPrefabEntity()`** — reads gizmos from `GizmoRegistry` instead of inline:

```zig
// Before:
if (@hasField(@TypeOf(entity_def), "gizmos")) {
    try Ops.createGizmoEntities(..., entity_def.gizmos, ...);
} else if (comptime Prefabs.hasGizmos(prefab_name)) {
    try Ops.createGizmoEntities(..., Prefabs.getGizmos(prefab_name), ...);
}

// After:
if (comptime GizmoReg.has(prefab_name)) {
    if (comptime GizmoReg.getEntityGizmos(prefab_name)) |gizmos| {
        try Ops.createGizmoEntities(..., gizmos, ...);
    }
}
```

**`createChildEntity()`** — reads child gizmos from `GizmoRegistry`:

```zig
// Before:
if (@hasField(@TypeOf(entity_def), "gizmos")) {
    try createGizmoEntities(..., entity_def.gizmos, ...);
}

// After:
if (comptime GizmoReg.has(prefab_name)) {
    if (comptime GizmoReg.getChildrenGizmos(prefab_name)) |children| {
        if (@hasField(@TypeOf(children), field_name)) {
            const array = @field(children, field_name);
            if (child_index < array.len) {
                try createGizmoEntities(..., array[child_index], ...);
            }
        }
    }
}
```

**`instantiatePrefab()`** — now creates gizmos (currently skipped):

```zig
// After component creation:
if (comptime GizmoReg.has(prefab_name)) {
    if (comptime GizmoReg.getEntityGizmos(prefab_name)) |gizmos| {
        try Ops.createGizmoEntities(game, scene, entity, gizmos, x, y, &ready_queue);
    }
}
```

### Public API for Runtime Gizmo Creation

New function on `SceneLoader` for game code to create gizmos on manually-created
entities:

```zig
pub fn createGizmosForEntity(
    comptime prefab_name: []const u8,
    game: *Game,
    scene: *Scene,
    entity: Entity,
) !void {
    if (comptime !GizmoReg.has(prefab_name)) return;
    if (builtin.mode != .Debug) return;

    const pos = game.getRegistry().tryGet(Position, entity) orelse return;
    var ready_queue = std.ArrayList(ReadyCallbackEntry).init(game.allocator);
    defer ready_queue.deinit();

    if (comptime GizmoReg.getEntityGizmos(prefab_name)) |gizmos| {
        try Ops.createGizmoEntities(game, scene, entity, gizmos, pos.x, pos.y, &ready_queue);
    }
}
```

Usage in game scripts:

```zig
// Production system after creating a flour item:
const item_entity = registry.createEntity();
registry.add(item_entity, Item{ .item_type = .flour });
// ...
try Loader.createGizmosForEntity("flour", game, scene, item_entity);

// Save/load after restoring a dynamic entity:
try Loader.createGizmosForEntity("flour", game, scene, restored_entity);
```

### Breaking Change

This is a breaking change. Inline `.gizmos` blocks in prefab and scene `.zon`
files are no longer supported. All gizmo definitions must move to the `gizmos/`
directory. The `SceneLoader` signature changes from 3 to 4 comptime parameters.

All existing projects must:
1. Create a `gizmos/` directory with per-prefab `.zon` files
2. Remove `.gizmos` blocks from all prefab and scene `.zon` files
3. Regenerate with `zig build generate`

### Project Generator Changes

1. **Scan `gizmos/` directory** — add `scanZonFolder("gizmos/")` alongside
   existing prefab/component/script scans.
2. **Generate `GizmoRegistry`** — emit imports and registry struct in `main.zig`,
   same pattern as `PrefabRegistry`.
3. **Copy `gizmos/` to target dirs** — add `"gizmos"` to `dirs_to_copy` array.
4. **Pass `Gizmos` to `SceneLoader`** — change the `Loader` line in generated
   `main.zig` to include the 4th parameter.
5. **When no `gizmos/` directory exists** — generate an empty `GizmoRegistry(.{})`.

### Cleanup

- Remove `PrefabRegistry.hasGizmos()` and `getGizmos()`.
- Remove all `.gizmos` handling from `loadPrefabEntity()`,
  `loadComponentEntity()`, and `createChildEntity()`.
- Remove `.gizmos` blocks from all prefab and scene `.zon` files in example
  projects.

## Engine Files to Modify

| File | Change |
|------|--------|
| `scene/src/loader.zig` | Add `GizmoReg` param to `SceneLoader`, update `loadPrefabEntity`, `loadComponentEntity`, `instantiatePrefab` |
| `scene/src/loader/entity_components.zig` | Update `createChildEntity` to accept gizmo data from registry |
| `scene/src/prefab.zig` | Deprecate `hasGizmos()` / `getGizmos()` |
| `scene/src/gizmo_registry.zig` | **New** — `GizmoRegistry` type |
| `scene/src/root.zig` | Export `GizmoRegistry` |
| `tools/generator.zig` | Add `gizmos` scan |
| `tools/generator/scanner.zig` | No changes needed (reuses `scanZonFolder`) |
| `tools/generator/targets/raylib_desktop.zig` | Generate `GizmoRegistry` and pass to `SceneLoader` |
| `tools/generator/targets/*.zig` | Same for all other targets |
| `tools/templates/main_raylib.txt` | Add gizmo template tags |

## Verification

1. **Unit tests**: Add GizmoRegistry tests (has/get/getEntityGizmos/getChildrenGizmos)
2. **Backwards compat**: Existing example projects (no gizmos/ dir) continue building
3. **Forward path**: bakery-game migrates to gizmos/ dir:
   - Create `gizmos/*.zon` files
   - Remove `.gizmos` from `prefabs/*.zon`
   - Regenerate with `zig build generate`
   - Production system calls `Loader.createGizmosForEntity()` for dynamic items
   - Verify gizmos appear on runtime-created items
   - Verify gizmos survive save/load cycle

## Alternatives Considered

### Engine-level `recreateAllGizmos()` API

Walk all entities, match to prefabs, rebuild gizmo entities. Solves save/load
but doesn't address the separation of concerns problem or help with non-prefab
entities.

### Inline gizmo data on parent entity (no separate gizmo entities)

Store gizmo config as a component on the parent entity instead of creating
separate entities. Simpler model but requires significant render pipeline changes
and loses the current `Gizmo.parent_entity` + offset architecture.

### Single `gizmos.zon` file instead of per-prefab files

All gizmo configs in one file. Works for small projects but doesn't scale.
Per-prefab files mirror the existing `prefabs/` directory convention.

### Runtime JSON gizmo config

Load gizmos from a JSON file at runtime instead of comptime .zon. Enables hot
reload but breaks the engine's comptime philosophy and adds runtime parsing cost.
