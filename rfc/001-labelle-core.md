# RFC 001: Extract `labelle-core` — Plugin Development Kit

**Status**: Validated (POC)
**Issue**: [#289](https://github.com/labelle-toolkit/labelle-engine/issues/289)
**Date**: 2026-02-16
**POC**: `rfc/poc/` — micro_core, micro_engine, micro_plugin

## Problem

Building a plugin for the labelle engine requires understanding implicit
contracts scattered across labelle-engine: hook types, dispatcher patterns,
component callback signatures, entity conversions, ECS bridge vtables. A new
plugin author has to study engine internals and reinvent patterns that
labelle-tasks already solved.

Specific issues:

1. **Plugins must depend on the full engine** just to access hook definitions and
   component callback signatures, even when they don't need ECS, rendering, or
   physics.
2. **The engine cannot be tested with plugins** without creating a reverse
   dependency (engine -> plugin), violating the Open-Closed Principle (PR #288).
3. **Plugin patterns are not reusable** — labelle-tasks invented the EcsInterface
   vtable, the EngineTypes bundle, the two-way hook binding. The next plugin
   would reinvent all of it.

## Goal

**Make plugin creation as fast as possible.** A new plugin should import
labelle-core and have everything it needs to integrate with the engine: hook
system, component callbacks, ECS bridge, test harness — all fully generic via
comptime.

## Current Architecture

```
labelle-tasks ──uses EngineTypes param──> labelle-engine
                                           (hook types, dispatcher,
                                            component payloads, entity types)
```

labelle-tasks avoids a direct module dependency on labelle-engine (WASM module
collision — labelle-tasks#38) by receiving engine types via a comptime
`EngineTypes` parameter. But the pattern itself is ad-hoc and undocumented.

## Proposed Architecture

```
labelle-engine ───> labelle-core
labelle-tasks  ───> labelle-core
any-plugin     ───> labelle-core  (only core needed to build a plugin)
any-plugin     ───> labelle-engine (optional, for ECS/rendering features)
```

## What goes in labelle-core

Everything below is fully generic — no hardcoded types. Entity, Item, payloads
are all comptime parameters. Validated in the POC.

### 1. Hook System (see RFC 002 for full details)

The comptime zero-overhead hook dispatcher. This is the primary integration
mechanism between engine and plugins.

```zig
/// Receiver-based hook dispatcher. PayloadUnion field names = event names.
/// Receiver: struct (or pointer to struct) with handler methods.
/// Options: .exhaustive = true to require handlers for all events.
pub fn HookDispatcher(
    comptime PayloadUnion: type,
    comptime Receiver: type,
    comptime options: struct { exhaustive: bool = false },
) type { ... }

/// Compose multiple receiver structs into one merged dispatch.
/// Handlers fire in tuple order — first receiver listed, first called.
pub fn MergeHooks(
    comptime PayloadUnion: type,
    comptime ReceiverTypes: anytype,    // tuple of Receiver types
) type { ... }
```

**Includes:**
- `HookDispatcher` — generic, comptime-validated receiver dispatch
- `MergeHooks` — composes N receivers, calls handlers in tuple order
- `EngineHookPayload(Entity)` — standard lifecycle events as a tagged union
- Standard payload structs (GameInitInfo, FrameInfo, SceneInfo, EntityInfo) —
  parameterized by a comptime `Entity` type

### 2. Component Lifecycle

The callback signatures that ECS-aware components implement. Parameterized by
Entity type — not hardcoded to u64.

```zig
/// Component lifecycle payload — passed to onAdd, onReady, onRemove callbacks.
/// Entity type is comptime so plugins aren't locked to any specific type.
pub fn ComponentPayload(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
        game_ptr: *anyopaque,

        pub fn getGame(self: @This(), comptime GameType: type) *GameType {
            return @ptrCast(@alignCast(self.game_ptr));
        }
    };
}
```

### 3. ECS Trait (comptime interface)

Core defines what an ECS must look like. Plugins work through this trait
generically — they never know which backend (zig-ecs, zflecs, mr_ecs) is
behind it. The engine provides the concrete implementation. Everything resolves
at comptime, zero runtime overhead.

```zig
/// Comptime ECS trait — defines the operations any ECS backend must support.
/// Plugins parameterize on this; engine provides the concrete type.
pub fn Ecs(comptime Backend: type) type {
    comptime {
        if (!@hasDecl(Backend, "Entity"))
            @compileError("ECS backend must define Entity type");
        const required = .{ "createEntity", "destroyEntity", "entityExists" };
        for (required) |name| {
            if (!@hasDecl(Backend, name))
                @compileError("ECS backend must implement " ++ name);
        }
    }

    return struct {
        pub const Entity = Backend.Entity;
        backend: *Backend,

        pub fn createEntity(self: @This()) Entity { ... }
        pub fn destroyEntity(self: @This(), entity: Entity) void { ... }
        pub fn entityExists(self: @This(), entity: Entity) bool { ... }
        pub fn add(self: @This(), entity: Entity, component: anytype) void { ... }
        pub fn get(self: @This(), entity: Entity, comptime T: type) ?*T { ... }
        pub fn has(self: @This(), entity: Entity, comptime T: type) bool { ... }
        pub fn remove(self: @This(), entity: Entity, comptime T: type) void { ... }
    };
}
```

**How it flows:**

```zig
// Engine provides the concrete backend
const MyEcs = core.Ecs(engine.ZigEcsBackend);

// Plugin uses PluginContext for validation, then works through the trait
pub fn TasksPlugin(comptime EcsType: type) type {
    const Ctx = core.PluginContext(.{ .EcsType = EcsType });

    return struct {
        ecs: Ctx.EcsType,

        pub fn addStorage(self: @This(), entity: Ctx.Entity, role: StorageRole) void {
            self.ecs.add(entity, Storage{ .role = role });
        }

        pub fn getStorage(self: @This(), entity: Ctx.Entity) ?*Storage {
            return self.ecs.get(entity, Storage);
        }
    };
}

// Game wires it together
const Tasks = tasks.TasksPlugin(MyEcs);
```

This replaces the ad-hoc `EcsInterface` vtable in labelle-tasks. Plugins use
`ecs.add()`, `ecs.get()`, `ecs.has()`, `ecs.remove()` — standard operations,
fully typed, no vtable overhead.

### 4. Plugin Protocol (PluginContext)

A comptime validator that checks an ECS type satisfies the core trait interface
and bundles convenience type aliases. Replaces ad-hoc comptime parameter
validation in each plugin with a single, reusable check.

```zig
/// Validates that EcsType satisfies the core ECS trait interface.
/// Returns a namespace with derived types for plugin use.
pub fn PluginContext(comptime cfg: struct { EcsType: type }) type {
    comptime {
        if (!@hasDecl(cfg.EcsType, "Entity"))
            @compileError("PluginContext: EcsType must expose Entity type");

        const required_fns = .{
            "createEntity", "destroyEntity", "entityExists",
            "add", "get", "has", "remove",
        };
        for (required_fns) |name| {
            if (!@hasDecl(cfg.EcsType, name))
                @compileError("PluginContext: EcsType must implement '" ++ name ++ "'");
        }
    }

    return struct {
        pub const Entity = cfg.EcsType.Entity;
        pub const EcsType = cfg.EcsType;
        pub const Payload = ComponentPayload(cfg.EcsType.Entity);
    };
}
```

**Usage in a plugin:**

```zig
pub fn InventoryPlugin(comptime EcsType: type, comptime Item: type) type {
    const Ctx = core.PluginContext(.{ .EcsType = EcsType });
    const Entity = Ctx.Entity;

    return struct {
        ecs: EcsType,
        // ... plugin implementation using Entity, EcsType, Ctx.Payload
    };
}
```

If a consumer passes an invalid EcsType (e.g., a bare struct without
`createEntity`), they get a clear compile error from PluginContext instead of
a cryptic error deep in the plugin's internal code.

### 5. Plugin Test Harness

A mock engine context and hook recorder that any plugin can use for testing
without importing the real engine. This is what PR #288 was trying to solve.

**MockEcsBackend** — in-memory ECS backend satisfying the `Ecs` trait:

```zig
/// HashMap-based mock backend. Uses type-erased storage internally,
/// type-safe API externally. Unique typeId per component type via
/// anonymous struct referencing T to prevent compiler deduplication.
pub fn MockEcsBackend(comptime Entity: type) type {
    return struct {
        pub const Entity = Entity;
        pub fn createEntity(self: *@This()) Entity { ... }
        pub fn destroyEntity(self: *@This(), entity: Entity) void { ... }
        pub fn addComponent(self: *@This(), entity: Entity, component: anytype) void { ... }
        pub fn getComponent(self: *@This(), entity: Entity, comptime T: type) ?*T { ... }
        pub fn hasComponent(self: *@This(), entity: Entity, comptime T: type) bool { ... }
        pub fn removeComponent(self: *@This(), entity: Entity, comptime T: type) void { ... }
    };
}
```

**TestContext** — wraps MockEcsBackend with convenience init/deinit:

```zig
/// Replaces 3-line boilerplate with 2 lines.
/// Avoids the self-referencing pointer issue — ecs() creates the wrapper
/// on the fly, pointing to the stable backend field.
pub fn TestContext(comptime Entity: type) type {
    const Backend = MockEcsBackend(Entity);

    return struct {
        pub const EcsType = Ecs(Backend);
        pub const Payload = ComponentPayload(Entity);

        backend: Backend,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .backend = Backend.init(allocator) };
        }

        /// Returns an Ecs wrapper pointing to this context's backend.
        pub fn ecs(self: *@This()) EcsType {
            return .{ .backend = &self.backend };
        }

        pub fn deinit(self: *@This()) void {
            self.backend.deinit();
        }
    };
}
```

**RecordingHooks** — records dispatched event tags for assertion:

```zig
/// Drop-in HookSystem replacement. Pass *RecordingHooks as HookSystem
/// to Game to capture and assert the exact event sequence.
pub fn RecordingHooks(comptime PayloadUnion: type) type {
    const Tag = std.meta.Tag(PayloadUnion);

    return struct {
        tags: std.ArrayListUnmanaged(Tag) = .{},
        allocator: std.mem.Allocator,
        cursor: usize = 0,

        pub fn init(allocator: std.mem.Allocator) @This() { ... }
        pub fn deinit(self: *@This()) void { ... }

        /// Record an event — compatible with HookSystem emit interface.
        pub fn emit(self: *@This(), payload: PayloadUnion) void { ... }

        /// Assert the next recorded event matches the expected tag.
        pub fn expectNext(self: *@This(), expected: Tag) !void { ... }

        /// Assert no more events remain after current cursor.
        pub fn expectEmpty(self: @This()) !void { ... }

        /// Count occurrences of a specific event tag.
        pub fn count(self: @This(), tag: Tag) usize { ... }

        /// Total number of recorded events.
        pub fn len(self: @This()) usize { ... }

        /// Reset all recordings and cursor.
        pub fn reset(self: *@This()) void { ... }
    };
}
```

**A plugin's tests become:**

```zig
const core = @import("labelle-core");
const TC = core.TestContext(u32);

test "my plugin adds a component" {
    var ctx = TC.init(testing.allocator);
    defer ctx.deinit();

    const ecs = ctx.ecs();
    const entity = ecs.createEntity();

    var plugin = MyPlugin(TC.EcsType).init(testing.allocator, ecs);
    plugin.doSomething(entity);

    try testing.expect(ecs.has(entity, MyComponent));
}
```

**RecordingHooks with engine integration:**

```zig
test "game emits correct lifecycle sequence" {
    const Payload = core.EngineHookPayload(u32);
    var recorder = core.RecordingHooks(Payload).init(testing.allocator);
    defer recorder.deinit();

    var game = engine.Game(*core.RecordingHooks(Payload)).init(allocator, &recorder);
    game.fixPointers();
    defer game.deinit();

    game.start();
    game.loadScene("level1");
    _ = game.createEntity();
    game.tick(0.016);

    try recorder.expectNext(.game_init);
    try recorder.expectNext(.scene_load);
    try recorder.expectNext(.entity_created);
    try recorder.expectNext(.frame_start);
    try recorder.expectNext(.frame_end);
    try recorder.expectEmpty();
}
```

### 6. Two-Way Hook Binding Pattern

The pattern where a plugin both *emits* hooks (to notify the game) and
*receives* hooks (from the game). Core provides symmetric dispatching for
both directions, each with its own receiver.

```zig
/// Bidirectional hook binding for a plugin.
pub fn PluginHooks(comptime cfg: struct {
    OutPayload: type,
    InPayload: type,
    GameReceiver: type,
    PluginReceiver: type,
}) type {
    return struct {
        out: HookDispatcher(cfg.OutPayload, cfg.GameReceiver, .{}),
        in_hooks: HookDispatcher(cfg.InPayload, cfg.PluginReceiver, .{}),

        /// Plugin calls this to notify the game
        pub fn emit(self: @This(), payload: cfg.OutPayload) void {
            self.out.emit(payload);
        }

        /// Game calls this to notify the plugin
        pub fn handle(self: @This(), payload: cfg.InPayload) void {
            self.in_hooks.emit(payload);
        }
    };
}
```

Plugins expose a `Hooks(GameReceiver)` type generator so the game only needs
to provide its receiver:

```zig
// Inside the plugin
pub fn Hooks(comptime GameReceiver: type) type {
    return core.PluginHooks(.{
        .OutPayload = OutPayload,
        .InPayload = InPayload,
        .GameReceiver = GameReceiver,
        .PluginReceiver = PluginReceiver,
    });
}

// Game side
const hooks = Inventory.Hooks(*GameRecv){
    .out = .{ .receiver = &game_recv },
    .in_hooks = .{ .receiver = plugin.pluginReceiver() },
};

hooks.handle(.{ .add_item = .{ .entity_id = e, .item = .sword, .quantity = 1 } });
hooks.emit(.{ .item_added = .{ .entity_id = e, .item = .sword, .quantity = 1, .new_total = 1 } });
```

## Module Structure

```
labelle-core/
  root.zig              — Public API re-exports
  dispatcher.zig        — HookDispatcher, MergeHooks, UnwrapReceiver
  ecs.zig               — Ecs(Backend) comptime trait, MockEcsBackend
  component.zig         — ComponentPayload(Entity)
  plugin.zig            — PluginHooks bidirectional binding
  context.zig           — PluginContext, TestContext, RecordingHooks
```

## What stays in labelle-engine

The engine is a full framework, not a thin orchestrator. Internal modules
(physics, audio, GUI) have direct access to engine internals and are NOT
plugins — they ship as part of the engine.

- ECS backends (zig-ecs, zflecs, mr_ecs) — implement core's `Ecs` trait
- Game loop, window, frame management
- Scene system, loader, prefabs
- Rendering pipeline, input
- **Physics** (Box2D integration — engine-internal, not a plugin)
- **Audio** (zaudio — engine-internal, not a plugin)
- **GUI** (nuklear/imgui/clay — engine-internal, not a plugin)
- The concrete backend types that satisfy core's `Ecs` trait and `PluginContext`
- Code generators (project.labelle -> build files)

Core is for **external plugins** (like labelle-tasks) that extend the engine
without being part of it. Engine-internal modules use engine types directly.

## What stays in labelle-tasks

- All domain types (WorkerState, WorkstationStatus, StorageRole, Priority, etc.)
- Task-specific hooks (TaskHookPayload, GameHookPayload) — built on core's
  PluginHooks scaffolding
- Task engine logic (assignment, evaluation, dangling items)
- ECS components (Storage, Worker, Workstation) — using core's ComponentPayload
- Uses core's `Ecs` trait for entity/component operations (replaces the ad-hoc
  `EcsInterface` vtable)

## Migration Plan

### Phase 1: Create labelle-core, extract hook system

1. Create `labelle-core` repo
2. Move `HookDispatcher`, `MergeHooks` from engine to core
3. Move `EngineHookPayload`, payload structs to core (parameterize Entity type)
4. Move `ComponentPayload` to core (parameterize Entity type)
5. Engine depends on core, re-exports for backward compatibility
6. **No breaking changes** — engine re-exports everything

### Phase 2: ECS trait and plugin protocol

1. Define `Ecs(Backend)` comptime trait in core
2. Wrap engine ECS backends (zig-ecs, zflecs, mr_ecs) to satisfy the trait
3. Define `PluginContext` validator
4. Update labelle-tasks to use core's `Ecs` trait (replaces `EcsInterface` vtable)
5. Document the plugin development workflow

### Phase 3: Test harness

1. Build `TestContext` and `RecordingHooks` in core
2. Port labelle-tasks tests to use core's test harness
3. Any new plugin gets testing for free

### Phase 4: Cleanup

1. Remove re-exports from engine
2. Plugins depend only on core (+ engine if they need ECS/rendering)
3. Publish plugin development guide

## Decisions (from open questions discussion)

1. **EngineHook lives in core** — it defines the lifecycle contract that all
   plugins respond to. Plugins define their own domain-specific hooks separately.

2. **Entity type is comptime** — `ComponentPayload(comptime Entity: type)`.
   No hardcoded u64. The engine provides the concrete type; plugins stay generic.

3. **Core owns the ECS trait** — `Ecs(comptime Backend: type)` defines a
   standard interface for entity/component operations. Plugins work through this
   trait generically. Engine backends (zig-ecs, zflecs, mr_ecs) implement it.
   Replaces the ad-hoc `EcsInterface` vtable pattern. Fully comptime, zero
   runtime overhead.

4. **Versioning** — semver on core becomes the plugin API version. Breaking
   changes should be rare since this is the most stable layer.

5. **`labelle-core` is the right granularity** — it's a plugin development kit,
   not just hooks. Room to grow without being over-scoped.

## POC Validation

All 6 core components are validated by the POC (`rfc/poc/`):

| Component | POC Location | Tests |
|---|---|---|
| HookDispatcher | `micro_core/dispatcher.zig` | basic emit, stateless receiver, partial handling |
| MergeHooks | `micro_core/dispatcher.zig` | tuple order, partial receivers |
| ECS Trait | `micro_core/ecs.zig` | CRUD, multi-component, MockEcsBackend |
| ComponentPayload | `micro_core/component.zig` | getGame typed pointer |
| PluginContext | `micro_core/context.zig` | type validation, works with TestContext |
| TestContext | `micro_core/context.zig` | ECS without boilerplate, plugin integration |
| RecordingHooks | `micro_core/context.zig` | event sequence, reset, engine integration |
| PluginHooks | `micro_core/plugin.zig` | bidirectional emit/handle |
| Full plugin pattern | `micro_plugin/root.zig` | inventory: add/remove/clear/stack/lifecycle/hooks |

22 tests total, all passing.

## Alternatives Considered

### Keep everything in labelle-engine, use lazy dependencies

Rejected: `.lazy = true` doesn't work with `.path` dependencies in Zig 0.15,
and conceptually the plugin contract shouldn't live inside the engine.

### Dedicated integration test repo

Solves testing but doesn't address the architectural coupling or reusability.

### Plugin defines all its own types (status quo)

labelle-tasks already does this via `EngineTypes`. But every new plugin would
reinvent the vtable, the hook binding, the test harness. Core eliminates that
duplication.

### `labelle-hooks` (smaller scope)

Too narrow — the hook system alone isn't enough to build a plugin quickly. The
ECS bridge, component callbacks, test harness, and plugin protocol are equally
important for plugin development speed.
