# RFC 0001: Task Plugin Hook Detection

- **Status**: Implemented
- **Issue**: [#80](https://github.com/labelle-toolkit/labelle-engine/issues/80)
- **Related**: labelle-tasks#21

## Summary

Auto-detect task hook functions in the `hooks/` folder and generate a `TaskEngine` type with hooks automatically wired up, similar to how engine hooks (`game_init`, `scene_load`) are already detected.

## Motivation

Currently, integrating `labelle-tasks` with `labelle-engine` requires manual boilerplate:

```zig
// Manual hook setup (before this RFC)
const MyTaskHooks = struct {
    pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void { ... }
};
const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyTaskHooks);
var engine = tasks.EngineWithHooks(u32, Item, Dispatcher).init(allocator);
```

This RFC enables automatic detection and wiring:

```zig
// hooks/task_hooks.zig - just define the handlers
pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
    // Game responds to pickup starting
}
```

The generator handles all the wiring automatically.

## Design

### Plugin Configuration

The `Plugin` struct in `project_config.zig` gains two new optional fields:

```zig
pub const Plugin = struct {
    // ... existing fields ...

    /// Entity ID type for task engine (e.g., "u32", "u64")
    id_type: ?[]const u8 = null,

    /// Item type for task engine (e.g., "components.items.ItemType")
    item_type: ?[]const u8 = null,
};
```

Example `project.labelle`:

```zig
.plugins = .{
    .{
        .name = "labelle-tasks",
        .version = "0.6.0",
        .id_type = "u32",
        .item_type = "main_module.ItemType",
    },
},
```

### Task Hook Detection

The generator scans hook files for these known task hook function signatures:

| Hook Name | Trigger |
|-----------|---------|
| `pickup_started` | Worker starts moving to EIS |
| `process_started` | Worker begins processing at workstation |
| `store_started` | Worker starts moving to EOS |
| `worker_released` | Worker released from workstation |

Detection uses simple pattern matching: `pub fn <hook_name>(`.

### Generated Code

When task hooks are detected and `labelle-tasks` plugin is configured, the generator produces:

```zig
// Auto-generated in main.zig
const TaskDispatcher = labelle_tasks.hooks.HookDispatcher(u32, ItemType, task_hooks);
pub const TaskEngine = labelle_tasks.EngineWithHooks(u32, ItemType, TaskDispatcher);
```

For multiple hook files with task hooks:

```zig
const TaskHooks = labelle_tasks.hooks.MergeTasksHooks(u32, ItemType, .{
    game_hooks,
    analytics_hooks,
});
const TaskDispatcher = labelle_tasks.hooks.HookDispatcher(u32, ItemType, TaskHooks);
pub const TaskEngine = labelle_tasks.EngineWithHooks(u32, ItemType, TaskDispatcher);
```

### User Code

Users define handlers in `hooks/*.zig`:

```zig
// hooks/task_hooks.zig
const std = @import("std");
const tasks = @import("labelle_tasks");
const items = @import("../components/items.zig");

const HookPayload = tasks.hooks.HookPayload(u32, items.ItemType);

pub fn pickup_started(payload: HookPayload) void {
    const info = payload.pickup_started;
    // Start worker movement animation toward EIS
    std.log.info("Worker {d} picking up from {d}", .{info.worker_id, info.eis_id});
}

pub fn store_started(payload: HookPayload) void {
    const info = payload.store_started;
    // Start worker movement animation toward EOS
}
```

## Implementation

### Files Modified

1. **`src/project_config.zig`**
   - Added `id_type` and `item_type` fields to `Plugin` struct

2. **`src/generator.zig`**
   - Added `task_hook_names` constant with known hook names
   - Added `TaskHookScanResult` struct
   - Added `scanForTaskHooks()` function
   - Added `fileContainsTaskHooks()` helper
   - Updated `generateMainZigRaylib()` to accept task hooks
   - Updated `generateMainZig()` signature
   - Updated `generateProject()` and `generateMainOnly()` to scan for task hooks

3. **`src/templates/main_raylib.txt`**
   - Added `.task_engine_empty` section
   - Added `.task_engine_start` section
   - Added `.task_engine_hook_item` section
   - Added `.task_engine_end` section

### Template Sections

```
.task_engine_empty

.task_engine_start
// Task engine with auto-wired hooks
const TaskHooks = {s}.hooks.MergeTasksHooks({s}, {s}, .{
.task_engine_hook_item
    {s}_hooks,
.task_engine_end
});
const TaskDispatcher = {s}.hooks.HookDispatcher({s}, {s}, TaskHooks);
pub const TaskEngine = {s}.EngineWithHooks({s}, {s}, TaskDispatcher);
```

## Usage Example

See `usage/example_tasks_plugin/` for a complete working example:

```
usage/example_tasks_plugin/
├── project.labelle           # Plugin config with id_type/item_type
├── hooks/task_hooks.zig      # Task hook handlers
├── components/items.zig      # ItemType enum
├── main.zig                  # Shows generated pattern
└── scenes/main.zon
```

## Alternatives Considered

### 1. Explicit Hook Registration

Require users to explicitly list which hooks they want:

```zig
.plugins = .{
    .{ .name = "labelle-tasks", .hooks = .{ "pickup_started", "store_started" } },
},
```

**Rejected**: Adds configuration burden. Auto-detection is simpler and follows the existing pattern for engine hooks.

### 2. Runtime Hook Registration

Use runtime function pointers instead of comptime dispatch:

```zig
task_engine.on_pickup_started = myHandler;
```

**Rejected**: Already supported by base `Engine` class. This RFC focuses on the comptime hook system which provides zero-overhead dispatch and better type safety.

### 3. Separate Task Hooks Folder

Use `task_hooks/` instead of detecting task hooks in `hooks/`:

```
hooks/           # Engine hooks only
task_hooks/      # Task hooks only
```

**Rejected**: Adds complexity. A single `hooks/` folder with auto-detection is simpler and allows mixed hook files (engine + task hooks in same file).

## Future Work

1. **SceneContext Integration**: Add `getTaskEngine()` method to `SceneContext` for easy access in scripts
2. **Additional Hook Types**: Detect more task hooks (`transport_started`, `cycle_completed`, etc.)
3. **Plugin-Agnostic Pattern**: Generalize this pattern for other plugins that define hook systems

## References

- [labelle-tasks Hook System](https://github.com/labelle-toolkit/labelle-tasks/blob/main/src/hooks.zig)
- [labelle-engine Hook System](https://github.com/labelle-toolkit/labelle-engine/blob/main/src/hooks/)
- [Issue #80](https://github.com/labelle-toolkit/labelle-engine/issues/80)
