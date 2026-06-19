# RFC: Project-configurable Y-axis convention

**Status:** Draft (revision 1)

**Tracking:** labelle-gfx#274

## Problem

A labelle game today silently mixes two opposite vertical conventions, and
nothing reconciles them. From labelle-gfx#274, reproduced on a screen-space
(no-camera) bgfx project at `design_h = 600`:

- **Entity positions are y-up.** `setPosition(e, .{ .x = 400, .y = 50 })` +
  a circle Shape renders near the **bottom** of the window; `y = 550` renders
  near the **top**. The renderer flips `Position.y` to screen space on the way
  out (`screen_height - y` / the NDC `1 - (py/design_h)*2`).
- **Mouse picking is y-down.** `game.screenToDesign(getMouseX, getMouseY)`
  returns design coordinates with `y = 0` at the **top** (it forwards raw
  window coordinates through `renderer.screenToDesign`).

So for a screen-space layer the two spaces are vertically mirrored: a click at
the top of the window yields a *small* design `y`, but the entity you place
there needs a *large* `y`. Callers must hand-flip by `design_h - y`, and
nothing in the API tells them to.

This also produces a concrete, separate rendering bug (#274 part 2). In the
retained Shape draw (`labelle-gfx/src/retained_engine/draw.zig`):

```zig
.line => |line| {
    B.drawLine(spos.x, spos.y, spos.x + line.end.x, spos.y + line.end.y, line.thickness, c);
},
```

`spos` is the shape's position **already flipped into render space**, but
`line.end` is added directly to it — so the `end` offset effectively lives in
flipped space, not the same logical space as the entity's `position`. To draw
a line from a source entity to a logical-space target you must negate **only**
`end.y`: `end = .{ .x = tx - sx, .y = sy - ty }`. A line authored entirely in
logical coordinates lands with a mirrored endpoint. (Empirically: in a
drag-to-place tool the placed node was correct but the connector line went to
the mirrored Y until `end.y` was negated.)

The root cause is that "which way is +Y" is an **implicit, inconsistent**
property scattered across the engine (positions, `screenToDesign`), the gfx
renderer (the flip), and per-Shape draw code (the `end` offset). There is no
single place that defines it and no way for a game to pick the convention that
matches how it authors content.

## Goals

- Give a project **one** Y-axis convention that every coordinate-producing and
  coordinate-consuming surface agrees on: entity positions, `screenToDesign`,
  the renderer flip, and Shape sub-offsets (`line.end`, future shapes).
- Make the convention **explicit and configurable** per project via
  `project.labelle`, defaulting to today's behavior so no existing game moves.
- Fix #274 part 2: a Shape authored entirely in logical coordinates (position
  **and** `end`) must compose without a manual per-axis flip.

## Non-goals

- **Per-layer** Y conventions. The convention is project-global. (Screen-space
  vs world-space layers already differ in *origin/camera*, not in +Y meaning.)
- Changing **camera/world-space** picking. `cam.screenToWorld` already maps
  screen → world correctly for camera layers; this RFC is about the
  no-camera / direct screen-space path and the logical↔render flip.
- Changing the wire/storage meaning of `Position` for existing saves (see
  Migration).

## Proposal

Add a top-level enum to `project.labelle`:

```zig
.y_axis = .up,   // default — y=0 at the BOTTOM, +Y goes up (today's behavior)
// or
.y_axis = .down, // y=0 at the TOP, +Y goes down (matches mouse / typical UI)
```

`.y_axis` defines the **logical** coordinate convention — the space in which
`Position`, `screenToDesign`, and Shape offsets are all expressed. The renderer
is the *only* layer that knows about screen/NDC space, and it applies (or
skips) the vertical flip based on `.y_axis` so that everything above it shares
one convention:

| Surface | `.y_axis = .up` (default) | `.y_axis = .down` |
|---|---|---|
| `Position.y` author space | y-up (0 = bottom) | y-down (0 = top) |
| Renderer Position→screen | flip (`h - y`) | **no flip** (identity) |
| `screenToDesign` returns | y-up (flip the raw mouse Y) | y-down (raw) |
| `line.end` / Shape offsets | logical, composed pre-flip | logical, no flip |

Net effect: with `.up`, the framework now flips mouse Y for you so picking
agrees with placement; with `.down`, nothing flips and the whole pipeline is
natively y-down (the natural choice for UI / screen-space games, which is where
#274 was found).

The Shape fix (#274 part 2) falls out for **both** settings: the renderer
composes `position + end` in logical space and flips the *final* endpoint once,
instead of flipping `position` and then adding a logical offset on top.

## Per-layer changes

### 1. `project.labelle` + labelle-assembler

- Parse `.y_axis: enum { up, down } = .up` in the project config; surface it on
  the generated config so the engine/gfx can read it at comptime (it is a
  build-time constant, like `.backend`).
- Emit a compile error for an unknown value; default `.up` when the key is
  absent (back-compat).

### 2. labelle-gfx — renderer flip + Shape composition (the core change)

- Thread the convention into the renderer (a comptime `y_axis` on the render
  config, mirroring how the backend is parameterized).
- The single vertical flip (`toNdcY` / `screen_height - y`) becomes conditional
  on `y_axis`: applied for `.up`, identity for `.down`.
- Shape sub-offsets are composed in logical space **before** the flip. For the
  `.line` case, compute the logical endpoint `(pos.x + end.x, pos.y + end.y)`
  and run *that* through the same position→screen transform as `pos`, rather
  than `flip(pos) + end`. Same treatment for any current/future offset-bearing
  Shape (`triangle` vertices are already relative offsets — audit them here).

### 3. labelle-engine — `screenToDesign` + an accessor

- `screenToDesign` returns coordinates in the logical convention: for `.up` it
  flips the raw window Y (`design_h - y`) so the result is directly comparable
  to `Position`; for `.down` it returns the raw value (today's behavior).
- Expose the active convention (e.g. `game.yAxis()` / a comptime constant) so
  game code and tools can branch if they must.
- `setPosition` is unchanged — `Position` is *already* the logical space; this
  RFC only changes what "logical" means relative to the screen and makes the
  consumers agree.

## Migration plan

- **Default `.up` = exact current behavior for positions + rendering.** No
  existing game's entities move.
- **`screenToDesign` for `.up` becomes flipped** — this is the one behavior
  change for existing projects, and it is the *fix*: today callers who fed
  `screenToDesign` straight into placement were already wrong (or hand-flipping)
  for screen-space layers. We should (a) gate this behind an engine version
  bump and call it out loudly, and (b) provide a `screenToDesignRaw` escape
  hatch for anyone who genuinely wants window coordinates.
- **The `.line` `end` fix is technically breaking** for any game that worked
  around the bug by negating `end.y`. Such games render a mirrored line *after*
  the fix. Enumerate these in the release notes; they are rare (the bug is
  recent) and the fix direction is "stop negating."
- Roll out as: gfx (renderer + Shape compose) → engine (`screenToDesign` +
  accessor) → assembler (`project.labelle` key) → consumers opt into `.down`
  where it helps (FP's screen-space UI/menus are candidates).

## Alternatives considered

1. **Document-only.** Add a doc note ("for direct screen-space picking, flip
   Y") and fix nothing. Cheap, but leaves the footgun and the `.line` bug, and
   every screen-space game re-derives the same `design_h - y` flip.
2. **Force one convention globally** (always y-down to match the mouse, or
   always y-up). Simplest mental model, but it's a hard breaking change for the
   whole ecosystem with no opt-out, and "best" differs by game type (UI wants
   y-down; physics/platformer math often wants y-up).
3. **Runtime API instead of project config** (`game.setYAxis(...)`). More
   flexible but the flip wants to be a comptime constant in the renderer for
   zero per-frame cost, and a mid-run flip would invalidate every stored
   position — project-build-time is the right granularity.
4. **Fix only #274 part 2** (the `.line` `end` composition) and leave part 1.
   Removes the concrete render bug but keeps the picking/placement mismatch and
   the implicit convention. Worth doing regardless, but insufficient alone.

This RFC is **alternative 1+2's middle path**: one convention per project,
explicit, default-compatible.

## Open questions

1. **Should `.up` really change `screenToDesign`?** It's the correct fix, but
   it's a silent behavior change for existing `.up` (default) projects. Options:
   (a) change it + version-gate + `screenToDesignRaw` escape hatch (this RFC's
   lean); (b) leave `screenToDesign` raw and add a new
   `screenToLogical`/`pickPoint` that respects `.y_axis`, so nothing existing
   moves. (b) is safer but adds a second picking API.
2. **Interaction with camera layers.** For world-space layers, `screenToWorld`
   already does the right thing; does `.y_axis` need to feed the camera math, or
   is it strictly the no-camera/logical-flip knob? (Believed strictly the
   latter — confirm against `Camera2D`.)
3. **Touch / gizmo / gui input.** `screenToDesign` has siblings
   (`getTouchX/Y`, gizmo hit-testing, imgui bridge mouse). Which of these are in
   "logical" space and must follow `.y_axis`, vs. raw window space that
   shouldn't?
4. **Storage / saves.** `Position` values in `.zon` scenes + save files are
   authored in the logical convention. A project that flips `.y_axis` after
   shipping content would mirror all of it — do we need a migration note, or is
   "don't flip mid-project" sufficient guidance?
5. **Shape audit.** Beyond `line.end`, which Shapes carry logical sub-offsets
   that need the same pre-flip composition (`triangle` p2/p3, any future
   `polygon`/`arrow`)? Enumerate so the gfx change is complete, not just `.line`.
