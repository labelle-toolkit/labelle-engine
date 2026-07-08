//! editor_api — the engine side of labelle-studio's Play mode (Phase 3).
//!
//! The studio runs the game compiled to wasm in an iframe and drives it
//! through the plain `export fn editor_*` symbols in this file (emcc
//! `-sEXPORTED_FUNCTIONS` keeps them alive on the wasm side).
//!
//! ## Bind pattern
//!
//! Module-scope `g` / `runner` in the assembler-generated `main.zig` are
//! not visible to a sibling module, so the generated main hands them to
//! `bind(&g, &runner)` once, right after `Game.init`. `bind` is
//! comptime-generic: it instantiates a `Holder` for the concrete
//! Game/Runner types, stores the pointers in that instantiation's
//! container-level `var`s, and publishes a vtable of plain (non-generic)
//! function pointers. The `export fn`s dispatch through that vtable —
//! they carry no comptime type information themselves.
//!
//! Before `bind` runs, every export is a safe no-op: `editor_scene_digest`
//! writes `{}`, the i32-returning scene/state ops return -1, and the
//! void setters silently ignore. `editor_pause` / `editor_step` are pure
//! editor-side state and work even before `bind`.
//!
//! ## No symbols in non-preview builds
//!
//! This file is reachable from the engine root only through
//! `root.editor_api`, a lazily-analyzed `pub const`. The generated main
//! `@import`s/binds it only under the assembler's preview flag; a build
//! that never references the module never semantically analyzes this
//! file, so none of the `editor_*` exports are emitted. (Verified by
//! `nm`-ing two otherwise-identical executables — see the PR.)
//!
//! ## Generated-main touchpoints (the assembler splices exactly these)
//!
//! ```zig
//! editor_api.bind(&g, &runner);            // once, after Game init
//! if (editor_api.shouldTick()) g.tick(dt); // gate the SIM half only
//! editor_api.frame(&g);                    // AFTER the tick, BEFORE render
//! g.render();
//! ```
//!
//! `frame` re-asserts the editor camera override every frame because
//! game scripts (e.g. FP's `camera_control`) re-assert the gameplay
//! camera on every tick — the editor must win by writing last. The
//! tick → frame → render ordering is load-bearing: `frame` must run
//! after the tick (so the script's camera write is already down) but
//! BEFORE `g.render()`. If it ran after render, every unpaused frame
//! would render the script's camera — the override would land
//! post-render only to be overwritten by the next tick before the next
//! render, so studio camera control would only work while paused.
//! Call `frame` unconditionally (gated ticks included) so the override
//! also holds while paused.
//!
//! Single-threaded by design (the wasm main thread); no atomics.

const std = @import("std");
const core = @import("labelle-core");

// ── Editor-local state (functional pre-bind) ────────────────────────

var editor_paused: bool = false;
var pending_steps: u32 = 0;
/// Whether the CURRENT frame consumed an `editor_step` (i.e. `g.tick` ran for
/// it while paused). Set by `shouldTick`, read by `frame` to SKIP the
/// apply-while-paused re-seed on a stepped frame — otherwise single-step
/// debugging would clobber the just-ticked camera with the authored seed
/// before render (finding #2). One shouldTick→frame pair per loop iteration.
var stepped_this_frame: bool = false;

pub const CameraOverride = struct { x: f32, y: f32, zoom: f32 };
var camera_override: ?CameraOverride = null;

// ── Type-erased dispatch ────────────────────────────────────────────

const VTable = struct {
    set_scene: *const fn (name: []const u8) i32,
    load_scene: *const fn (name: []const u8, src: []const u8) i32,
    set_state: *const fn (name: []const u8) i32,
    load_animation_def: *const fn (name: []const u8, src: []const u8) i32,
    reload_prefab: *const fn (name: []const u8, src: []const u8) i32,
    set_entity_position: *const fn (id: u64, x: f32, y: f32) void,
    set_component: *const fn (id: u64, name: []const u8, json: []const u8) i32,
    scene_digest: *const fn (out: []u8) usize,
    apply_camera: *const fn (x: f32, y: f32, zoom: f32) void,
};

var vtable: ?*const VTable = null;

// ── Generated-main API (non-export) ─────────────────────────────────

/// Store the concrete Game (and Runner) behind the type-erased vtable.
/// Called once by the generated main, after `Game.init` (and scene
/// registration). `g` must be a stable `*Game` pointer; `runner` is
/// stored for future ops (v1 doesn't dispatch through it) and may be
/// any value, typically `*ScriptRunner(...)`.
pub fn bind(g: anytype, runner: anytype) void {
    const GP = @TypeOf(g);
    comptime {
        const info = @typeInfo(GP);
        if (info != .pointer or @typeInfo(info.pointer.child) != .@"struct")
            @compileError("editor_api.bind expects a *Game pointer, got " ++ @typeName(GP));
    }
    const H = Holder(GP, @TypeOf(runner));
    H.game = g;
    H.runner = runner;
    vtable = &H.vtable_impl;
}

/// Drop the bound game and reset all editor state (pause, pending
/// steps, camera override). Exports revert to their pre-bind no-op
/// behavior. Call before the Game is deinitialized if the module
/// outlives it; tests use it to isolate the module-level state.
pub fn unbind() void {
    vtable = null;
    editor_paused = false;
    pending_steps = 0;
    stepped_this_frame = false;
    camera_override = null;
}

/// Gate for the SIM half of the generated main's frame loop.
/// Unpaused: always true. Paused: consumes one pending `editor_step`
/// count per call and returns true for it; false otherwise (render
/// continues either way — only `g.tick` is gated on this).
pub fn shouldTick() bool {
    if (!editor_paused) {
        stepped_this_frame = false;
        return true;
    }
    if (pending_steps > 0) {
        pending_steps -= 1;
        stepped_this_frame = true; // this frame ticks — frame() must not re-seed
        return true;
    }
    stepped_this_frame = false;
    return false;
}

/// Per-frame editor pass, called by the generated main AFTER the sim
/// tick (and its camera-writing scripts) and BEFORE `g.render()`.
/// Two jobs, in precedence order:
///
///   1. **Apply-while-paused** (camera-prefabs #714): while the sim is
///      PAUSED and no look-around override is engaged, re-seed the gfx
///      camera from the authored `Camera` component every frame, so
///      inspector/gizmo edits show live. Safe precisely because the sim
///      is paused — no gameplay camera script is ticking to fight it. On
///      resume the script drives and this stops asserting. SKIPPED on a
///      STEPPED frame (one this `shouldTick` advanced): `g.tick` just ran
///      and may have moved the camera, so single-step debugging must render
///      that ticked frame, not the re-seeded authored camera (finding #2).
///   2. **Look-around override**: re-asserts the editor camera while the
///      override is engaged so the frame about to be rendered uses it.
///      Applied LAST so it wins over both the component and the script.
///
/// A no-op when neither is active, and a comptime no-op for games whose
/// renderer has no camera (or no `Camera` seed path).
pub fn frame(g: anytype) void {
    if (editor_paused and camera_override == null and !stepped_this_frame) applyCameraComponentTo(g);
    if (camera_override) |c| applyCameraTo(g, c);
}

/// Current editor pause state (what `editor_scene_digest` reports).
pub fn isPaused() bool {
    return editor_paused;
}

/// The engaged camera override, if any. Introspection for tests/tools.
pub fn cameraOverride() ?CameraOverride {
    return camera_override;
}

// ── Exports (plain, non-generic; dispatch through the vtable) ───────

/// Allocate `len` bytes the host can write into (scene names/sources)
/// or read from. Uses the C allocator — on emscripten-wasm this IS
/// `malloc`, so the JS side can pair it with the module's heap views.
pub export fn editor_alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    const mem = std.heap.c_allocator.alloc(u8, len) catch return null;
    return mem.ptr;
}

/// Free a buffer obtained from `editor_alloc`. `len` must match.
pub export fn editor_free(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    std.heap.c_allocator.free(ptr[0..len]);
}

/// 1 = freeze the simulation (rendering continues), 0 = resume.
/// Resuming discards any unconsumed `editor_step` counts.
pub export fn editor_pause(paused: i32) void {
    editor_paused = paused != 0;
    if (!editor_paused) pending_steps = 0;
}

/// While paused: advance N sim ticks (consumed one per frame by
/// `shouldTick`). Ignored when not paused.
pub export fn editor_step(frames: u32) void {
    if (!editor_paused) return;
    pending_steps +|= frames;
}

/// Switch to scene `name`. 0 = ok (including a swap deferred on the
/// asset gate — a retry is queued), nonzero = unknown scene / error /
/// not bound.
pub export fn editor_set_scene(name: [*]const u8, len: usize) i32 {
    const vt = vtable orelse return -1;
    return vt.set_scene(name[0..len]);
}

/// Store `src` as the runtime source override for scene `name` (the
/// override map is consulted before the embedded/compiled source on
/// every subsequent load). If `name` is the current scene, it is
/// reloaded immediately — transactionally: when the new source fails
/// to load, the override map is rolled back to its previous state and
/// the scene is reloaded from the last-good source, so a malformed
/// edit never blanks the preview. 0 = ok.
pub export fn editor_load_scene(name: [*]const u8, nlen: usize, src: [*]const u8, slen: usize) i32 {
    const vt = vtable orelse return -1;
    return vt.load_scene(name[0..nlen], src[0..slen]);
}

/// Switch the game STATE machine to `name` (v1.1) — the axis
/// `editor_set_scene` does not touch: scenes swap entities, states gate
/// which scripts tick (e.g. FP's sky director / production / needs run
/// only in "playing"). Without this, Play mode edits a scene whose
/// state-gated systems are all frozen in "menu".
///
/// States are user-defined free-form strings (see `state_mixin.zig`);
/// the engine has NO state registry to validate against — an unknown
/// name is simply a state no script listens to, and it is trivially
/// recoverable by another `editor_set_state` (unlike a scene typo,
/// nothing is torn down). Only the empty name is rejected. The name is
/// copied into game-owned memory (`setStateOwned`), so the caller may
/// free the buffer immediately. 0 = ok; -1 = empty name / OOM / not
/// bound.
pub export fn editor_set_state(name: [*]const u8, len: usize) i32 {
    const vt = vtable orelse return -1;
    return vt.set_state(name[0..len]);
}

/// Push a `.zon` animation-def SOURCE into the running game (contract
/// v1.2, labelle-studio issue #24 — the animation analog of
/// `editor_load_scene`). `name` is the def's stem (`"worker"` for
/// `animations/worker.zon`); `src` is the full ZON source. On success
/// the def is parsed (`RuntimeAnimationDef.load`), installed as the
/// runtime override consulted by `Game.runtimeAnimDef`, and every live
/// component that opted in via `anim_def_name` is `refreshState`-ed
/// (stale speed/frame-count copies re-read, indices clamped, `dirty`
/// set) — see `game/animation_runtime_mixin.zig`.
///
/// Returns 0 = ok; -1 = not bound / empty name; -2 = parse/validation
/// failure; -3 = out of memory. On ANY nonzero return the running game
/// is untouched — the previous override (or the comptime table) stays
/// live, so a half-saved file never corrupts the preview. The buffers
/// are copied; the caller may free them right after the call.
pub export fn editor_load_animation_def(name: [*]const u8, nlen: usize, src: [*]const u8, slen: usize) i32 {
    const vt = vtable orelse return -1;
    return vt.load_animation_def(name[0..nlen], src[0..slen]);
}

/// Push a prefab JSONC SOURCE into the running game (contract v1.4,
/// labelle-studio issue #24 — the prefab half). `name` is the prefab's
/// registry name (`"condenser"` for `prefabs/condenser.jsonc`,
/// `"<pack>__<stem>"` for pack prefabs); `src` is the full JSONC
/// source. On success the source is parsed, shape-checked, and
/// installed in the prefab registry under its effective name
/// (replace-or-insert — see `PrefabCache.replaceFromSource`), so every
/// FUTURE spawn resolves the new definition: runtime `spawnPrefab`
/// calls, scene loads referencing the prefab (including an
/// `editor_load_scene` reload of the current scene, which re-spawns its
/// placed instances from the new data), and save/load Phase 1
/// re-spawns.
///
/// v1.4 (engine#691): already-spawned instances additionally get the
/// prefab's `.transient`-policy components re-applied in place — the
/// exact set save/load already rebuilds from prefab data on every
/// load. Runtime-attached transients, `.saveable` state, entity
/// identity, `Position`/`Sprite`/`Shape`, and structural child edits
/// stay untouched; see `jsonc/scene_loader/prefab_refresh.zig` for the
/// scope contract. The change is visible on the next TICKED frame
/// (under `editor_pause` that is the next `editor_step`/resume — same
/// latency as `editor_load_animation_def`). The replaced definition's
/// memory is retired, never freed, so components still borrowing
/// slices from it stay valid even while the sim is paused.
///
/// Returns 0 = ok; -1 = not bound / empty name; -2 = parse/shape
/// failure (unparseable, non-object top level, RFC #560 §B2 violation);
/// -3 = out of memory. On ANY nonzero return the registry is untouched
/// — the previous definition stays live, so a half-saved file never
/// corrupts the preview. The rc values are unchanged from v1.3 — a
/// v1.3-era studio keeps working, it just under-promises. The buffers
/// are copied; the caller may free them right after the call.
pub export fn editor_reload_prefab(name: [*]const u8, nlen: usize, src: [*]const u8, slen: usize) i32 {
    const vt = vtable orelse return -1;
    return vt.reload_prefab(name[0..nlen], src[0..slen]);
}

/// Move entity `id` to world coordinates (x, y). Marks the position
/// dirty so the render pipeline re-syncs. Unknown/positionless ids are
/// ignored.
pub export fn editor_set_entity_position(id: u64, x: f32, y: f32) void {
    const vt = vtable orelse return;
    vt.set_entity_position(id, x, y);
}

/// Set component `name` on entity `id` from a JSON object — the general
/// per-component edit seam (editor-bridge contract **v1.5**, camera-prefabs
/// #714). `editor_set_entity_position` stays the drag hot-path; this is the
/// general path the inspector grows into.
///
/// **Allowlisted** (MVP): only the vetted `"Camera"` built-in is accepted — a
/// `{"zoom":…}` (and, when authored, `"viewport":{…}`) object. Any other name
/// returns -1; there is deliberately no blanket apply-any-component path.
///
/// **Merge/patch semantics**: only the keys PRESENT in the JSON overwrite the
/// entity's existing `Camera` — a `{"zoom":…}` patch preserves a prior
/// `viewport`. A default `Camera` is materialized when the entity has none. On
/// success the live `getCamera()` is re-seeded so a paused preview updates
/// immediately.
///
/// Returns 0 = ok; -1 = not bound / unknown id / unknown-or-unvetted
/// component; -2 = parse/validation failure (entity untouched — the parse runs
/// before any mutation). The buffers are copied; the caller may free them
/// right after the call. Optional on older builds like v1.1–v1.4: a studio
/// that finds no `editor_set_component` degrades to today's behavior.
pub export fn editor_set_component(
    id: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    json_ptr: [*]const u8,
    json_len: usize,
) i32 {
    const vt = vtable orelse return -1;
    return vt.set_component(id, name_ptr[0..name_len], json_ptr[0..json_len]);
}

/// v1: always -1 — the studio picks client-side from the scene digest.
pub export fn editor_pick(x: f32, y: f32) i64 {
    _ = x;
    _ = y;
    return -1;
}

/// Write a JSON digest of the current scene into `out` (capacity
/// `cap`) and return the number of bytes written. Shape:
/// `{"scene":"...","state":"...","paused":0|1,"entity_count":N,
///   "entities":[{"id":<u64>,"prefab":"?","sprite":"?","tilemap":"?",
///     "camera":{"zoom":f,"viewport"?:{x,y,width,height},
///               "view":{x,y,width,height}},"x":f,"y":f},...]}`
/// `prefab`/`sprite`/`tilemap`/`camera` appear only when the entity
/// carries them; a Camera entity's `viewport` is present only when
/// authored, while `view` is the derived WORLD-space visible rect
/// (`getCamera().getViewport()`) the studio draws its gizmo from. `x`/`y`
/// are WORLD coordinates (the same space `editor_set_entity_position`
/// consumes).
/// The entity list is
/// truncated to fit `cap` while `entity_count` keeps the full count —
/// the output is always valid JSON (worst case `{}`; 0 bytes only when
/// `cap < 2`).
pub export fn editor_scene_digest(out: [*]u8, cap: usize) usize {
    const vt = vtable orelse return writeEmptyObject(out, cap);
    return vt.scene_digest(out[0..cap]);
}

/// Engage the editor camera override: applied immediately and
/// re-asserted after every sim tick (via `frame`) until released.
pub export fn editor_set_camera(x: f32, y: f32, zoom: f32) void {
    camera_override = .{ .x = x, .y = y, .zoom = zoom };
    if (vtable) |vt| vt.apply_camera(x, y, zoom);
}

/// Release the camera override. The gameplay camera is NOT restored
/// explicitly — camera-driving scripts re-assert it on their next tick.
pub export fn editor_release_camera() void {
    camera_override = null;
}

// ── Implementation ──────────────────────────────────────────────────

fn writeEmptyObject(out: [*]u8, cap: usize) usize {
    if (cap < 2) return 0;
    out[0] = '{';
    out[1] = '}';
    return 2;
}

/// True when `G` (a Game type) exposes a settable camera. `Game`
/// publishes `CameraType = void` for camera-less renderers (StubRender),
/// which folds the whole override path away at comptime.
fn gameHasCamera(comptime G: type) bool {
    if (!@hasDecl(G, "CameraType")) return false;
    if (G.CameraType == void) return false;
    return @hasDecl(G.CameraType, "setPosition") and @hasDecl(G.CameraType, "setZoom");
}

fn applyCameraTo(g: anytype, c: CameraOverride) void {
    const G = @typeInfo(@TypeOf(g)).pointer.child;
    if (comptime !gameHasCamera(G)) return;
    const cam = g.getCamera();
    cam.setPosition(c.x, c.y);
    cam.setZoom(c.zoom);
}

/// The apply-while-paused pass (camera-prefabs #714): re-seed the gfx camera
/// from the authored `Camera` component. Dispatches to the engine's
/// `seedCameraFromComponent`, which is itself comptime-gated on the renderer
/// having a settable camera. The extra `@hasDecl` gate here lets the minimal
/// camera stand-ins used by the override tests (`CameraGame`, which duck-types
/// only `getCamera`) still compile — they carry no `Camera` seed path.
fn applyCameraComponentTo(g: anytype) void {
    const G = @typeInfo(@TypeOf(g)).pointer.child;
    if (comptime !@hasDecl(G, "seedCameraFromComponent")) return;
    g.seedCameraFromComponent();
}

/// One instantiation per concrete (Game-pointer, Runner) pair. The
/// container-level `var`s give the plain vtable fns a place to find
/// the typed pointers without any runtime type erasure gymnastics.
fn Holder(comptime GP: type, comptime RP: type) type {
    return struct {
        const G = @typeInfo(GP).pointer.child;

        var game: GP = undefined;
        var runner: RP = undefined;

        const vtable_impl = VTable{
            .set_scene = &setSceneImpl,
            .load_scene = &loadSceneImpl,
            .set_state = &setStateImpl,
            .load_animation_def = &loadAnimationDefImpl,
            .reload_prefab = &reloadPrefabImpl,
            .set_entity_position = &setEntityPositionImpl,
            .set_component = &setComponentImpl,
            .scene_digest = &sceneDigestImpl,
            .apply_camera = &applyCameraImpl,
        };

        fn setSceneImpl(name: []const u8) i32 {
            // Validate BEFORE calling setScene: the engine tears the
            // current scene down before it discovers an unknown target
            // (SceneNotFound leaves no scene loaded). A typo'd editor
            // request must not nuke the running scene.
            if (game.scenes.get(name) == null and game.jsonc_scenes.get(name) == null)
                return -1;
            game.setScene(name) catch return -1;
            // `setScene` DEFERS (returns without swapping, leaving
            // `pending_scene_assets` set) while the target's asset
            // manifest is still loading. Queue the change so the game
            // loop's retrier (loop_mixin) commits it once the assets
            // are ready — mirrors the pending-scene commit detection
            // from #635.
            if (game.pending_scene_assets != null) game.queueSceneChange(name);
            return 0;
        }

        fn setStateImpl(name: []const u8) i32 {
            // No pre-validation registry exists for states (unlike
            // scenes): they're free-form strings scripts gate on, so
            // every non-empty name is "valid" by construction and a
            // typo is recoverable in place. Reject only the empty name
            // — never a meaningful state, most likely a host-side
            // length bug.
            if (name.len == 0) return -1;
            // The name lives in a studio-owned wasm buffer that is
            // freed right after this call, while `setState` stores its
            // argument by reference — `setStateOwned` copies onto the
            // game allocator (see state_mixin.zig for the UAF-ordering
            // history it encodes).
            game.setStateOwned(name) catch return -1;
            return 0;
        }

        fn loadSceneImpl(name: []const u8, src: []const u8) i32 {
            const is_current = if (game.getCurrentSceneName()) |cur|
                std.mem.eql(u8, cur, name)
            else
                false;

            if (!is_current) {
                // Not the running scene: just store; the override is
                // picked up on the next load of `name`.
                game.setSceneSourceOverride(name, src) catch return -1;
                return 0;
            }

            // Reloading the RUNNING scene must be transactional: the
            // engine unloads the current scene before the loader can
            // fail, so a malformed/partially-typed source would blank
            // the preview AND leave the bad override installed (a later
            // corrected editor_load_scene would no longer auto-reload —
            // there'd be no current scene to match). Snapshot the
            // previous override (exact-key, ownership stays with the
            // map — we copy), install the new source, and on reload
            // failure roll the map back and reload the last-good source.
            const prev: ?[]const u8 = if (game.scene_source_overrides.get(name)) |old|
                (game.allocator.dupe(u8, old) catch return -1)
            else
                null;
            defer if (prev) |p| game.allocator.free(p);

            game.setSceneSourceOverride(name, src) catch return -1;
            if (setSceneImpl(name) == 0) return 0;

            // Bad source — restore the previous override state…
            if (prev) |p| {
                game.setSceneSourceOverride(name, p) catch {};
            } else {
                game.removeSceneSourceOverride(name);
            }
            // …and reload the scene from the last-good source so the
            // preview doesn't stay blank. If even that fails we're no
            // worse off than before this rollback existed.
            _ = setSceneImpl(name);
            return -1;
        }

        fn loadAnimationDefImpl(name: []const u8, src: []const u8) i32 {
            // Empty name: never meaningful, most likely a host-side
            // length bug (mirrors setStateImpl).
            if (name.len == 0) return -1;
            // `loadAnimationDefSource` is transactional by construction:
            // parse failures error out BEFORE the registry or any live
            // component is touched, so unlike loadSceneImpl there is no
            // rollback dance here.
            game.loadAnimationDefSource(name, src) catch |err| {
                return if (err == error.OutOfMemory) -3 else -2;
            };
            return 0;
        }

        fn reloadPrefabImpl(name: []const u8, src: []const u8) i32 {
            // Empty name: never meaningful, most likely a host-side
            // length bug (mirrors setStateImpl / loadAnimationDefImpl).
            if (name.len == 0) return -1;
            // `reloadPrefabSource` is transactional by construction:
            // parse/shape failures error out BEFORE the registry is
            // touched, so there is no rollback dance here either.
            game.reloadPrefabSource(name, src) catch |err| {
                return if (err == error.OutOfMemory) -3 else -2;
            };
            return 0;
        }

        fn setEntityPositionImpl(id: u64, x: f32, y: f32) void {
            const Entity = G.EntityType;
            if (comptime @typeInfo(Entity) != .int) return;
            const ent = std.math.cast(Entity, id) orelse return;
            // Positionless ids (stale/dead entities included) are
            // ignored — the editor only drags positioned entities.
            if (!game.hasComponent(ent, core.Position)) return;
            // World coords; converts to local for parented entities and
            // marks the position dirty for the render pipeline.
            game.setWorldPosition(ent, .{ .x = x, .y = y });
        }

        fn setComponentImpl(id: u64, name: []const u8, json: []const u8) i32 {
            // Allowlist (FLAG B): only the vetted "Camera" built-in in the
            // MVP. An unknown/unvetted name is refused up front — no blanket
            // apply-any-component path is wired.
            if (!std.mem.eql(u8, name, "Camera")) return -1;
            // Defer to a project that registered its OWN `Camera` (finding #1):
            // the built-in bridge is off for such projects — refuse rather than
            // materialize a conflicting second component. Routing "Camera" to
            // the registry path is a later, studio-side change.
            if (comptime !G.camera_is_builtin) return -1;
            const Entity = G.EntityType;
            if (comptime @typeInfo(Entity) != .int) return -1;
            const ent = std.math.cast(Entity, id) orelse return -1;
            // Unknown/dead id → -1 (distinct from a parse failure, which is
            // -2). The entity need NOT already carry a `Camera` — the first
            // edit materializes one.
            if (!game.ecs_backend.entityExists(ent)) return -1;
            // MERGE the JSON patch into the entity's `Camera` and re-seed
            // getCamera(). The parse happens before any mutation, so a
            // parse/validation failure (-2) leaves the entity untouched.
            game.applyCameraComponentJson(ent, json) catch return -2;
            return 0;
        }

        fn applyCameraImpl(x: f32, y: f32, zoom: f32) void {
            applyCameraTo(game, .{ .x = x, .y = y, .zoom = zoom });
        }

        fn sceneDigestImpl(out: []u8) usize {
            if (out.len < 2) return 0;
            return renderDigest(out) catch writeEmptyObject(out.ptr, out.len);
        }

        const NoSpace = error{NoSpace};

        fn renderDigest(out: []u8) NoSpace!usize {
            // Reserve the closing `]}` up front so entity truncation
            // can never eat the bytes that keep the JSON valid.
            const body = out[0 .. out.len - 2];
            var cur: usize = 0;

            var count: usize = 0;
            {
                var v = game.ecs_backend.view(.{core.Position}, .{});
                defer v.deinit();
                while (v.next()) |_| count += 1;
            }

            try appendLit(body, &cur, "{\"scene\":");
            try appendJsonString(body, &cur, game.getCurrentSceneName() orelse "");
            try appendLit(body, &cur, ",\"state\":");
            try appendJsonString(body, &cur, game.getState());
            try appendFmt(body, &cur, ",\"paused\":{d},\"entity_count\":{d},\"entities\":[", .{
                @intFromBool(editor_paused), count,
            });

            var first = true;
            var v = game.ecs_backend.view(.{core.Position}, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                const mark = cur;
                writeEntityJson(body, &cur, ent, first) catch {
                    // Doesn't fit — roll back this entity (and its
                    // leading comma) and stop; the closing `]}` below
                    // keeps the truncated list valid JSON.
                    cur = mark;
                    break;
                };
                first = false;
            }

            out[cur] = ']';
            out[cur + 1] = '}';
            return cur + 2;
        }

        fn writeEntityJson(buf: []u8, cur: *usize, ent: G.EntityType, first: bool) NoSpace!void {
            if (!first) try appendLit(buf, cur, ",");
            try appendFmt(buf, cur, "{{\"id\":{d}", .{entityId(ent)});
            if (comptime @hasDecl(G, "PrefabInstanceComp")) {
                if (game.getComponent(ent, G.PrefabInstanceComp)) |pi| {
                    try appendLit(buf, cur, ",\"prefab\":");
                    try appendJsonString(buf, cur, pi.path);
                }
            }
            if (comptime @hasDecl(G, "SpriteComp") and @hasField(G.SpriteComp, "sprite_name")) {
                if (game.getComponent(ent, G.SpriteComp)) |sp| {
                    try appendLit(buf, cur, ",\"sprite\":");
                    try appendJsonString(buf, cur, sp.sprite_name);
                }
            }
            // Tilemap presence (T2 Phase 2) — publishes the referenced
            // `.tmx` asset name; no per-tile data (tilemaps are immutable).
            if (comptime @hasDecl(G, "TilemapComp") and @hasField(G.TilemapComp, "asset_name")) {
                if (game.getComponent(ent, G.TilemapComp)) |tm| {
                    try appendLit(buf, cur, ",\"tilemap\":");
                    try appendJsonString(buf, cur, tm.asset_name);
                }
            }
            // Camera (camera-prefabs MVP, #714) — the authored `zoom` and
            // (when set) `viewport` so the studio round-trips them, plus the
            // derived WORLD-space visible rect `view` from
            // `getCamera().getViewport()` — the rect the studio draws its
            // draggable gizmo from. Emitted only for Camera-bearing entities,
            // exactly like the sprite/tilemap optional-field pattern above.
            // Suppressed when a project registered its own `Camera` (finding
            // #1): the built-in feature defers, so its component is never
            // injected/published here.
            if (comptime @hasDecl(G, "CameraComp") and G.camera_is_builtin) {
                if (game.getComponent(ent, G.CameraComp)) |cam| {
                    try appendFmt(buf, cur, ",\"camera\":{{\"zoom\":{d}", .{jsonSafeFloat(cam.zoom)});
                    if (cam.viewport) |vp| {
                        try appendFmt(buf, cur, ",\"viewport\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
                            vp.x, vp.y, vp.width, vp.height,
                        });
                    }
                    // The derived world view-rect — only for renderers whose
                    // camera reports one (`getViewport`). Nested comptime block
                    // (not an `and`) so `getViewport` is never reflected on a
                    // `void` camera — mirrors tilemap_mixin's `camera_cullable`.
                    const emit_view = comptime blk: {
                        if (!gameHasCamera(G)) break :blk false;
                        break :blk @hasDecl(G.CameraType, "getViewport");
                    };
                    if (emit_view) {
                        const vr = game.getCamera().getViewport();
                        try appendFmt(buf, cur, ",\"view\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
                            jsonSafeFloat(vr.x), jsonSafeFloat(vr.y), jsonSafeFloat(vr.width), jsonSafeFloat(vr.height),
                        });
                    }
                    try appendLit(buf, cur, "}");
                }
            }
            // WORLD coordinates, not the raw (parent-relative) Position
            // component — `editor_set_entity_position` consumes world
            // coords, so the digest must publish the same space or the
            // studio would draw/drag nested prefab children at their
            // local offsets and write them back wrong.
            const wp = game.getWorldPosition(ent);
            try appendFmt(buf, cur, ",\"x\":{d},\"y\":{d}}}", .{
                jsonSafeFloat(wp.x), jsonSafeFloat(wp.y),
            });
        }

        fn entityId(ent: G.EntityType) u64 {
            const info = @typeInfo(G.EntityType);
            if (comptime info == .int and info.int.signedness == .unsigned and info.int.bits <= 64) {
                return @intCast(ent);
            }
            return 0;
        }
    };
}

/// NaN/Inf would render as `nan`/`inf` — invalid JSON. Clamp to 0.
fn jsonSafeFloat(v: f32) f32 {
    return if (std.math.isFinite(v)) v else 0;
}

fn appendLit(buf: []u8, cur: *usize, lit: []const u8) error{NoSpace}!void {
    if (buf.len - cur.* < lit.len) return error.NoSpace;
    @memcpy(buf[cur.*..][0..lit.len], lit);
    cur.* += lit.len;
}

fn appendFmt(buf: []u8, cur: *usize, comptime fmt: []const u8, args: anytype) error{NoSpace}!void {
    const written = std.fmt.bufPrint(buf[cur.*..], fmt, args) catch return error.NoSpace;
    cur.* += written.len;
}

fn appendJsonString(buf: []u8, cur: *usize, s: []const u8) error{NoSpace}!void {
    try appendLit(buf, cur, "\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try appendLit(buf, cur, "\\\""),
            '\\' => try appendLit(buf, cur, "\\\\"),
            '\n' => try appendLit(buf, cur, "\\n"),
            '\r' => try appendLit(buf, cur, "\\r"),
            '\t' => try appendLit(buf, cur, "\\t"),
            else => {
                if (ch < 0x20) {
                    try appendFmt(buf, cur, "\\u{x:0>4}", .{ch});
                } else {
                    if (cur.* >= buf.len) return error.NoSpace;
                    buf[cur.*] = ch;
                    cur.* += 1;
                }
            },
        }
    }
    try appendLit(buf, cur, "\"");
}
