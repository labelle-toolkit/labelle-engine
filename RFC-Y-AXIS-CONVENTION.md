# RFC: Project-configurable Y-axis convention

**Status:** Draft (revision 5 — scene audit done: FP + ricochet both y-up; Q2 promoted to load-bearing)

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
  `project.labelle`, defaulting to the screen-native `.down`; existing games
  declare `.y_axis = .up` (a no-op declaration under Q1→(b)), and the rollout
  prevents any *silent* flip (see Migration).
- Fix #274 part 2: a Shape authored entirely in logical coordinates (position
  **and** `end`) must compose without a manual per-axis flip.

## Non-goals

- **Per-layer** Y conventions. The convention is project-global. (Screen-space
  vs world-space layers already differ in *origin/camera*, not in +Y meaning.)
- Changing what **camera/world-space** picking *means*. `cam.screenToWorld`
  keeps mapping screen → world; this RFC only routes its vertical flip through
  the same single core transform as the no-camera path so the two can't diverge
  (Q2). World coordinates remain the logical convention.
- Changing the wire/storage meaning of `Position` for existing saves (see
  Migration).
- Changing **labelle-imgui** or imgui's coordinate space. The bridge forwards
  raw window-space (y-down) mouse coordinates **unchanged**
  (`addMousePosEvent(mouse_x, mouse_y)` / `imgui_bridge_mouse_pos`), and imgui
  is intrinsically y-down (top-left origin) — both are correct under *any*
  `.y_axis`, so the bridge needs no change (it's the Q3 rule: raw input stays
  y-down). imgui-based *tools* that manipulate the world (drag-to-place, gizmo
  hit-testing, an inspector) convert imgui's screen-space mouse to logical via
  the engine's `screenToLogical` — that's game/engine code, not the bridge.

## Proposal

Add a top-level enum to `project.labelle`:

```zig
.y_axis = .down, // DEFAULT — y=0 at the TOP, +Y goes down (matches the mouse,
                 //           the screen, and the renderer's native space)
// or
.y_axis = .up,   // y=0 at the BOTTOM, +Y goes up (today's behavior; math-/
                 //           platformer-natural — every existing game must set this)
```

`.y_axis` defines the **logical** coordinate convention — the space in which
`Position`, `screenToDesign`, and Shape offsets are all expressed. The renderer
is the *only* layer that knows about screen/NDC space, and it applies (or
skips) the vertical flip based on `.y_axis` so that everything above it shares
one convention:

| Surface | `.y_axis = .down` (DEFAULT) | `.y_axis = .up` |
|---|---|---|
| `Position.y` author space | y-down (0 = top) | y-up (0 = bottom) |
| Renderer Position→screen | **no flip** (identity) | flip (`h - y`) |
| `screenToDesign` returns | y-down (raw) | y-up *or* raw — see Q1 |
| `line.end` / Shape offsets | logical, no flip | logical, composed pre-flip |

**Why `.down` is the default.** The renderer's internal/NDC space is *already*
y-down (`renderer.zig` flips `Position.y` via `screen_height - y` on the way
out, and a comment there documents the internal space as y-down); the mouse and
the whole screen are y-down. So `.down` is the framework's *native* space — it
makes the default pipeline **flip-free and internally consistent**: positions,
mouse, and rendering all agree with zero reconciliation, which is exactly what
the #274 screen-space case wanted. `.up` then becomes the explicit, opt-in
"math-natural" convention (bottom-origin, +Y up) that physics/platformer games
— and **every game produced before this RFC** — must now declare.

This inverts the prior draft (which defaulted `.up` for zero migration). The
trade is deliberate: new games get the consistent, footgun-free convention by
default, and the (small, known) set of existing games each add one line.

The Shape fix (#274 part 2) falls out for **both** settings: the renderer
composes `position + end` in logical space and flips the *final* endpoint once,
instead of flipping `position` and then adding a logical offset on top.

## Per-layer changes

### 1. labelle-core — the convention's home

- `labelle-core` owns `position.zig` + `coordinates.zig` and is the shared base
  both engine and gfx depend on. Define `YAxis = enum { up, down }` and the
  canonical vertical transform **here**, so there is exactly one definition of
  "which way is +Y" that every layer routes through (this is what keeps the
  camera and no-camera paths from diverging — Q2).

### 2. labelle-gfx — renderer flip + Shape composition (the core change)

- Thread the convention into the renderer (a comptime `y_axis`, mirroring how
  the backend is parameterized) and route the one vertical flip through the
  core transform: applied for `.up`, identity for `.down`.
- `worldToScreen`/`screenToWorld` (camera) must use the **same** core transform
  so a camera layer and a no-camera layer can never disagree (Q2).
- Shape sub-offsets are composed in logical space **before** the flip: for
  `.line`, transform the logical endpoint `(pos.x + end.x, pos.y + end.y)`
  through the same position→screen path as `pos`, not `flip(pos) + end`. Audit
  every offset-bearing Shape — `triangle` p2/p3 for sure, `rectangle` extent to
  verify, `circle` (scalar radius) exempt (Q5).

### 3. labelle-engine — picking + accessor

- Keep `screenToDesign` **raw** (window space, y-down) so existing games are
  untouched; add `screenToLogical` that applies `.y_axis` for axis-aware
  picking (Q1 → (b)). Gizmo hit-testing routes through `screenToLogical`, not a
  raw-mouse-vs-logical-position comparison (Q3).
- Expose the active convention (`game.yAxis()` / a comptime constant).
- `setPosition` is unchanged — `Position` is *already* the logical space; the
  RFC only changes what "logical" means relative to the screen.

### 4. `project.labelle` + labelle-assembler

- `src/config.zig` parses `.y_axis: YAxis` from `project.labelle` and emits it
  onto the generated game config (comptime, like `.backend`).
- **Unset-`.y_axis` build guard** (the safety net — see Migration): during the
  transition release, an absent key is a hard error naming both choices.
- Update the bundled example projects.

### 5. labelle-cli — `labelle init` scaffold

- `src/cli/init.zig` writes `.y_axis = .down` into the generated
  `project.labelle` so new projects get the default convention explicitly.

## Repos & rollout order

Five framework repos + two game repos (plus the assembler's bundled examples).
This is a **"core diamond"** change — release strictly in dependency order so
no consumer ever sees an unbuildable intermediate:

| Stage | Repo | Role |
|---|---|---|
| 1 | **labelle-core** | `YAxis` enum + canonical flip transform (single source of truth) |
| 2 | **labelle-gfx** | renderer flip-conditional, Shape compose, camera transform |
| 2 | **labelle-engine** | `screenToLogical` + `yAxis()` accessor; thread the config |
| 3 | **labelle-assembler** | parse/emit `.y_axis`, the unset-guard, bundled examples |
| 3 | **labelle-cli** | `labelle init` scaffolds `.down` |
| 4 | **flying-platform-labelle** | add `.y_axis = .up` (a pure declaration under Q1→(b)) |
| 4 | **ricochet** | add `.y_axis = .up` |

Order: **core → (gfx, engine) → (assembler, cli) → game pin-bumps + `.y_axis`
declarations.** gfx and engine both consume core and can go in parallel once
core ships; assembler + cli both consume engine/gfx; the games are last. The
unset-guard means a game that bumps the assembler *before* declaring `.y_axis`
gets a build error, not a silent flip — so each game can adopt at its own pace.

**Explicitly *not* involved:** `labelle-imgui` (forwards raw y-down mouse
unchanged; imgui is intrinsically y-down — see Non-goals) and `zig-utils`
(convention-free vector math). The convention lives in `labelle-core` and is
consumed upward; these two sit outside that path.

## Migration plan

Defaulting to `.down` is a **breaking change for every existing game**: a
project that bumps to the introducing engine version *without* setting
`.y_axis` would have all of its y-up positions silently flipped (the whole game
renders upside-down). The rollout must make that impossible to hit silently.

- **Transition window — require an explicit `.y_axis`.** In the introducing
  assembler/engine version, treat an *unset* `.y_axis` as a hard error (or a
  loud, build-failing warning) whose message names both choices: "set
  `.y_axis = .up` to keep current behavior, or `.y_axis = .down` for the new
  screen-native convention." No project flips by accident.
- **`labelle init` scaffolds `.down`** so new projects get the default from day
  one.
- **Existing games each add `.y_axis = .up`.** With Q1 resolved as **(b)** —
  keep `screenToDesign` raw and add a `screenToLogical` for callers who want
  axis-aware picking — adding `.up` is a **pure one-line declaration with no
  behavior change**: positions stay y-up, the renderer flip stays, the mouse
  stays raw exactly as today. Known set to patch: **flying-platform-labelle**,
  **ricochet**, and the in-repo example projects. (This is the main reason to
  prefer (b) over (a): it lets every existing game opt into `.up` without
  touching a line of game code.)
- **After the transition**, an unset `.y_axis` may quietly default to `.down`
  — only brand-new projects reach that path, and `labelle init` writes it
  explicitly anyway.
- **The `.line` `end` fix is independently breaking** for any game (under
  either axis) that worked around the bug by negating `end.y` — it renders
  mirrored *after* the fix. Enumerate in release notes; the bug is recent and
  the fix direction is "stop negating."
- Roll out order: gfx (renderer flip-conditional + Shape compose) → engine
  (`screenToLogical`/accessor + the unset-`.y_axis` guard) → assembler
  (`project.labelle` key + `labelle init` template) → patch the known existing
  games with `.y_axis = .up`.

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

1. **`screenToDesign` under `.up`: flip it, or leave it raw + add
   `screenToLogical`?** With `.down` as the default this is no longer about the
   default path (default `.down` returns raw, which already agrees with y-down
   positions). It's purely about opt-in `.up` projects — i.e. every existing
   game. (a) flip `screenToDesign` for `.up` so picking matches placement, but
   that changes behavior for every game that adopts `.up`; (b) keep
   `screenToDesign` raw and add a `screenToLogical` that respects `.y_axis`, so
   an existing game adopting `.up` is a **pure no-op declaration**. The Migration
   plan now assumes **(b)** for exactly that reason — please confirm. (Trade-off:
   (b) means `.up` games still see a y-up-position / y-down-`screenToDesign`
   split unless they call `screenToLogical` — but that split is *intrinsic* to
   choosing a bottom-origin convention on a top-origin screen.)
2. **Interaction with camera layers — NOW LOAD-BEARING.** The scene audit
   (below) found that **flying-platform, the primary existing game, is
   camera-based** (`game.getCamera()` zoom/pan; input via
   `screenToDesign` → `cam.screenToWorld`). So `.y_axis` is *not* "strictly the
   no-camera knob" — the camera path is exactly what the main existing game
   uses, and `worldToScreen`/`screenToWorld` must route through the same single
   core transform as the renderer flip (and `.up` must reproduce today's camera
   behavior exactly, or FP regresses). This makes Q2 the **critical** path to
   nail, not a corner case. Trace how the `Camera2D` transform composes with the
   renderer flip today before implementing.
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
   Verify `rectangle` extent under the flip; `circle` (scalar radius) is exempt.
   (Extends into Q6 — sprite pivots are the same class of problem.)

6. **Sprite pivot composition *and direction*.** `syncPosition`
   (`renderer.zig:629`) flips `pos.y → toScreenY(pos.y)` and hands *screen*
   coordinates to the backend, which then applies the **pivot** (`bottom_center`
   etc.) in screen space. Two things to settle: (a) the pivot offset must
   compose with the flip the same way the Shape offsets do (audit alongside Q5);
   and (b) the pivot's vertical *extension is axis-dependent* — a `bottom_center`
   sprite at the same logical position extends its body **up** under `.up` and
   **down** under `.down`. Since pivots are the most common Y-anchor in the
   engine, this needs an explicit answer, not just "it works today under `.up`."

7. **Should the Shape/pivot offset fix ship *independently* of `.y_axis`?** The
   `line.end`-in-flipped-space bug (#274 part 2) is wrong under **both**
   conventions — it's a plain bug, not a convention choice. It could land as a
   **standalone gfx fix now** (compose offsets pre-flip), fixing #274 part 2 for
   existing games immediately and de-risking the 7-repo `.y_axis` rollout, which
   then only carries the *convention* change. Sequencing decision: bundle, or
   split the bug-fix out ahead?

**Lighter / forward-looking:**

- **PIE editor (labelle-gui).** When in-editor drag-to-place lands, it will need
  `screenToLogical` too — it's literally where #274 was found. Out of scope for
  this RFC, noted so it isn't forgotten when the editor grows placement.
- **Pre-migration scene audit — DONE.** Verified both existing games author
  **y-up**, so `.y_axis = .up` is a clean declaration for each:
  - **flying-platform (bgfx, camera-based):** the `main.jsonc` "second floor
    (below corridor)" comment is *narrative, not the convention* — the
    construction math is `f = floor(pos.y / SLOT_HEIGHT)` with "next floor up" =
    higher `f` = higher `y`, i.e. **y-up** (floor 1 at `y=93` renders *above*
    floor 0, and the transport ship "floating above" at `y=186` is highest). No
    manual Y inversion anywhere; input is `screenToDesign` → `cam.screenToWorld`.
    The catch is that FP is **camera-based**, which is what promoted Q2 to
    load-bearing — its `.up` adoption hinges on the camera path, not the
    no-camera flip.
  - **ricochet (raylib, no-camera / screen-space):** y-up via the engine
    default, no manual flip. It's the screen-space path #274 is about, but its
    aiming is **entity-to-entity** (`combat.aimAt`, convention-agnostic) with
    **no mouse→world picking**, so it never hits the #274 mismatch. Clean no-op.
  - **Takeaway:** the picking mismatch in #274 bit a *new* drag-to-place tool,
    not either shipped game — both are safely y-up. The real implementation risk
    for existing games is **Q2 (FP's camera)**, not the picking/`screenToDesign`
    change.
