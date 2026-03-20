# RFC: Gizmo Categories

## Problem Statement

All gizmos are controlled by a single `g.gizmos_enabled` boolean. Games can't selectively show or hide groups of debug drawings. With multiple systems producing gizmos (physics collisions, pathfinding routes, bounding boxes, nav meshes, component debug views), the screen quickly becomes unreadable.

The debug inspector plugin needs per-category toggles so developers can focus on specific systems during debugging.

## Design

### Categories are declared in project.labelle

```zon
.gizmo_categories = .{
    .{ .name = "physics", .enabled = true },
    .{ .name = "collision", .enabled = true },
    .{ .name = "pathfinding", .enabled = false },
    .{ .name = "bounds", .enabled = false },
    .{ .name = "nav_mesh", .enabled = false },
    .{ .name = "ai", .enabled = false },
},
```

The CLI generates a comptime enum from this declaration:

```zig
const GizmoCategory = enum {
    physics,
    collision,
    pathfinding,
    bounds,
    nav_mesh,
    ai,
    all, // built-in: always present, used for uncategorized draws
};
```

### Drawing API

Every gizmo draw call takes a category as the first parameter:

```zig
g.drawGizmoArrow(.collision, x1, y1, x2, y2, 0xFF00FF00);
g.drawGizmoLine(.pathfinding, x1, y1, x2, y2, 0xFF0000FF);
g.drawGizmoRect(.bounds, x, y, w, h, 0xFFFFFF00);
g.drawGizmoCircle(.ai, cx, cy, radius, 0xFFFF00FF);
```

Existing calls without a category default to `.all`:

```zig
// Backward compatible — these still work
g.drawGizmoArrow(x1, y1, x2, y2, color);
// Equivalent to:
g.drawGizmoArrow(.all, x1, y1, x2, y2, color);
```

### Comptime dead code elimination

Categories declared with `.enabled = false` in project.labelle are compiled as no-ops:

```zig
pub fn drawGizmoArrow(self: *Self, comptime category: GizmoCategory, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
    // Comptime check: if category is disabled at build time, entire function is eliminated
    if (comptime !initialCategoryState(category)) return;

    // Runtime check: category may have been toggled at runtime
    if (!self.gizmo_category_enabled[@intFromEnum(category)]) return;

    self.gizmo_state.drawArrow(self.allocator, x1, y1, x2, y2, color);
}
```

When a category is `.enabled = false` in project.labelle, the comptime check eliminates the entire function body. Zero overhead for disabled categories — not even a branch instruction.

### Runtime toggle

Categories enabled at comptime can be toggled at runtime:

```zig
g.setGizmoCategory(.physics, false);    // hide physics gizmos
g.setGizmoCategory(.bounds, true);      // show bounding boxes
g.isGizmoCategoryEnabled(.collision);   // query state

g.gizmos_enabled = false;               // master switch (existing, overrides all)
```

Categories disabled at comptime cannot be enabled at runtime — the draw calls are compiled out. This is intentional: shipping builds with `.enabled = false` have zero gizmo overhead.

### How the GizmoDraw struct changes

```zig
// Before
pub const GizmoDraw = struct {
    kind: Kind,
    x1: f32, y1: f32,
    x2: f32, y2: f32,
    color: u32,
    space: Space,
};

// After
pub const GizmoDraw = struct {
    kind: Kind,
    x1: f32, y1: f32,
    x2: f32, y2: f32,
    color: u32,
    space: Space,
    category: u8,       // index into GizmoCategory enum
};
```

The renderer filters draws by category before rendering:

```zig
pub fn renderGizmoDraws(self: *Self, draws: []const GizmoDraw) void {
    for (draws) |d| {
        if (!self.gizmo_category_enabled[d.category]) continue;
        drawGizmoPrimitive(d, self.screen_height);
    }
}
```

### Plugin usage

Plugins use categories to tag their gizmos:

```zig
// box2d plugin
if (show_collision_gizmos) {
    game.drawGizmoArrow(.collision, pos_a.x, pos_a.y, pos_b.x, pos_b.y, 0xFF00FF00);
}

// pathfinding plugin
game.drawGizmoLine(.pathfinding, from.x, from.y, to.x, to.y, 0xFF0000FF);
```

If the game doesn't declare a category that the plugin uses, the compiler errors with a clear message:

```
error: enum 'GizmoCategory' has no member named 'collision'
note: consider adding .{ .name = "collision" } to gizmo_categories in project.labelle
```

### Debug inspector integration

The debug plugin iterates all categories at comptime and renders toggle checkboxes:

```zig
const GameType = @TypeOf(game.*);
const categories = comptime GameType.gizmoCategoryNames();

inline for (categories) |cat_name| {
    var enabled = game.isGizmoCategoryEnabled(
        @field(GameType.GizmoCategory, cat_name)
    );
    if (Gui.checkbox(cat_name, &enabled)) {
        game.setGizmoCategory(
            @field(GameType.GizmoCategory, cat_name),
            enabled,
        );
    }
}
```

This renders one checkbox per declared category — all discovered at comptime.

## Implementation Plan

### Phase 1: Core + Engine (labelle-core, labelle-engine)

1. Add `category: u8` field to `GizmoDraw` in labelle-core
2. Add `GizmoCategory` comptime parameter to `GameConfig`
3. Add `gizmo_category_enabled: [N]bool` runtime state to the game
4. Update `drawGizmoArrow/Line/Rect/Circle` to accept category
5. Add backward-compatible overloads that default to `.all`
6. Update `renderGizmoDraws` to filter by category

### Phase 2: CLI (labelle-cli)

1. Parse `gizmo_categories` from project.labelle
2. Generate `GizmoCategory` enum in main.zig
3. Pass to `GameConfig`
4. Default: if `gizmo_categories` is not declared, use `enum { all }` (current behavior)

### Phase 3: Plugins

1. Box2D plugin: use `.collision` and `.physics` categories
2. Debug inspector: render per-category toggles
3. Update existing gizmo calls in examples

## Backward Compatibility

- Projects without `gizmo_categories` get a single `.all` category (current behavior)
- Existing `drawGizmoArrow(x1, y1, x2, y2, color)` calls continue to work (default to `.all`)
- `g.gizmos_enabled` master switch remains — overrides all categories
- No changes required for games that don't use categories

## Open Questions

1. **Should categories have a default color?** E.g. `.{ .name = "physics", .color = 0xFF00FF00 }` — draws without an explicit color use the category's default. This simplifies plugin code: `g.drawGizmoArrow(.collision, x1, y1, x2, y2)` uses the collision category's green color.

2. **Should plugins be able to declare their own categories?** E.g. the box2d plugin exports `pub const GizmoCategories = .{ "collision", "physics" }` and the assembler merges them with the project's declaration (similar to `Components` auto-discovery).

3. **Maximum number of categories?** Using `u8` for the category index supports up to 256 categories. The `gizmo_category_enabled` array is `[N]bool` where N = number of declared categories. For most games this is 5-15.
