# RFC #275: Split engine/game.zig into focused modules

## Problem

`engine/game.zig` is 1,978 lines and growing. It contains ~80 public methods across 9 unrelated responsibilities in a single comptime-generic struct (`GameWith(Hooks)`). This makes the file hard to navigate, review, and maintain.

## Current Structure

```
engine/game.zig  (1978 lines — one file, one struct)
├── Types & re-exports            lines 1-96      (~96 lines)
├── Init / deinit / fixPointers   lines 97-334     (~237 lines)
├── Entity management             lines 336-381    (~45 lines)
├── Position (local + world)      lines 382-557    (~175 lines)
├── Visual components (CRUD)      lines 558-636    (~78 lines)
├── Entity hierarchy              lines 638-881    (~243 lines)
├── Asset loading                 lines 883-893    (~10 lines)
├── Scene management              lines 895-988    (~93 lines)
├── Game loop                     lines 990-1059   (~69 lines)
├── Camera                        lines 1061-1111  (~50 lines)
├── Accessors                     lines 1113-1133  (~20 lines)
├── Input / touch / gestures      lines 1135-1241  (~106 lines)
├── Misc (fullscreen, screen)     lines 1242-1285  (~43 lines)
├── Gizmos (entity + standalone)  lines 1287-1472  (~185 lines)
├── Visual bounds                 lines 1474-1541  (~67 lines)
├── GUI rendering                 lines 1543-1944  (~401 lines)
└── Screenshot                    lines 1946-1978  (~32 lines)
```

### Key Constraint

`GameWith(Hooks)` is a **comptime-generic function** that returns a struct. All methods live inside this returned struct. Any split strategy must account for this.

### Hook Dependency Analysis

Only **7 of ~80 methods** call `emitHook`:
- `init`, `deinit` (game lifecycle)
- `createEntity`, `destroyEntity`, `destroyEntityOnly` (entity lifecycle)
- `unloadCurrentScene`, `setScene` (scene transitions)
- `runWithCallback` (frame start/end)

All other methods (hierarchy, gizmos, GUI, camera, input, positions, etc.) are **hook-free** and don't depend on the `Hooks` type parameter.

## Proposed Approaches

### Approach A: Zero-bit Field Mixins (`@fieldParentPtr`)

Each sub-module exports a comptime-generic mixin type. The parent struct declares zero-bit fields of each mixin type. Methods on the mixin use `@fieldParentPtr` to access the parent `Game` struct. This is the [Zig-endorsed replacement for `usingnamespace` mixins](https://github.com/ziglang/zig/issues/20663).

```zig
// engine/game_hierarchy.zig
pub fn HierarchyMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        pub fn setParent(self: *Self, child: Entity, parent: Entity) HierarchyError!void {
            const game: *GameType = @alignCast(@fieldParentPtr("hierarchy", self));
            // full implementation using game.registry, game.pipeline, game.allocator
        }
        pub fn removeParent(self: *Self, child: Entity) void {
            const game: *GameType = @alignCast(@fieldParentPtr("hierarchy", self));
            // ...
        }
        pub fn getParent(self: *Self, entity: Entity) ?Entity {
            const game: *GameType = @alignCast(@fieldParentPtr("hierarchy", self));
            // ...
        }
        // ... ~15 methods
    };
}

// engine/game.zig (inside GameWith return struct)
const Self = @This();

// Zero-bit mixin fields (no runtime cost)
hierarchy: @import("game_hierarchy.zig").HierarchyMixin(Self) = .{},
gizmos: @import("game_gizmos.zig").GizmosMixin(Self) = .{},
gui: @import("game_gui.zig").GuiMixin(Self) = .{},
input: @import("game_input.zig").InputMixin(Self) = .{},
pos: @import("game_position.zig").PositionMixin(Self) = .{},

// Usage changes from:
//   game.setParent(child, parent)
// To:
//   game.hierarchy.setParent(child, parent)
```

**Modules to extract:**

| Module | Mixin field | Methods | Lines saved |
|--------|-------------|---------|-------------|
| `game_hierarchy.zig` | `.hierarchy` | setParent, removeParent, getParent, getChildren, etc. | ~243 |
| `game_gui.zig` | `.gui` | renderGui, renderSceneGui, renderGuiElementWithState, etc. | ~401 |
| `game_gizmos.zig` | `.gizmos` | drawGizmo, drawArrow, drawLine, selectEntity, etc. | ~185 |
| `game_position.zig` | `.pos` | getWorldTransform, setWorldPosition, local position API | ~175 |
| `game_input.zig` | `.input` | getMousePosition, getTouch, gesture methods | ~106 |

**Remaining in game.zig: ~868 lines** (types, init/deinit, entity CRUD, scene management, game loop, camera, accessors, visual components, screenshot)

**Pros:**
- Zig-endorsed pattern — the official replacement for `usingnamespace` mixins
- Each file is focused and independently navigable
- Sub-modules can access all `Game` fields via `@fieldParentPtr`
- Clean split along responsibility lines
- Zero-bit fields have no runtime cost (`@sizeOf(Mixin) == 0`)
- Clean namespacing — `game.hierarchy.setParent()` makes the domain obvious

**Cons:**
- **Breaking API change** — all call sites must add `.hierarchy.`, `.gizmos.`, etc.
- Every method needs a `@fieldParentPtr` call at the top (boilerplate per method)
- `@fieldParentPtr` requires the field name as a comptime string — renaming the field requires updating the mixin
- Go-to-definition in editors may jump to the mixin file, not game.zig

---

### Approach B: Namespaced Accessor Functions

Similar to Approach A in API, but uses lightweight wrapper structs returned by accessor functions instead of zero-bit fields.

```zig
// engine/game_hierarchy.zig
pub fn HierarchyManager(comptime GameType: type) type {
    return struct {
        game: *GameType,

        pub fn setParent(self: @This(), child: Entity, parent: Entity) !void {
            // accesses self.game.registry, self.game.pipeline, etc.
        }
        pub fn getParent(self: @This(), entity: Entity) ?Entity { ... }
    };
}

// engine/game.zig (inside GameWith return struct)
pub const Hierarchy = @import("game_hierarchy.zig").HierarchyManager(Self);

pub fn hierarchy(self: *Self) Hierarchy {
    return .{ .game = self };
}

// Usage changes from:
//   game.setParent(child, parent)
// To:
//   game.hierarchy().setParent(child, parent)
```

**Pros:**
- Idiomatic Zig (just structs and functions)
- Each sub-module is independently testable
- No `@fieldParentPtr` magic — straightforward pointer access
- Sub-modules have cleaner method bodies (`self.game.registry` vs `@fieldParentPtr`)

**Cons:**
- **Breaking API change** — all call sites must add `.hierarchy()`, `.gizmos()`, etc.
- Slightly more verbose than Approach A: `game.hierarchy().foo()` vs `game.hierarchy.foo()`
- Creates wrapper structs on each call (though zero-cost — just a pointer copy)
- Accessor function must be `pub fn` on `Game`, adding a small amount of code to game.zig

---

### Approach C: Internal Extraction with Thin Delegation

Keep the full public API on `Game`, but move implementations to internal modules. `game.zig` becomes a thin facade.

```zig
// engine/internal/hierarchy.zig
const Entity = @import("ecs").Entity;

pub fn setParent(
    registry: anytype,
    pipeline: anytype,
    allocator: Allocator,
    child: Entity,
    new_parent: Entity,
) HierarchyError!void {
    // full implementation using passed-in dependencies
}

// engine/game.zig (public method, thin wrapper)
pub fn setParent(self: *Self, child: Entity, parent: Entity) HierarchyError!void {
    return internal_hierarchy.setParent(&self.registry, &self.pipeline, self.allocator, child, parent);
}
```

**Pros:**
- Zero API change — `game.setParent(child, parent)` unchanged
- No `@fieldParentPtr` or wrapper objects
- Implementation files are pure functions, easy to test
- No dependency on `Self` type in sub-modules

**Cons:**
- game.zig retains all pub fn signatures (~400+ lines of delegation boilerplate)
- Every internal function needs explicit dependency injection (many parameters)
- Split is less clean — logic in one file, signature in another
- game.zig is still ~900 lines of boilerplate + types + hook-dependent methods

---

### Approach D: Extract Only GUI (Targeted)

The GUI section alone is 401 lines and has clear boundaries. Extract just that one section using Approach A, B, or C, and defer the full split.

```zig
// Using Approach A (zero-bit field):
gui: @import("game_gui.zig").GuiMixin(Self) = .{},

// Using Approach B (accessor):
pub fn gui(self: *Self) GameGui { return .{ .game = self }; }

// Using Approach C (delegation):
pub fn renderGui(self: *Self, ...) void {
    return game_gui_impl.renderGui(&self.pipeline, ...);
}
```

**Pros:**
- Smallest change, lowest risk
- GUI is the largest section (401 lines) and most self-contained
- Validates the chosen pattern before committing to it everywhere

**Cons:**
- Only addresses 20% of the problem
- Doesn't establish a clear pattern for the rest (unless the POC succeeds)

## Recommendation

**Approach A (Zero-bit Field Mixins)** for the following reasons:

1. Zig-endorsed pattern — this is the official replacement for `usingnamespace` mixins
2. Largest line reduction (game.zig goes from 1978 → ~868 lines)
3. Cleanest namespacing — `game.hierarchy.setParent()` reads naturally and makes the domain explicit
4. Zero runtime cost — zero-bit fields add no memory overhead
5. Fallback to Approach C is mechanical if any issue arises
6. Breaking API changes are acceptable — this is an internal engine, not a public API with external consumers

**POC validation is required** before committing:
1. That `@fieldParentPtr` works correctly inside comptime-generic struct fields
2. That ZLS handles autocomplete and go-to-definition on mixin methods
3. That compile errors in mixin files produce clear diagnostics

## POC Plan

### POC 1: Zero-bit field mixin validation (Approach A)
Extract `game_hierarchy.zig` (~243 lines) using the `@fieldParentPtr` pattern. Verify:
- All tests still pass
- `@fieldParentPtr` works inside a comptime-generic struct (the `GameWith` return type)
- ZLS autocomplete works on `game.hierarchy.setParent()`
- Compile errors in the mixin show correct file/line
- Update call sites in the codebase to use the new `game.hierarchy.*` API

### POC 2: Accessor function validation (Approach B)
Extract the same hierarchy methods using the accessor function approach. Compare:
- API ergonomics at call sites (`game.hierarchy.foo()` vs `game.hierarchy().foo()`)
- Editor tooling quality
- Compile error clarity
- Method body readability (`@fieldParentPtr` boilerplate vs `self.game` access)

### POC 3 (using the winning pattern): Full extraction
Extract all 5 modules (hierarchy, GUI, gizmos, position, input) using the winning pattern.

## Files Affected

- `engine/game.zig` — reduced from 1978 to ~868 lines
- `engine/game_hierarchy.zig` — new (~243 lines)
- `engine/game_gui.zig` — new (~401 lines)
- `engine/game_gizmos.zig` — new (~185 lines)
- `engine/game_position.zig` — new (~175 lines)
- `engine/game_input.zig` — new (~106 lines)
- `engine/mod.zig` — no changes needed (re-exports from game.zig, which still has all types)
- Various call sites — API migration from `game.foo()` to `game.{module}.foo()`
