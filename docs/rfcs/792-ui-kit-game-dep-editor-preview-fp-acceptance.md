# RFC 792: UI-kit as a game dependency, editor FrameResolver preview, and FP build-menu acceptance

**Status:** Draft
**Tracking issue:** [labelle-engine#792](https://github.com/labelle-toolkit/labelle-engine/issues/792) (the remainder of #787; it also absorbs #771)
**Depends on:** labelle-gui#215 (`ui_kit` phase 2). The issue's 2026-09-08 audit says it merged on 2026-07-11.
**Related:** RFC-FONT-LOADER (#448), RFC-ASSET-STREAMING, `examples/uikit-gpu/` (#787 deliverable 1)

---

## 1. Problem and context

### 1.1 What the code shows today (verified in this checkout)

The engine half of the UI-kit seam is already shipped:

| Surface | Where | What it does |
|---|---|---|
| `UiDrawCmd`, `UiRect`, `UiRgba8`, `UiUvRect`, `UiRenderOptions`, `UiFontStore`, `BakedUiFont`, `ResolvedUiFrame`, `convertUiDrawCommand`, `renderUiCommands` | `src/ui_draw_list.zig`, re-exported at `src/root.zig:242-257` | The engine copies the kit's `DrawCmd` structurally. `convertCommand` duck-types any union whose tags match. Unknown tags return `null`, so a newer kit still works against an older engine. |
| `game.submitUiDrawList(cmds, opts)` | `src/game/ui_kit_mixin.zig` | Keeps one frame of commands and duplicates the text slices. Several submits in a frame accumulate, and the last `opts` wins. |
| `game.renderSubmittedUi()` | called from `src/game/loop_mixin.zig:424` | Draws after the world and particle passes and before gizmos, then drains the list. |
| `game.bakeUiFont`, `game.uiFont`, `game.reuploadUiFonts` | `ui_kit_mixin.zig` | Bakes a TTF/OTF through the injected `FontBackend` into a white-RGBA atlas and keeps the glyph tables. This is the engine half of the kit's `FontResolver`. |
| `game.resolveUiFrame(name)` | `ui_kit_mixin.zig` | UVs come from the atlas's logical dims (`meta.size`). Returns `null` for rotated frames or when `meta.size` is missing. This is the engine half of the kit's `FrameResolver`. |
| Tests | `test/ui_draw_list_test.zig` (wired in `build.zig:364`) | UV→pixel mapping, text pass, focus ring, conversion, NaN/corrupt-glyph guards, bake, multi-submit, frame resolution, surface-loss re-upload, and submit→render ordering, all against a recording renderer. |

The real-GPU proof is `examples/uikit-gpu/` (README and `screenshot.png`). It does three things by hand that no game can do through the toolkit today:

1. **Module graph.** In `examples/uikit-gpu/build.zig`, `ui_kit_mod` is created with `b.createModule(.{ .root_source_file = .{ .cwd_relative = "../../../labelle-gui/src/ui_kit/mod.zig" } })`. The comment says labelle-gui does not export `ui_kit` as a build module. `build.zig.zon` assumes a flat sibling checkout. That is why the example is local-dev and not built in CI.
2. **Resolver glue (about 40 lines).** In `examples/uikit-gpu/main.zig`:
   - `resolveFrame` maps `ResolvedUiFrame` to `ui_kit.render.ResolvedFrame`.
   - `resolveFont` and `metricsFromBaked` wrap `BakedUiFont` in a `ui_kit.font.FontMetrics` (`@ptrCast` of three slices plus four scalars).
   - Both use `context = undefined` and read a global `g`.
3. **Per-frame plumbing.** `submitUi` runs `layout.apply`, then `render.build`, then `submitUiDrawList` with a hand-filled `UiRenderOptions` (atlas texture id and dims, default font, focus styling). Focus is a fixed `button_id`, so there is no navigation.

### 1.2 Constraints found in the existing engine code that the remaining work has to respect

- **C1: one atlas per submit.** A `UiDrawCmd.textured_quad` carries a UV but no texture. `UiRenderOptions.atlas_texture`, `atlas_width` and `atlas_height` apply to every quad in one submit. `resolveUiFrame` does return a per-frame `texture_id`, but the DrawList drops it. So a theme has to be a single atlas, or the game has to split its submits by atlas.
- **C2: sprite lookup order across atlases is undefined.** `TextureManager.findSprite` (`src/atlas.zig:499`) returns the first match it finds while iterating a `StringHashMap` of atlases. If two theme packs are loaded together and both define `panel`, which one wins is undefined. A theme swap therefore has to unload the old theme atlas, or the lookup has to be scoped to an atlas.
- **C3: the engine must not import labelle-gui.** `src/ui_draw_list.zig` explains why: it would pull the whole editor build into every game. `test/agnostic_guard_test.zig` covers both UI-kit files. Any "engine re-exports the kit" option has to live outside the core `engine` module.
- **C4: gamepad input already exists.** `game.isGamepadButtonPressed`, `isGamepadAvailable` and `getGamepadAxisValue` are in `src/game/input_mixin.zig`. Focus navigation needs no new engine input surface.

### 1.3 Not verified here (outside this checkout)

The workspace does not contain labelle-assembler, labelle-gui or flying-platform-labelle. I have not checked these claims against their source:

- that `ui_kit` on labelle-gui `main` (after #215) still has no `b.addModule("ui_kit", …)`;
- the exact shape of the kit's `FrameResolver`, `FontResolver` and focus API beyond what `examples/uikit-gpu/main.zig` uses;
- how the assembler declares plugin and module dependencies in `project.labelle`;
- the current FP build-menu implementation;
- the editor's `atlas.Index` API.

Each of these is listed as a **pre-implementation check** in §6.

### 1.4 The three remaining deliverables

- **(1b)** A game can declare a `ui_kit` dependency through the assembler, and the two resolvers come with the toolkit instead of being hand-written.
- **(2)** labelle-gui's editor previews kit UI by using its `atlas.Index` as the DrawList `FrameResolver`.
- **(3)** Acceptance: Flying-Platform's build menu is rebuilt on the kit with gamepad focus navigation, and its UI theme can be swapped through an asset pack.

## 2. Proposed design

Everything in this section is a **proposal**. None of it exists yet.

### 2.1 (1b) labelle-gui exports `ui_kit` as a standalone build module

In labelle-gui `build.zig`, add:

```zig
_ = b.addModule("ui_kit", .{
    .root_source_file = b.path("src/ui_kit/mod.zig"),
    .target = target,
    .optimize = optimize,
});
```

The example's build comment says the kit is "dependency-free". If that holds, exporting it adds no transitive editor dependencies. Consumers use `b.dependency("labelle_gui", …).module("ui_kit")`. Zig builds dependency modules lazily, so referencing the module does not compile the editor executable. Pre-check P2 confirms this.

### 2.2 (1b) A thin glue module `labelle-ui-kit-bridge`, kept out of `engine`

The glue goes in a small module that imports both `engine` and `ui_kit`. It cannot go in `engine` itself (C3). I propose putting it in the engine repo as a sub-package (`ui_kit_bridge/`, the same in-tree sub-package pattern as `animation/`, `scene/` and `jsonc/`). It gets its own `build.zig.zon` dependency on labelle-gui, which is only fetched when the bridge is used. Its surface:

```zig
// ui_kit_bridge/src/root.zig  (proposed)
pub fn Bridge(comptime Game: type) type {
    return struct {
        game: *Game,
        fonts: FontMetricsCache,              // name -> ui_kit.font.FontMetrics, built from game.uiFont()

        pub fn frameResolver(self: *@This()) ui_kit.render.FrameResolver;  // -> game.resolveUiFrame
        pub fn fontResolver(self: *@This()) ui_kit.render.FontResolver;    // -> game.uiFont + metricsFromBaked
        pub fn submit(self: *@This(), tree: *ui_kit.Tree, root: ui_kit.ElementId,
                      viewport: UiRect, focused: ui_kit.ElementId, style: SubmitStyle) !void;
        // layout.apply -> render.build -> game.submitUiDrawList(items, opts),
        // filling atlas_texture/atlas_width/atlas_height from the theme atlas (§2.5).
    };
}
```

- The resolvers use `self` as their `context`. The demo's `context = undefined` plus a global `g` goes away.
- `FontMetricsCache` is rebuilt whenever `bakeUiFont` replaces a name. `ui_fonts` is a hash map, so a re-bake invalidates the borrowed slices. This RFC proposes keying the cache on a `ui_fonts` generation counter (a new `u32` on the store, bumped by `put`). It is the only engine-core change in 1b, and it is additive.
- The `metricsFromBaked` `@ptrCast` is the identity cast documented in RFC-FONT-LOADER §3. The bridge adds a comptime `@sizeOf`/`@alignOf`/field-offset check that the core and kit `Glyph`, `CodepointEntry` and `KernPair` structs match, so drift fails at compile time and does not corrupt memory.

### 2.3 (1b) Assembler wiring

When `project.labelle` opts in, the assembler-generated `build.zig` will:

1. fetch labelle-gui, take `.module("ui_kit")`, and apply the same `overrideImport` core-unification the example does (`examples/uikit-gpu/build.zig`, `overrideImport`);
2. add `ui_kit` and `ui_kit_bridge` to the game module's imports;
3. expose a ready-made `Bridge(Game)` in the generated main, so hooks reach it through `HookContext`'s typed game (#855) and no globals are needed.

The opt-in flag's spelling (for example `.ui_kit = true` or a `.modules` entry) follows whatever convention the assembler uses for optional modules. That is pre-check P3. Projects that do not opt in generate byte-identical output.

### 2.4 (2) Editor FrameResolver preview (labelle-gui)

The editor implements `ui_kit.render.FrameResolver` over its own `atlas.Index`: UV = frame rect / atlas logical size, and `frame_px` = frame size. This is the same math as `resolveUiFrame`, which avoids a dependency on the engine. The editor already draws through its own renderer, so it consumes the DrawList with its own sink. `renderUiCommands` takes any `sink` with `drawTexturedQuad` and `drawSolidRect` (`src/ui_draw_list.zig`, `renderCommands` doc). The editor can therefore use the engine's converter and renderer loop as a pure function if it already depends on the engine, or copy the roughly 60 lines if it does not. Pre-check P4 settles which.

For parity, both resolvers should give the same UVs for the same atlas JSON. A shared golden fixture (§5) checks this.

### 2.5 (3) Theme atlas and theme swap via asset pack

To fit C1 and C2:

- A UI theme is exactly one atlas resource whose JSON includes `meta.size`. `resolveUiFrame` already requires this and returns `null` without it. Frames are packed unrotated.
- The bridge keeps a "current theme atlas" name. `SubmitStyle` and `UiRenderOptions` get their atlas fields from that atlas (`texture_id`, logical × `texture_scale`), so the game no longer passes texture ids by hand.
- **Swap** works as follows:
  1. `bridge.setTheme(atlas_name)` acquires the new pack's atlas through the existing catalog (RFC-ASSET-STREAMING).
  2. Once the atlas is loaded, it unloads the old theme atlas, which removes the C2 ambiguity.
  3. It switches the current name.
  4. If the old atlas is still referenced, the swap waits one frame.
- An optional, additive engine change is `resolveUiFrameIn(atlas_name, sprite_name)`. It removes the hash-order dependence completely, so two themes could coexist during a cross-fade. It is recommended but not required for acceptance.

### 2.6 (3) FP build menu on the kit with gamepad focus nav

- The build menu becomes a `ui_kit.Tree`: a panel, a grid or column of focusable buttons, and labels.
- Focus navigation comes from the kit's focus API if it has one (pre-check P1). Otherwise the bridge adds a small `FocusNav`: D-pad or left-stick edges move focus to the nearest focusable element in that direction by rect centre, `A` activates (`button.action_id`), and `B` closes. Input comes through the existing `game.isGamepadButtonPressed` and `getGamepadAxisValue` (C4), with an axis dead-zone and an edge trigger.
- Activation emits the same game events the current FP menu emits, so gameplay code does not change.

## 3. Alternatives considered

| Alternative | Why not chosen |
|---|---|
| **The engine re-exports the kit's `Tree`/`render` surface** (named in the issue as a minimal path) | `engine` would import labelle-gui. That breaks C3 and the stated reason in `ui_draw_list.zig`, and every game, including those without UI, would fetch the editor repo. |
| **Keep the `cwd_relative` path wiring and document it** | Needs a flat sibling checkout, cannot be fetched by a hash-pinned `build.zig.zon`, and cannot run in CI. This is the status quo the issue wants removed. |
| **Move `ui_kit` into its own repo** | The cleanest split long-term, but it is a cross-repo migration beyond this issue. §2.1 keeps that option open, because consumers only see the `"ui_kit"` module name. |
| **Each game writes its own resolver glue (as in the demo)** | Repeats the unsafe `@ptrCast` in every game with no layout check, plus the global-state pattern. |
| **Per-command texture ids in `UiDrawCmd` (multi-atlas themes)** | Changes the cross-repo `DrawCmd` contract in both repos. Single-atlas themes are enough for acceptance. Revisit if a theme outgrows one atlas. |
| **Load multiple themes and pick by sprite-name prefix** | Works around C2 by naming convention only. It is fragile, and a pack author can break it. |

## 4. Acceptance criteria

1b
- [ ] labelle-gui exports a `ui_kit` build module, and a downstream `b.dependency(...).module("ui_kit")` compiles without building the editor.
- [ ] `ui_kit_bridge` provides `frameResolver`, `fontResolver` and `submit`, has a comptime layout-parity check on the glyph structs, and has its own tests wired in `build.zig`.
- [ ] A project that sets the assembler opt-in gets `ui_kit` and `ui_kit_bridge` in its generated build. Projects without it generate byte-identical output.
- [ ] `examples/uikit-gpu` builds from hash-pinned or fetchable deps through the bridge, with no `cwd_relative` path and no hand-written resolvers, and is built in CI (compile only; running needs a GPU).
- [ ] The core `engine` module still has no labelle-gui import (`agnostic_guard_test` passes, and the dependency graph is unchanged for non-UI games).

2
- [ ] The labelle-gui editor previews an authored kit tree using `atlas.Index` as the `FrameResolver`. The editor and the engine give identical UVs on the shared fixture atlas.

3
- [ ] Flying-Platform's build menu is rendered from a `ui_kit.Tree` via the bridge. The old menu path is removed or disabled.
- [ ] The whole menu works with a gamepad alone: directional focus moves predictably, A activates, B closes, and the focus ring follows.
- [ ] Swapping to a second theme asset pack at runtime changes the menu's look with no code change and no stale frames from the old atlas (C2).

## 5. Validation plan (proposed; nothing below has been run for this RFC)

**Existing evidence** (from the repo, not re-run): `test/ui_draw_list_test.zig` covers the engine consumer against a recording renderer, and `examples/uikit-gpu/screenshot.png` shows all four command kinds on a real GPU (offscreen Metal, per its README).

**Proposed:**
1. **Bridge unit tests** (`ui_kit_bridge/test/*`): the resolvers return the expected UV and `frame_px` for a synthetic atlas; `FontMetricsCache` rebuilds after a re-bake (generation bump); the glyph-struct layout assertions compile; `submit` produces the expected `UiDrawCmd` sequence through the mock renderer used by `ui_draw_list_test.zig`.
2. **Assembler golden tests**: generated `build.zig` for a project with and without the opt-in; the opt-out output must equal today's byte for byte.
3. **CI compile of `examples/uikit-gpu`**: no GPU run on CI.
4. **Resolver parity fixture**: one atlas JSON plus a frame list, checked against both `resolveUiFrame` (engine test) and the editor's `atlas.Index` resolver (labelle-gui test).
5. **FocusNav tests** (if the bridge owns nav): scripted button/axis sequences over a fixed grid of rects give the expected focus path, with dead-zone and edge-trigger behaviour.
6. **Theme swap test**: load theme A, swap to B, then assert `resolveUiFrame("panel")` returns B's texture id and that A is unloaded. Run it with both atlases defining the same sprite names (the C2 regression).
7. **Manual acceptance on FP**: a gamepad-only playthrough of the build menu, plus `LABELLE_SCREENSHOT_PATH` captures before and after a theme swap, attached to the PR.

Builds and tests should run serially (`zig build -j1 test`) under the toolkit's CI resource limits.

## 6. Risks and pre-implementation checks

| # | Risk / check | Mitigation |
|---|---|---|
| P1 | The kit's focus API is unknown here. The demo only passes a static `focused` id. | Read labelle-gui `src/ui_kit/` after #215. Use the kit's nav if it exists; otherwise the bridge's `FocusNav` from §2.6. |
| P2 | The kit may not actually be dependency-free on `main`, so exporting it pulls in editor deps. | Check its imports before §2.1. If it is not, split out a `ui_kit` sub-package inside labelle-gui first. |
| P3 | The assembler's optional-module convention is unknown. | Follow the existing plugin/module convention. Do not invent a new `project.labelle` key without assembler review. |
| P4 | Whether the editor depends on the engine decides between reusing and copying `renderUiCommands`. | Decide in labelle-gui. The parity fixture (§5.4) protects either choice. |
| R1 | The `@ptrCast` identity cast between core and kit glyph structs drifts silently. | Comptime layout assertions in the bridge (§2.2). |
| R2 | `FontMetrics` slices borrowed from `ui_fonts` dangle after a re-bake (`UiFontStore.put` frees the old tables). | Generation-keyed cache (§2.2). Document that a re-bake invalidates resolvers until the next `submit`. |
| R3 | Sprite-name collisions between theme packs (C2). | Unload-on-swap (§2.5), plus the optional `resolveUiFrameIn`. |
| R4 | Multi-atlas themes are not expressible (C1). | State the single-atlas rule in the pack authoring docs. The `resolveUiFrame` null path already covers missing `meta.size` and rotated frames. |
| R5 | Cross-repo ordering (gui export, then bridge, then assembler, then FP) stalls partway. | Each step can be merged on its own and is backward compatible. The example keeps working at every step. |
| R6 | UI draws one frame late relative to gameplay because of the dispatch-before-tick order in HOOK-DELIVERY-CONTRACT. | Submit from the frame's update and not from a buffered event. This matches the current demo, which submits right before `render()`. |

## 7. Out of scope

Multi-atlas themes and per-command textures, SDF text, a layout-engine redesign, editor *authoring* of kit trees (preview only), and kit animation or transitions.
