# RFC 792: UI-kit as a game dependency, editor FrameResolver preview, and FP build-menu acceptance

**Status:** Draft (revision 2, addresses review B1–B4 and S1–S5)
**Tracking issue:** [labelle-engine#792](https://github.com/labelle-toolkit/labelle-engine/issues/792) (the remainder of #787; it also absorbs #771)
**Depends on:** labelle-gui#215 (`ui_kit` phase 2). The issue's 2026-09-08 audit says it merged on 2026-07-11.
**Related:** RFC-FONT-LOADER (#448), RFC-ASSET-STREAMING, HOOK-DELIVERY-CONTRACT (#857), `examples/uikit-gpu/` (#787 deliverable 1)

---

## 1. Problem and context

### 1.1 What the code shows today (verified in this checkout, `8221af0`)

The engine half of the UI-kit seam is already shipped:

| Surface | Where | What it does |
|---|---|---|
| `UiDrawCmd`, `UiRect`, `UiRgba8`, `UiUvRect`, `UiRenderOptions`, `UiFontStore`, `BakedUiFont`, `ResolvedUiFrame`, `convertUiDrawCommand`, `renderUiCommands` | `src/ui_draw_list.zig`, re-exported at `src/root.zig:242-257` | The engine copies the kit's `DrawCmd` structurally. `convertCommand` duck-types any union whose tags match. Unknown tags return `null`. |
| `game.submitUiDrawList(cmds, opts)` | `src/game/ui_kit_mixin.zig:61` | Keeps one frame of commands. Several submits in a frame accumulate, and the last `opts` wins. |
| `game.renderSubmittedUi()` | `ui_kit_mixin.zig:105`, called from `src/game/loop_mixin.zig:424` | Draws after the world and particle passes and before gizmos, then drains the list. |
| `game.bakeUiFont`, `game.uiFont`, `game.reuploadUiFonts` | `ui_kit_mixin.zig:195,281,…` | Bakes a TTF/OTF into a white-RGBA atlas and keeps the glyph tables. `UiFontStore.put` frees the old tables on a re-bake but **not** the old texture (`src/ui_draw_list.zig:236-258`). |
| `game.resolveUiFrame(name)` | `ui_kit_mixin.zig:312-343` | Resolves through the global `findSprite`. Computes the UV from the packed rect divided by `meta.size`. `frame_px` comes from `getWidth()`/`getHeight()`, which give the **packed** size, not `source_width/height` (`src/atlas.zig:21-43`). Returns `null` for rotated frames or when `meta.size` is missing. Trimmed frames are **not** rejected. |
| Tests | `test/ui_draw_list_test.zig` (`build.zig:364`) | Recording-renderer tests for UV mapping, text, focus ring, conversion, guards, bake, multi-submit, frame resolution, re-upload, and ordering. |

Relevant atlas and asset facts:

- `TextureManager.findSprite` (`src/atlas.zig:499-516`) returns the first match while iterating a `StringHashMap` of atlases, so the lookup order is undefined. `TextureManager.getAtlas(name)` (`:338`) gives scoped access.
- A pending atlas has `texture_id = 0` (`registerPendingAtlas`, `src/atlas.zig:369`). `isLoaded()` means `pending == null` (`:217`). The engine treats 0 as a **valid** handle (`UiRenderOptions.atlas_texture` doc, `src/ui_draw_list.zig:302-307`), so an id of 0 cannot be used as a readiness check.
- `Game.unloadAtlas` / `TextureManager.unloadAtlas` (`src/game/atlas_mixin.zig:956`, `src/atlas.zig:526-533`) remove the entry and free only the sprite map. Neither releases a GPU texture or a catalog reference.
- Texture ownership depends on how the atlas was loaded:
  - **Catalog-loaded atlases** (`registerAtlasFromMemory`, then acquire): the catalog owns the texture. `AssetCatalog.release` frees it at refcount 0 through `loader.free` (`src/assets/catalog/engine.zig:389-423`, `src/assets/loaders/image.zig:190-202`). `game.releaseAsset(name)` (`src/game/scene_mixin.zig:291-297,562`) also blanks the atlas binding (engine#821).
  - **Eager atlases** (`loadAtlasImpl`, `atlas_mixin.zig:220`): the texture comes from `renderer.loadTexture`, and only `game.unloadTexture(id)` (`atlas_mixin.zig:896-916`) frees it.
- The catalog API (`acquire`, `release`, `isReady`, `allReady`, `anyFailed`) is described in `RFC-ASSET-STREAMING.md:145-158`. Loads are asynchronous and can fail.

The real-GPU proof is `examples/uikit-gpu/`. It does by hand what no game can do through the toolkit:

1. **Module graph.** `examples/uikit-gpu/build.zig:63-67` creates `ui_kit_mod` from a `cwd_relative` path into a sibling labelle-gui checkout. The comment there says the kit "is dependency-free (redeclares the labelle-core extern glyph structs)". `build.zig.zon` uses path deps for a flat sibling checkout. This is why the example is not built in CI.
2. **Resolver glue (about 40 lines, `main.zig:103-133`).** `resolveFrame` and `resolveFont`/`metricsFromBaked` use identity `@ptrCast` over three slices plus four scalars. Both take `context = undefined` and read the file-scope `g`.
3. **Per-frame plumbing (`main.zig:257-283`).** `layout.apply`, then `render.build` (frame resolver, font resolver, `default_text_metrics`, a fixed `focused` id), then `submitUiDrawList` with a hand-filled `UiRenderOptions`.
4. **Lifecycle.** The file-scope `g`, `tree` and `body_metrics` are also used by the sokol `init`/`frame` callbacks (`main.zig:86-96,349-372`). That is not only resolver context.

Engine build facts that shape the design:

- Engine sub-packages such as `animation/` are separate packages with their own `build.zig`. They import only lower layers (`animation/build.zig:1-24`: `jsonc`, `labelle-core`) and are wired with `b.dependency("animation")` (`build.zig:123-124`). None of them imports `engine`.
- Test-only cross-repo deps are `lazy` and reached through `b.lazyDependency`, so downstream consumers never fetch them (`labelle_gfx`, `zspec`; `build.zig.zon` comments, `build.zig:722,832`).
- `std.Build.Dependency.path` exists (`/opt/zig/lib/std/Build.zig:1979`), so a consumer can point a module at a file inside a dependency's package.
- `HookContext` exposes only the bound `Game` (`src/hooks_types.zig:238-250`).
- `GamepadButton` is positional (`src/input_types.zig:153-172`). `right_face_down` is the bottom face button and `right_face_right` is the right face button. Reading `isGamepadButtonPressed` / `getGamepadAxisValue` (`src/game/input_mixin.zig:67-88`) is all the engine offers. Nothing marks input as consumed.

### 1.2 Constraints

- **C1: one atlas per submit.** A `textured_quad` carries a UV but no texture. `UiRenderOptions.atlas_*` applies to the whole submit.
- **C2: unscoped sprite lookup.** While two atlases share a sprite name, `resolveUiFrame` can resolve from either one.
- **C3: the engine module must not import labelle-gui.** This is enforced by `test/agnostic_guard_test.zig:93,112`.
- **C4: asynchronous, fallible atlas loads.** A theme cannot be assumed ready on the frame it is requested.
- **C5: texture ownership depends on the load path** (catalog vs eager, §1.1). Teardown must match the owner, or a texture is leaked or freed twice.
- **C6: no input consumption** in the engine. A menu cannot stop gameplay from seeing the same button press.

### 1.3 Not verified here (outside this checkout)

The workspace has no labelle-assembler, labelle-gui or flying-platform-labelle. Each item below is a pre-check in §6:

- whether labelle-gui `main` exports `ui_kit` (P2);
- the kit's focus API (P1);
- the assembler's opt-in convention and generated-main shape (P3);
- whether the editor depends on the engine (P4);
- FP's current build menu (P5);
- the editor `atlas.Index` semantics (P6);
- the engine ↔ labelle-gui dependency direction (P7).

## 2. Proposed design

Everything in this section is a **proposal**. None of it exists yet. Each item is tagged with the repo that would own the change.

### 2.1 [labelle-gui] Export `ui_kit` as a standalone build module

```zig
_ = b.addModule("ui_kit", .{ .root_source_file = b.path("src/ui_kit/mod.zig"), .target = target, .optimize = optimize });
```

Zig only builds modules that are reachable from a requested step, and labelle-gui's editor-only deps must be `lazy` so a consumer never fetches them (P2). **Fallback if P2 fails:** if the kit is not dependency-free, or the editor's deps cannot be made lazy, move `src/ui_kit/` into an in-repo sub-package `labelle-gui/ui_kit/` with its own `build.zig.zon` that has no dependencies, and consume it directly. The consumer-visible module name stays `"ui_kit"`.

### 2.2 [engine] `ui_kit_bridge`: source shipped in the engine package, module created by the consumer (fixes B1)

**Decision: option (a).** `ui_kit_bridge/src/root.zig` lives in the engine repo and is listed in the engine `build.zig.zon` `.paths`. It is **not** a package and has no `build.zig.zon`. Whoever builds the game creates the module with imports bound to **the game's own** `engine` and `ui_kit` module instances:

```zig
// assembler-generated build.zig (proposed)
const bridge = b.createModule(.{
    .root_source_file = engine_dep.path("ui_kit_bridge/src/root.zig"),
    .target = target, .optimize = optimize,
    .imports = &.{
        .{ .name = "engine", .module = engine_mod },   // the SAME instance the game imports
        .{ .name = "ui_kit", .module = ui_kit_mod },   // labelle_gui_dep.module("ui_kit")
    },
});
game_mod.addImport("ui_kit", ui_kit_mod);
game_mod.addImport("ui_kit_bridge", bridge);
```

The bridge sees exactly the `UiRect`, `UiRenderOptions` and `ResolvedUiFrame` types the game's `submitUiDrawList` uses, so no second engine package instance exists. The core `engine` module still does not import the kit (C3). The bridge directory sits outside `src/`, and the guard keeps covering `src/`.

**Engine-side testing of the bridge** goes behind `b.lazyDependency("labelle_gui")`, a test-only `lazy` pin as with `labelle_gfx`. Non-UI consumers fetch nothing new. `zig build test` creates the bridge module the same way the assembler does.

Why not option (b), where the engine `build.zig` exports the bridge behind a `-Dui_kit` option: the assembler would still have to unify the `ui_kit` instance and the engine's option plumbing, and nothing is gained over (a). The assembler-template alternative is covered in §3.

### 2.3 [engine] Bridge surface, ownership and lifetime (fixes S3)

```zig
// ui_kit_bridge/src/root.zig (proposed)
pub fn Bridge(comptime Game: type) type {
    return struct {
        game: *Game,
        allocator: std.mem.Allocator,
        fonts: FontMetricsCache,     // name -> ui_kit.font.FontMetrics (keyed on UiFontStore.generation)
        theme: ThemeState,           // §2.6
        nav: FocusNav,               // §2.7; owns the focused ElementId
        style: ThemeStyle,           // focus colour/thickness, default font, from the theme pack

        pub fn init(allocator, game: *Game, initial_theme: []const u8) !@This();
        pub fn deinit(self: *@This()) void;           // frees cache, releases the current theme's catalog ref
        pub fn frameResolver(self: *@This()) ui_kit.render.FrameResolver;   // scoped to the current theme atlas
        pub fn fontResolver(self: *@This()) ui_kit.render.FontResolver;
        pub fn update(self: *@This(), tree: *const ui_kit.Tree, root: ui_kit.ElementId) NavResult; // input -> focus/activate/cancel
        pub fn submit(self: *@This(), tree: *ui_kit.Tree, root: ui_kit.ElementId, viewport: engine.UiRect) !void;
        pub fn setTheme(self: *@This(), atlas_name: []const u8) !void;      // §2.6
        pub fn wantsInput(self: *const @This()) bool; // C6: true while a nav-enabled tree is active
    };
}
```

- **Ownership.** The generated main owns one `Bridge(Game)` next to its `Game`, as a file-scope value just as `g` is today. Generated code calls `init` after `Game.init` and the initial asset registration. It calls `deinit` **before** `g.deinit()`. Hooks reach the bridge through `@import("root").ui_bridge()`, an accessor the generated main emits. This uses the same root-lookup mechanism as `HookContext.game()` (#855). `HookContext` itself is unchanged. This is still a program-lifetime global. What goes away is the `context = undefined` resolver pattern: the resolvers receive `self`. The demo's lifecycle globals stay in the demo.
- **Focus** is owned by `nav`. `submit` passes `nav.focused` to `render.build`, and the caller does not pass it. A game that manages focus itself sets `nav.focused` directly.
- **Font cache.** `UiFontStore` gains a `generation: u32` that `put` bumps. This is an additive engine-core change. The cache rebuilds when the generation changes, because a re-bake frees the borrowed tables (`ui_draw_list.zig:247`).
- **Layout parity.** Comptime `@sizeOf`/`@alignOf`/`@offsetOf` assertions compare core and kit `Glyph`/`CodepointEntry`/`KernPair` before the identity `@ptrCast` (RFC-FONT-LOADER §3).

### 2.4 [assembler] Wiring

When `project.labelle` opts in (spelling per P3), the generated `build.zig`:

1. fetches labelle-gui by **url + hash pinned at or above the first release that has `addModule("ui_kit")`**;
2. builds the bridge module as in §2.2;
3. emits `ui_bridge` ownership, init/deinit and the accessor in the generated main (§2.3).

Opted-out projects generate byte-identical output.

### 2.5 [labelle-gui] Editor preview (fixes S1)

- **Tree source.** Authoring is out of scope, so the preview renders a **built-in sample tree** shipped in labelle-gui (panel, button grid, labels, one focused button) against the **project's theme atlas**. Rendering a game's own tree would need tree serialisation, which is a follow-up.
- **FrameResolver** over `atlas.Index`: the UV is the packed rect divided by the atlas logical size, and `frame_px` is the packed size. Rotated or trimmed frames return `null`, matching §2.6 rule 3 and the dims semantics checked in P6.
- **Fonts.** The editor owns its font store. If P4 shows the editor depends on the engine, it reuses `UiFontStore` and `renderUiCommands` with its own sink. If not, it reimplements the textured quad, solid rect, text pass and focus ring (`renderCommands`, `drawTextLine` and `drawFocusRing` together are about 90 lines, `src/ui_draw_list.zig:337-425`).
- **Parity** covers UVs, `frame_px`, **and glyph placement**: both implementations, given the same atlas JSON, font bytes and DrawList, must emit the same `drawTexturedQuad` sequence (src/dst rects) on a recording sink.

### 2.6 [engine + bridge] Theme pack contract and swap state machine (fixes B2, B3, B4)

**Theme pack contract.** A theme pack contains:
1. exactly one atlas (JSON + image) whose JSON includes `meta.size`;
2. a `theme` style block (asset JSON) with `focus_color`, `focus_thickness`, `default_font` (a UI font name to bake), and optional named colour tokens;
3. frames that are **unrotated and untrimmed** (`rotated == false`, `trimmed == false`). TexturePacker trims by default, so pack authors must turn trimming off.

`setTheme` checks every sprite in the atlas once it is registered. If any frame is rotated or trimmed, it rejects the pack with `error.ThemePackInvalid` and logs the first offending frame name. This prevents the silent 9-slice corruption described in B4.

**Look-change scope.** A swap changes atlas frames, the focus ring and the default font. Colours hard-coded in the kit tree only change if the kit supports style tokens (P1). Otherwise acceptance criterion A3.3 is limited to frames, focus ring and font, and the FP tree must read colours from the bridge's tokens.

**Scoped resolution (required, not optional).** Add to the engine:

```zig
pub fn resolveUiFrameIn(self: *Game, atlas_name: []const u8, sprite_name: []const u8) ?ResolvedUiFrame
```

It works through `getTextureManager().getAtlas(atlas_name)` and applies the same math as `resolveUiFrame`. It also returns `null` when the atlas is `!isLoaded()` or the frame is rotated or trimmed. `resolveUiFrame` keeps its current behaviour (no breaking change), and its doc comment gains a trimmed-frame warning. The bridge only ever calls `resolveUiFrameIn` with its current theme atlas name, so C2 no longer applies on the UI side.

**Swap state machine** (bridge, driven from `submit` each frame):

```text
Steady(current)
  setTheme(next):
    registerAtlasFromMemory(next) if needed; assets.acquire(next)  -> Loading(current, next)
Loading(current, next)            -- keep rendering `current`
  assets.anyFailed({next}):  releaseAsset(next); log; -> Steady(current); setTheme returns/flags error.ThemeLoadFailed
  assets.isReady(next) and getAtlas(next).isLoaded() and contract ok:
      flip: current := next (before this frame's render.build)   -> Releasing(old)
  setTheme(other) while Loading: releaseAsset(next) first, then start loading `other`
Releasing(old)                    -- the old list was drained by last frame's renderSubmittedUi
  teardown(old)                                                   -> Steady(current)
```

- **Gating.** `submit` fills `UiRenderOptions.atlas_texture` only from an atlas where `isLoaded()` is true. It never infers readiness from a non-zero `texture_id`. If the initial theme is not loaded yet, the submit goes out with `atlas_texture = null`, and quads are skipped rather than drawn from texture 0.
- **Why the release is safe.** `renderSubmittedUi` drains the command list after drawing (§1.1). The flip happens in `submit` before `render.build`, so no retained command refers to the old atlas when the old atlas is released. Backends that buffer GPU work across frames must defer the actual destroy themselves, which is already true for scene swaps.
- **Teardown follows texture ownership (C5).**
  - Catalog-loaded theme (the normal pack path): call `game.releaseAsset(old)`. At refcount 0 the catalog frees the GPU texture and blanks the binding (#821). The sprite map stays registered as a pending atlas. That is one map per pack, bounded by the number of packs, and swapping back re-acquires it without re-parsing. `setTheme(.., .{ .evict = true })` additionally calls `unloadAtlas(old)`.
  - Eager theme (`loadAtlas` from files): call `game.unloadTexture(old_texture_id)`, then `unloadAtlas(old)`. Calling `unloadTexture` on a catalog-owned handle would free it twice, so the bridge records which path loaded each theme.
- **Fonts.** If the new theme's `default_font` was baked by the bridge and the old one is no longer used, the bridge calls `unloadTexture` on the old `BakedUiFont.texture_id` before re-baking, because `UiFontStore.put` does not free the texture.

### 2.7 [bridge or kit] Gamepad focus navigation (fixes S2)

If P1 finds a kit focus API, the bridge maps input onto it. Otherwise `FocusNav` lives in the bridge. Either way the behaviour and the automated tests below are mandatory.

- **Bindings, by position.** *Confirm* is `right_face_down` (the bottom face button: A on Xbox layout, B on Nintendo layout). *Cancel* is `right_face_right` (the right face button). Both live in a `NavBindings` struct the game can remap. Keyboard defaults: arrows, Enter, Escape.
- **Direction input.** D-pad edges (`isGamepadButtonPressed(left_face_*)`) or the left stick with hysteresis: fire when |axis| ≥ 0.5, re-arm when |axis| < 0.3. Only the dominant axis fires. Optional auto-repeat: 400 ms first delay, then every 120 ms.
- **Metric.** For direction *d*, a candidate is any other focusable element whose rect centre *c* satisfies `dot(c − c₀, d) > 0`. Score = `along + 2 × |across|`, where *along* and *across* are the components of `c − c₀` along *d* and perpendicular to it. The lowest score wins. **Tie-break:** smaller `|across|`, then lower tree order. No candidate means focus stays put (no wrap by default). If the focused element disappears, focus goes to the first focusable element in tree order.
- **Activation.** Confirm returns `NavResult.activated(action_id)`. FP maps it to the same game events its current menu emits (P5). Cancel returns `.cancelled`, and FP closes the menu.
- **Input arbitration (C6).** `wantsInput()` is true while the menu is open. FP's gameplay input code checks it. The engine does not gain input consumption in this RFC.

## 3. Alternatives considered

| Alternative | Why not chosen |
|---|---|
| **The engine re-exports the kit's `Tree`/`render` surface** | `engine` would import labelle-gui, which breaks C3, and every game would fetch it. |
| **The bridge as an engine sub-package with its own `build.zig.zon` that depends on `engine`** (revision 1 of this RFC) | It would get a different engine package instance from the game's, so `UiRect`/`UiRenderOptions` would be nominally different types (review B1). |
| **The engine `build.zig` exports the bridge behind a `-Dui_kit` option plus `lazyDependency("labelle_gui")`** | Workable, but the assembler still has to unify the `ui_kit` instance and pass the option. Option (a) is simpler, and the lazy dep stays test-only. |
| **Assembler-generated resolver glue (~40 lines in the template, the issue's "minimal path")** | Needs no new module and no type-instance question. Not chosen because the glue would live in a template the engine CI cannot test, the layout-parity check and theme state machine would also become template code, and every assembler change would risk drift. It stays the **fallback** if option (a) hits an assembler limitation (P3). |
| **Keep the `cwd_relative` wiring and document it** | Needs a sibling checkout and cannot run in CI. This is the status quo the issue wants removed. |
| **Move `ui_kit` into its own repo** | Cleanest long-term, but a cross-repo migration. The `"ui_kit"` module name keeps this option open. |
| **Each game writes its own glue (as the demo does)** | Repeats the unchecked `@ptrCast` in every game. |
| **Per-command texture ids (multi-atlas themes)** | Changes the `DrawCmd` contract in both repos. Single-atlas themes are enough for acceptance. |
| **Unload-on-swap with the global `findSprite` and no scoped lookup** (revision 1) | Leaves a window spanning many frames, or a failed load, in which either atlas can answer (review B2). |
| **Sprite-name prefixes per theme** | A naming convention a pack author can break. |

## 4. Acceptance criteria

Each criterion is tagged with the repo or PR that closes it.

**1b: module wiring**
- [ ] **A1.1 [labelle-gui]** `ui_kit` is exported as a build module. A downstream `b.dependency("labelle_gui", …).module("ui_kit")` compiles, and a fresh `--global-cache-dir` afterwards holds **only** the labelle-gui package: no editor-only deps are fetched or compiled.
- [ ] **A1.2 [engine]** `ui_kit_bridge/src/root.zig` ships in `.paths`, provides `Bridge(Game)` (§2.3) with comptime glyph-layout checks, and is tested through a test-only lazy `labelle_gui` pin wired in `build.zig`.
- [ ] **A1.3 [engine]** `UiFontStore.generation` and `resolveUiFrameIn` land with tests. `resolveUiFrame` behaviour is unchanged.
- [ ] **A1.4 [assembler]** An opted-in project gets `ui_kit` and `ui_kit_bridge` built from the **same** engine/ui_kit instances as the game, a pinned labelle-gui hash, and generated `ui_bridge` init/deinit/accessor. Opted-out output is byte-identical.
- [ ] **A1.5 [engine]** `examples/uikit-gpu` builds from fetchable, hash-pinned deps through the bridge, with no `cwd_relative` path and no hand-written resolvers, and CI compiles it.
- [ ] **A1.6 [engine]** `agnostic_guard_test` passes, and the dependency graph for non-UI consumers is unchanged (no new non-lazy deps in `build.zig.zon`).

**2: editor preview**
- [ ] **A2.1 [labelle-gui]** The editor previews the built-in sample tree with the project's theme atlas, using `atlas.Index` as the `FrameResolver` and an editor-owned font store.
- [ ] **A2.2 [labelle-gui + engine]** On the shared fixture (atlas JSON, font, DrawList), the editor and the engine produce identical UVs, `frame_px` values and textured-quad sequences, including a glyph run.

**3: FP acceptance**
- [ ] **A3.1 [flying-platform]** The build menu is rendered from a `ui_kit.Tree` through the bridge. The old menu path is removed, and activation emits the same events the old menu emitted (event list from P5).
- [ ] **A3.2 [engine/bridge + FP]** The menu works with a gamepad alone. Automated tests pin the focus path for a fixed grid under the §2.7 metric and tie-breaks, the confirm/cancel positions, stick hysteresis, and `wantsInput()`. A manual hardware check confirms the ring follows.
- [ ] **A3.3 [engine/bridge + FP]** Swapping to a second theme pack at runtime changes frames, focus ring and font with no code change. No frame from the old atlas is drawn after the flip, and no frame is drawn from an unloaded atlas before it.
- [ ] **A3.4 [engine/bridge]** Teardown does not leak. After A→B→A swaps, `atlasCount` stays at the number of distinct packs, the released pack's catalog refcount is 0 and its resource is `null`, and each released texture handle has been unloaded exactly once on the recording backend.
- [ ] **A3.5 [engine/bridge]** A trimmed or rotated pack is rejected with `error.ThemePackInvalid`, and the current theme stays active.

## 5. Validation plan

**Existing evidence** (from the repo; not re-run for this RFC, because this is a design-only column):
- `test/ui_draw_list_test.zig` covers the engine consumer against a recording renderer.
- `examples/uikit-gpu/screenshot.png` shows all four command kinds on a real GPU.
- The code facts in §1.1 were read from source at `8221af0`.

**Proposed validation** (none of it has been run):
1. **Bridge unit tests** (engine, through the lazy `labelle_gui` pin): resolver UV and `frame_px` on a synthetic atlas; a font-cache rebuild after a re-bake (generation bump); the layout assertions compile; `submit` produces the expected `UiDrawCmd` sequence through the recording renderer.
2. **`resolveUiFrameIn` tests** (engine, `test/ui_draw_list_test.zig`): two atlases that both define `panel` resolve deterministically by atlas name; a pending atlas returns `null`; trimmed and rotated frames return `null`. A trimmed-frame fixture shows that `resolveUiFrame` still returns the packed size, which documents why the bridge does not use it.
3. **Theme swap state-machine tests** (bridge): a catalog stub where the next theme stays `.decoding` for N frames, then becomes `.ready`. Every frame before the flip has `atlas_texture` equal to the old id, and every frame after it has the new id. A variant that ends `.failed` stays on the old theme and releases the new reference. A→B→A covers the teardown assertions in A3.4 for both catalog and eager ownership, including no double `unloadTexture` for catalog handles. A trimmed pack is rejected.
4. **FocusNav tests**: scripted D-pad, stick and keyboard sequences over a fixed 3×2 grid and an irregular layout give the expected focus path, with ties, no-candidate cases and element removal. Confirm and cancel bind to the bottom and right face positions, and remapping works. Hysteresis: 0.6 fires, 0.4 does not re-fire, 0.2 re-arms.
5. **Assembler golden tests**: generated `build.zig` and main with and without the opt-in. Opt-out output must match today's byte for byte.
6. **CI compile of `examples/uikit-gpu`**, with no GPU run, plus a fresh-cache fetch listing for A1.1.
7. **Editor parity fixture**: the A2.2 recording-sink comparison runs in both the labelle-gui and engine test suites.
8. **Manual FP acceptance**: a gamepad-only playthrough on Xbox-layout and Nintendo-layout pads, plus `LABELLE_SCREENSHOT_PATH` captures before and after a theme swap, attached to the FP PR.

Run builds serially (`zig build -j1 test`).

## 6. Risks and pre-implementation checks

| # | Risk / check | Mitigation |
|---|---|---|
| P1 | The kit's focus and style-token API is unknown. | Read labelle-gui `src/ui_kit/`. Use the kit's nav if it exists, otherwise `FocusNav`. Without kit tokens, limit A3.3's look change to frames, focus ring and font (§2.6). |
| P2 | The kit may not be dependency-free, or editor deps may not be lazy. | Check before §2.1. Fallback: an in-repo `ui_kit` sub-package with no deps (§2.1). |
| P3 | The assembler's opt-in convention and generated-main shape are unknown, and it may not support `Dependency.path` modules. | Follow the existing convention. If option (a) cannot be expressed, fall back to template glue (§3). |
| P4 | Whether the editor depends on the engine decides between reusing and reimplementing the text pass. | Decide in labelle-gui. The A2.2 parity fixture protects either choice. |
| P5 | FP's current build-menu code and the events it emits are unknown here. | Inventory them before A3.1. That list becomes the A3.1 event-equivalence check. |
| P6 | The editor's `atlas.Index` trim, rotation and logical-size semantics are unknown. | Confirm before §2.5. The resolver must reject trimmed and rotated frames, as the engine does. |
| P7 | Dependency direction: if labelle-gui depends on the engine, an engine test-only pin on labelle-gui forms a package cycle. | Check labelle-gui's `build.zig.zon`. If it depends on the engine, test the bridge from a separate fixture package (for example under `examples/` or in CI) instead of the engine `build.zig`. |
| R1 | Glyph-struct layouts drift. | Comptime layout assertions (§2.3). |
| R2 | Borrowed font slices dangle after a re-bake. | Generation-keyed cache (§2.3). |
| R3 | A theme sprite name collides with a world sprite name. Scoped lookup fixes the UI side, but the global `findSprite` used for world sprites could resolve to the theme atlas. | Pack-authoring rule: theme frames use a `ui/` prefix. `setTheme` logs a debug warning when a pack name also appears in another loaded atlas. |
| R4 | Multi-atlas themes are not expressible (C1). | Documented single-atlas rule. Revisit when per-command textures exist. |
| R5 | Cross-repo ordering stalls partway. | Gates: labelle-gui release with `addModule("ui_kit")` (A1.1), then engine bridge and `resolveUiFrameIn` (A1.2–A1.3, needs that hash), then assembler pinned to both (A1.4), then FP (A3). Each step is backward compatible, and the demo keeps working through its path wiring until A1.5. |
| R6 | Latency **only when the UI is driven by engine-emitted events** (for example `engine__key_pressed`): these are drained one iteration later (HOOK-DELIVERY-CONTRACT.md:93-97). Script- or plugin-emitted events are delivered in the same iteration. | Poll input in `bridge.update` and call `submit` from the frame's update, as the demo does. |
| R7 | Backends that keep GPU work in flight across frames may still sample a released theme texture. | Same exposure as scene swaps today. The backend defers destruction. The bridge never releases before the flip frame's command list is built. |
| R8 | Gameplay still sees menu inputs (C6). | `wantsInput()` plus FP-side gating. Engine-level input consumption is out of scope. |

## 7. Out of scope

Multi-atlas themes and per-command textures, SDF text, layout-engine redesign, editor *authoring* or serialisation of kit trees (the preview uses a built-in sample tree), engine-level input consumption, and kit animation or transitions.
