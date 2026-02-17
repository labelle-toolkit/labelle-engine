# RFC 002: Core Hook System — Unified Bidirectional Dispatching

**Status**: Validated (POC)
**Issue**: [#289](https://github.com/labelle-toolkit/labelle-engine/issues/289)
**Date**: 2026-02-16
**Parent**: [RFC 001 — labelle-core](001-labelle-core.md)
**POC**: `rfc/poc/micro_core/dispatcher.zig`, `rfc/poc/micro_core/plugin.zig`

## Problem

The hook system is the primary integration mechanism between engine and plugins.
Today there are two separate implementations:

1. **Engine hooks** — `HookDispatcher` in `engine/hooks/dispatcher.zig`. Handles
   lifecycle events (game_init, frame_start, scene_load, etc.). Dispatches from
   engine to game/plugin code.

2. **Plugin hooks** — labelle-tasks defines its own dispatching in
   `tasks/src/hooks.zig`. Two separate flows: out events (plugin -> game) via a
   custom dispatcher, in events (game -> plugin) via a manual `handle()` switch.

These are the same pattern implemented twice, with different ergonomics. The
engine dispatcher has comptime validation; the plugin's manual switch does not.

## Current Implementation

### Engine HookDispatcher

```zig
// engine/hooks/dispatcher.zig
pub fn HookDispatcher(
    comptime HookEnum: type,
    comptime PayloadUnion: type,
    comptime HookMap: type,
) type {
    return struct {
        pub fn emit(payload: PayloadUnion) void {
            // inline switch — resolves handler at comptime, zero overhead
            inline for (std.meta.fields(PayloadUnion)) |field| {
                if (HookMap has field.name) {
                    call HookMap.field_name(payload.field_name);
                }
            }
        }
        pub fn hasHandler(comptime hook: HookEnum) bool { ... }
        pub fn handlerCount() comptime_int { ... }
    };
}
```

**Strengths:**
- Generic — works with any enum + payload union
- Zero runtime overhead (inline switch resolves at comptime)
- `MergeHooks` composes N handler structs into one

**Weaknesses:**
- No validation that handler names match valid hooks (typos are silent)
- Only handles one direction (emitter -> handler)

### Plugin Two-Way Hooks (labelle-tasks)

**Out direction** (plugin -> game): Uses its own dispatcher, similar to engine's.

**In direction** (game -> plugin): Manual switch in `Engine.handle()`:

```zig
pub fn handle(self: *Self, payload: GameHookPayload) bool {
    switch (payload) {
        .item_added => |p| { self.onItemAdded(p.storage_id, p.item); return true; },
        .worker_available => |p| { self.onWorkerAvailable(p.worker_id); return true; },
        .pickup_completed => |p| { self.onPickupCompleted(p.worker_id); return true; },
        .worker_unavailable => |p| { self.onWorkerUnavailable(p.worker_id); return true; },
        .worker_removed => |p| { self.onWorkerRemoved(p.worker_id); return true; },
        .workstation_enabled => |p| { self.onWorkstationEnabled(p.workstation_id); return true; },
        .workstation_disabled => |p| { self.onWorkstationDisabled(p.workstation_id); return true; },
        .workstation_removed => |p| { self.onWorkstationRemoved(p.workstation_id); return true; },
        .storage_cleared => |p| { self.onStorageCleared(p.storage_id); return true; },
        .item_removed => |p| { self.onItemRemoved(p.storage_id); return true; },
        .work_completed => |p| { self.onWorkCompleted(p.workstation_id); return true; },
        .store_completed => |p| { self.onStoreCompleted(p.worker_id); return true; },
    }
}
```

**Weaknesses:**
- Manual switch — no comptime validation, easy to miss a case or typo a method
- Asymmetric with the out direction (out uses dispatcher, in uses manual switch)
- Every plugin reinvents this pattern

## Proposal: Symmetric Bidirectional Dispatching

Core provides a single `HookDispatcher` that handles both directions. Plugins
define handler structs for both in and out events. Core validates everything at
comptime.

### The Dispatcher

Every handler is a method on a receiver. The dispatcher holds a receiver
instance and calls `receiver.method(payload)`. Receiver can be a value type or
a pointer — `UnwrapReceiver` strips pointer types for comptime inspection.

```zig
/// Core's hook dispatcher — used for both directions.
/// PayloadUnion: tagged union of event payloads (field names = event names)
/// Receiver: struct (or *struct) with handler methods matching union field names
/// Options: .exhaustive = true to require handlers for all events
pub fn HookDispatcher(
    comptime PayloadUnion: type,
    comptime Receiver: type,
    comptime options: struct { exhaustive: bool = false },
) type {
    const Base = UnwrapReceiver(Receiver);

    // Comptime validation — catch typos.
    // Only checks functions with exactly 2 params (self + payload) to skip
    // infrastructure methods like emit() that aren't event handlers.
    comptime {
        for (std.meta.declarations(Base)) |decl| {
            if (fieldIndex(PayloadUnion, decl.name) == null) {
                if (@hasDecl(Base, decl.name)) {
                    const DeclType = @TypeOf(@field(Base, decl.name));
                    const info = @typeInfo(DeclType);
                    if (info == .@"fn" and info.@"fn".params.len == 2) {
                        @compileError(
                            "Handler '" ++ decl.name ++ "' in " ++ @typeName(Base) ++
                            " doesn't match any event in " ++ @typeName(PayloadUnion),
                        );
                    }
                }
            }
        }

        // Exhaustive mode: every event must have a handler
        if (options.exhaustive) {
            for (std.meta.fields(PayloadUnion)) |field| {
                if (!@hasDecl(Base, field.name))
                    @compileError("Exhaustive: '" ++ field.name ++ "' has no handler");
            }
        }
    }

    return struct {
        receiver: Receiver,

        pub fn emit(self: @This(), payload: PayloadUnion) void {
            switch (payload) {
                inline else => |data, tag| {
                    const name = @tagName(tag);
                    if (@hasDecl(Base, name)) {
                        @field(Base, name)(self.receiver, data);
                    }
                },
            }
        }

        pub fn hasHandler(comptime event_name: []const u8) bool {
            return @hasDecl(Base, event_name);
        }
    };
}
```

Key changes from the old engine dispatcher:
- **`HookEnum` is gone** — derived from `PayloadUnion` field names. One less
  thing to keep in sync.
- **Receiver-based** — every handler is a method on a receiver. Stateless
  handlers use an empty struct and ignore `self`.
- **2-param rule** — only functions with exactly 2 parameters (self + payload)
  are validated as handlers. This lets receivers have infrastructure methods
  like `emit()` without false positives.
- **`UnwrapReceiver`** — strips pointer types (`*T` → `T`, `**T` → `T`) so
  comptime inspection works on both value and pointer receivers.
- **`switch` with `inline else`** — replaces `inline for` over fields. Cleaner
  and avoids issues with redundant `inline` in comptime scope.

### MergeHooks

Composes N receiver types into one. Each receiver keeps its own state.
Handlers are called in tuple order.

```zig
/// Compose N receiver types into one merged receiver.
/// For each event, calls all receivers that have a matching handler.
/// Order follows tuple order — first listed, first called.
pub fn MergeHooks(
    comptime PayloadUnion: type,
    comptime ReceiverTypes: anytype,    // tuple of Receiver types
) type {
    // Validate all receivers — same 2-param rule as HookDispatcher
    comptime { /* ... validate each receiver type ... */ }

    return struct {
        receivers: ReceiverInstances(ReceiverTypes),

        pub fn emit(self: @This(), payload: PayloadUnion) void {
            switch (payload) {
                inline else => |data, tag| {
                    const name = @tagName(tag);
                    inline for (0..ReceiverTypes.len) |i| {
                        const Base = UnwrapReceiver(ReceiverTypes[i]);
                        if (@hasDecl(Base, name)) {
                            @field(Base, name)(self.receivers[i], data);
                        }
                    }
                },
            }
        }
    };
}
```

Each receiver is independent — it has its own state, handles its own subset of
events. MergeHooks just iterates and calls them in order.

`ReceiverInstances` generates a tuple type via `@Type(.{ .@"struct" = ... })`
with `is_tuple = true`, holding one instance of each receiver.

### PluginHooks — Bidirectional Binding

A plugin declares its in/out events. Core provides symmetric dispatching for
both directions, each with its own receiver.

```zig
/// Bidirectional hook binding for a plugin.
///
/// OutPayload: events the plugin emits (plugin -> game)
/// InPayload: events the plugin receives (game -> plugin)
/// GameReceiver: game-side struct handling out events
/// PluginReceiver: plugin-side struct handling in events
pub fn PluginHooks(comptime cfg: struct {
    OutPayload: type,
    InPayload: type,
    GameReceiver: type,
    PluginReceiver: type,
}) type {
    return struct {
        // Out: plugin emits, game receiver handles
        out: HookDispatcher(cfg.OutPayload, cfg.GameReceiver, .{}),

        // In: game emits, plugin receiver handles
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

Note: the in-direction field is named `in_hooks` (not `in`) because `in` is a
reserved keyword in Zig.

Plugins expose a `Hooks(GameReceiver)` type generator so the game only provides
its own receiver — the plugin receiver is fixed:

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
```

### What labelle-tasks would look like with this

**Before** (manual switch, asymmetric):

```zig
// labelle-tasks/src/root.zig — manual switch for in direction
pub fn handle(self: *Self, payload: GameHookPayload) bool {
    switch (payload) {
        .item_added => |p| { self.onItemAdded(p.storage_id, p.item); return true; },
        .worker_available => |p| { self.onWorkerAvailable(p.worker_id); return true; },
        // ... 10 more manual cases
    }
}
```

**After** (core's PluginHooks, symmetric):

```zig
const core = @import("labelle-core");

// Plugin receiver for in events — a struct with state + handler methods
fn TaskReceiver(comptime Self: type) type {
    return struct {
        engine: *Self,

        pub fn item_added(self: @This(), p: anytype) void {
            self.engine.onItemAdded(p.storage_id, p.item);
        }
        pub fn worker_available(self: @This(), p: anytype) void {
            self.engine.onWorkerAvailable(p.worker_id);
        }
        pub fn pickup_completed(self: @This(), p: anytype) void {
            self.engine.onPickupCompleted(p.worker_id);
        }
        // Each handler is a method — comptime validates names match
    };
}

// Game receiver for out events — game decides what to do with plugin events
const MyGameReceiver = struct {
    scene: *Scene,

    pub fn worker_assigned(self: @This(), p: anytype) void {
        // animate worker walking to workstation
        self.scene.playAnimation(p.worker_id, "walk");
    }
    pub fn cycle_completed(self: @This(), p: anytype) void {
        // spawn output item visual
        self.scene.spawnEffect(p.workstation_id, "complete");
    }
    // Only handle events you care about — rest are no-ops
};

// Wire it up
const Hooks = core.PluginHooks(.{
    .OutPayload = TaskHookPayload(GameId, Item),
    .InPayload = GameHookPayload(GameId, Item),
    .GameReceiver = MyGameReceiver,
    .PluginReceiver = TaskReceiver(Self),
});

var hooks = Hooks{
    .out = .{ .receiver = MyGameReceiver{ .scene = &scene } },
    .in_hooks = .{ .receiver = TaskReceiver(Self){ .engine = &engine } },
};

// Game -> plugin
hooks.handle(.{ .item_added = .{ .storage_id = 1, .item = .flour } });

// Plugin -> game
hooks.emit(.{ .worker_assigned = .{ .worker_id = 5, .workstation_id = 2 } });
```

**Benefits:**
- No manual switch — handlers are methods on a receiver
- Comptime validates both directions (typos caught at compile time)
- Symmetric — in and out use the exact same dispatcher
- Receivers carry their own state — no global/static workarounds
- Every plugin gets this for free from core

## Engine Lifecycle Hooks

Same dispatcher, same receiver pattern. Engine hooks are typically stateless
(the payload carries everything), so the receiver is an empty struct:

```zig
// Core defines the lifecycle events — parameterized by Entity type
pub fn EngineHookPayload(comptime Entity: type) type {
    return union(enum) {
        game_init: GameInitInfo,
        game_deinit: void,
        frame_start: FrameInfo,
        frame_end: FrameInfo,
        scene_load: SceneInfo,
        scene_unload: SceneInfo,
        entity_created: EntityInfo(Entity),
        entity_destroyed: EntityInfo(Entity),
    };
}

// Game handles lifecycle hooks — stateless receiver
const MyEngineHooks = struct {
    pub fn game_init(_: @This(), info: GameInitInfo) void {
        // init subsystems using info.allocator
    }
    pub fn scene_load(_: @This(), info: SceneInfo) void {
        // scene loaded
    }
    // Only handle what you care about — rest are no-ops
};

// Dispatcher uses the same pattern as plugin hooks
const Dispatcher = core.HookDispatcher(EngineHookPayload(u32), MyEngineHooks, .{});
const dispatcher = Dispatcher{ .receiver = MyEngineHooks{} };
dispatcher.emit(.{ .game_init = .{ .allocator = alloc } });
```

If a plugin needs to respond to engine lifecycle events WITH state (e.g.,
labelle-tasks needs to re-evaluate workstations on scene_load), the receiver
carries the state:

```zig
const TaskLifecycleReceiver = struct {
    engine: *TaskEngine,

    pub fn game_init(self: @This(), info: GameInitInfo) void {
        self.engine.init(info.allocator);
    }
    pub fn scene_load(self: @This(), _: SceneInfo) void {
        self.engine.reevaluateAll();
    }
    pub fn game_deinit(self: @This(), _: void) void {
        self.engine.deinit();
    }
};
```

This replaces the current `createEngineHooks` function in labelle-tasks that
uses a comptime-static variable as a workaround for not having instance state.

Multiple receivers are composed with MergeHooks:

```zig
const Merged = core.MergeHooks(EngineHookPayload(u32), .{
    TaskLifecycleReceiver,   // called first
    MyGameHooks,             // called second
});

const merged = Merged{
    .receivers = .{
        TaskLifecycleReceiver{ .engine = &task_engine },
        MyGameHooks{},
    },
};

// scene_load fires → Task first, then Game
merged.emit(.{ .scene_load = .{ .name = "level1" } });
```

The engine's `Game` type accepts any type with an `emit()` method — duck-typed.
This means `HookDispatcher`, `MergeHooks`, and `*RecordingHooks` all work as
HookSystem without a shared interface:

```zig
pub fn Game(comptime HookSystem: type) type {
    return struct {
        hooks: HookSystem,
        // ... game just calls self.hooks.emit(payload)
    };
}
```

## Decisions

1. **Handler state**: Every handler is a method on a receiver struct. The
   dispatcher always calls `receiver.method(payload)`. Stateless handlers use an
   empty struct and ignore `self`. Stateful handlers put whatever they need in
   the struct (e.g., a pointer to the plugin instance). One pattern, no special
   cases.

   ```zig
   // Stateless — empty receiver, ignore self
   const MyEngineHooks = struct {
       pub fn game_init(_: @This(), info: GameInitInfo) void { ... }
   };

   // Stateful — receiver carries plugin state
   const TaskInHandlers = struct {
       engine: *TaskEngine,

       pub fn item_added(self: @This(), p: anytype) void {
           self.engine.onItemAdded(p.storage_id, p.item);
       }
   };
   ```

2. **`handle()` returns void**: The dispatcher's job is routing, not reporting.
   With comptime dispatch, all events in the payload union are valid — there's
   no "unrecognized event" case. If a plugin needs to track whether it acted on
   an event, it can do so in its receiver state.

3. **Partial handling by default**: A receiver doesn't need to handle every
   event. Unhandled events are silent no-ops. The comptime validation rules are:

   - Handler name (2-param function) doesn't match any event → **compile error**
     (catches typos)
   - Event has no handler → **silent no-op** (you don't care about it)
   - Non-handler declarations (different param count) → **ignored** (infrastructure
     methods like `emit()` are not validated)

   ```zig
   const MyReceiver = struct {
       // Only handles 2 of 15 possible events — the rest are no-ops
       pub fn worker_assigned(self: @This(), p: anytype) void { ... }
       pub fn cycle_completed(self: @This(), p: anytype) void { ... }

       // This would be a compile error — typo:
       // pub fn worke_assigned(self: @This(), p: anytype) void { ... }
   };
   ```

   For plugins that want to guarantee they handle everything (defensive
   programming), core offers an opt-in exhaustive mode:

   ```zig
   const Dispatcher = core.HookDispatcher(PayloadUnion, MyReceiver, .{
       .exhaustive = true,  // compile error if any event has no handler
   });
   ```

4. **MergeHooks: tuple order, guaranteed**: When multiple receivers handle the
   same event, they are called in the order they appear in the tuple. This is
   predictable, simple, and matches user expectation.

   ```zig
   const Merged = core.MergeHooks(EngineHookPayload(Entity), .{
       TaskLifecycleReceiver,   // called first
       AudioLifecycleReceiver,  // called second
       MyGameHooks,             // called third
   });

   var merged = Merged{
       .receivers = .{
           TaskLifecycleReceiver{ .engine = &task_engine },
           AudioLifecycleReceiver{ .mixer = &mixer },
           MyGameHooks{},
       },
   };

   // scene_load fires → Task, then Audio, then Game
   merged.emit(.{ .scene_load = .{ .name = "level1" } });
   ```

   No priority system, no dependency resolution. If order matters, arrange the
   tuple accordingly.

## POC Validation

All hook system decisions are validated by the POC (`rfc/poc/tests.zig`):

| Decision | Test |
|---|---|
| Receiver-based dispatch (stateful) | `dispatcher: basic emit calls receiver method` |
| Receiver-based dispatch (stateless) | `dispatcher: stateless receiver (empty struct)` |
| Partial handling (no-ops) | `dispatcher: partial handling compiles (no exhaustive)` |
| Typo = compile error | commented-out test (can't test compile errors at runtime) |
| Exhaustive opt-in | commented-out test (can't test compile errors at runtime) |
| MergeHooks tuple order | `MergeHooks: calls receivers in tuple order` |
| PluginHooks bidirectional | `PluginHooks: bidirectional emit and handle` |
| Stateful plugin receiver | inventory plugin: `PluginReceiver` carries `*InventoryPlugin` |
| Engine lifecycle via MergeHooks | `RecordingHooks: integration with micro engine` |
| Duck-typed HookSystem | Game works with MergeHooks, *RecordingHooks, HookDispatcher |
