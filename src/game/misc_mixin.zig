/// Misc mixin — small leaf accessors and forwarders that don't belong to
/// a larger cohesive cluster: design-coord conversion, embedded-scene /
/// JSONC scene registration, hot-reload request, screen height, camera
/// accessors, and the renderer / ECS / entity-count getters.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. The camera
/// gate (`has_camera`) and the `getCamera`/`getCameraManager` `pub const`
/// shells stay on `Game` — they fold to `void` on cameraless renderers —
/// and forward here for the impl bodies.
const std = @import("std");
const core = @import("labelle-core");
const frame_profiler_mod = @import("../frame_profiler.zig");
const profiler = @import("scene").profiler;

/// A pair of screen dimensions in one explicit coordinate space.
///
/// Returned by `Game.framebufferSize` (physical / backend-native pixels)
/// and `Game.designSize` (the logical canvas the game draws into). Both
/// are optional at the call site: a renderer that doesn't distinguish the
/// two spaces reports `null` rather than a plausible-looking lie.
pub const ScreenSize = struct {
    width: f32,
    height: f32,
};

/// Returns the misc-accessors mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const RenderImpl = @typeInfo(@FieldType(Game, "renderer")).pointer.child;
    const EcsImpl = Game.EcsBackend;
    const CameraType = Game.CameraType;
    const CameraManagerType = Game.CameraManagerType;

    return struct {
        /// Convert a physical-pixel screen coordinate (raw touch / mouse
        /// event coords from the backend) to a design-pixel coordinate
        /// inside the pillarboxed/letterboxed canvas. Use this before
        /// feeding touch / mouse coords to `cam.screenToWorld` so the
        /// math lines up with the game's design coordinate system.
        ///
        /// Backends without a design/physical distinction (raylib) get
        /// a passthrough — the input is returned unchanged.
        pub fn screenToDesign(self: *Game, px: f32, py: f32) RenderImpl.ScreenPoint {
            return self.renderer.screenToDesign(px, py);
        }

        /// The project's logical Y-axis convention as a runtime value
        /// (mirrors the comptime `Game.y_axis`). See RFC §3.
        pub fn yAxis(_: *const Game) core.YAxis {
            return Game.y_axis;
        }

        /// Convert a physical-pixel screen coordinate into the project's
        /// **logical** space (the `Position` space). Maps through the raw
        /// `screenToDesign` first, then applies `Game.y_axis` to the Y
        /// component via core's canonical `screenToLogicalY`. For `.down`
        /// this is the identity (== `screenToDesign`); for `.up` it flips Y
        /// (`height - design_y`). See RFC §3 (Q1→(b), Q3).
        pub fn screenToLogical(self: *Game, px: f32, py: f32) RenderImpl.ScreenPoint {
            var p = self.renderer.screenToDesign(px, py);
            p.y = core.screenToLogicalY(Game.y_axis, p.y, renderScreenHeight(self));
            return p;
        }

        /// The cursor position in **design** pixels — the space
        /// `screenToDesign` maps into, i.e. the canvas the game draws
        /// into before the backend's aspect-fit and HiDPI scale.
        ///
        /// `getMouseX`/`getMouseY` report the backend's OWN space, which
        /// is *not* the same across backends: bgfx / wgpu / sokol deliver
        /// physical framebuffer pixels (2x the window on a Retina
        /// display), while raylib / SDL deliver logical window points.
        /// This accessor is the portable one — it runs the backend's own
        /// `screenToDesign` (a no-op passthrough on backends with no
        /// design/physical distinction), so it lands on the same pixel a
        /// sprite was drawn at on every backend and every DPI.
        ///
        /// Prefer this (or `getMouseLogical`) over raw `getMouseX/Y` for
        /// any hit-testing (labelle-engine#852).
        pub fn getMouseDesign(self: *Game) RenderImpl.ScreenPoint {
            return screenToDesign(self, Game.Input.getMouseX(), Game.Input.getMouseY());
        }

        /// The cursor position in the project's **logical** space — the
        /// same space as `Position` / `setPosition`, with `Game.y_axis`
        /// applied. This is what axis-aware picking, drag-selection and
        /// clickable HUD widgets want: compare it directly against an
        /// entity's `Position`.
        ///
        /// Under `.down` this is identical to `getMouseDesign`; under
        /// `.up` the Y is flipped (`height - design_y`).
        pub fn getMouseLogical(self: *Game) RenderImpl.ScreenPoint {
            return screenToLogical(self, Game.Input.getMouseX(), Game.Input.getMouseY());
        }

        /// Inverse of `screenToDesign`: a design-pixel coordinate back to
        /// the backend's physical screen space (the space `getMouseX/Y`
        /// and touch events arrive in).
        ///
        /// Forwards to the renderer's `designToPhysical` when the backend
        /// provides one (bgfx / sokol / wgpu); backends without a
        /// design/physical distinction get a passthrough, matching
        /// `screenToDesign`'s own fallback so the two stay exact inverses.
        pub fn designToScreen(self: *Game, dx: f32, dy: f32) RenderImpl.ScreenPoint {
            if (comptime @hasDecl(RenderImpl, "designToPhysical")) {
                const p = self.renderer.designToPhysical(dx, dy);
                return .{ .x = p.x, .y = p.y };
            }
            return .{ .x = dx, .y = dy };
        }

        /// Inverse of `screenToLogical`: a coordinate in the project's
        /// logical (`Position`) space back to physical screen pixels.
        /// Un-applies `Game.y_axis` first, then `designToScreen`.
        pub fn logicalToScreen(self: *Game, lx: f32, ly: f32) RenderImpl.ScreenPoint {
            const design_y = core.toScreenY(Game.y_axis, ly, renderScreenHeight(self));
            return designToScreen(self, lx, design_y);
        }

        /// The **physical** framebuffer size in backend-native pixels —
        /// what the backend reported via `setScreenSize`. On a HiDPI /
        /// Retina display this is a multiple of `designSize`.
        ///
        /// `null` when the renderer doesn't report it (a backend with no
        /// design/physical distinction, or a stub/mock renderer). Callers
        /// that only need to map coordinates between the two spaces should
        /// use `screenToDesign` / `designToScreen` instead of deriving a
        /// ratio from these — those handle letterboxing too, which a bare
        /// ratio does not.
        pub fn framebufferSize(self: *Game) ?ScreenSize {
            if (comptime @hasDecl(RenderImpl, "framebufferSize")) {
                const s = self.renderer.framebufferSize();
                return .{ .width = s.width, .height = s.height };
            }
            return null;
        }

        /// The **design** (logical) canvas size — the project's declared
        /// `.width` / `.height`, the space sprite `Position`s and
        /// `drawGizmoRectScreen` are expressed in.
        ///
        /// `null` when the renderer doesn't report it. See
        /// `framebufferSize` for the physical counterpart.
        pub fn designSize(self: *Game) ?ScreenSize {
            if (comptime @hasDecl(RenderImpl, "designSize")) {
                const s = self.renderer.designSize();
                return .{ .width = s.width, .height = s.height };
            }
            return null;
        }

        /// The screen height the renderer flips against. The renderer owns
        /// the authoritative value (set via `setScreenHeight`); we read its
        /// `screen_height` field when present.
        ///
        /// Under `.up`, the flip (`height - y`) genuinely needs the height,
        /// so a renderer without a `screen_height` field is a build error
        /// rather than a silent `0` that would yield negative logical Y.
        /// Under `.down` the height is unused (identity), so a `0` fallback
        /// is harmless — this is the path the engine-test `StubRender`
        /// (no `screen_height` field) takes.
        fn renderScreenHeight(self: *Game) f32 {
            if (comptime @hasField(RenderImpl, "screen_height")) {
                return self.renderer.screen_height;
            }
            if (comptime Game.y_axis == .up) {
                @compileError("Renderer " ++ @typeName(RenderImpl) ++
                    " must expose a 'screen_height' field to be used with Game.y_axis == .up" ++
                    " (the y-up flip `height - y` needs it).");
            }
            return 0;
        }

        /// Register an embedded JSONC scene source so `"include"`
        /// directives can resolve against memory instead of disk.
        /// Mirrors `addEmbeddedPrefab` — the assembler emits one call
        /// per scene fragment in `main()` / `init()` so WASM and
        /// Android builds (no project directory in cwd) can still
        /// resolve nested scene includes. `path` is the include-
        /// relative path (e.g. `"scenes/obstacles.jsonc"`); `source`
        /// is typically a comptime `@embedFile(...)` slice. Caller
        /// retains no ownership — the map dupes the key and borrows
        /// the source's program-lifetime slice.
        pub fn addEmbeddedSceneSource(self: *Game, path: []const u8, source: []const u8) !void {
            const gop = try self.embedded_scene_sources.getOrPut(path);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, path);
            }
            gop.value_ptr.* = source;
        }

        /// Store (or replace) a runtime scene-source override
        /// (labelle-studio Play mode / `editor_api.editor_load_scene`).
        /// `name` is the scene name (e.g. `"main"`). Both key and value
        /// are copied with `self.allocator`; replacing an existing entry
        /// frees the previous source. The JSONC loader consults this map
        /// before the embedded/compiled source on every subsequent load
        /// — see `sceneSourceOverride` for the lookup rules.
        pub fn setSceneSourceOverride(self: *Game, name: []const u8, source: []const u8) !void {
            const value = try self.allocator.dupe(u8, source);
            errdefer self.allocator.free(value);
            const gop = try self.scene_source_overrides.getOrPut(name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            } else {
                gop.key_ptr.* = self.allocator.dupe(u8, name) catch |err| {
                    // Undo the half-inserted entry (its key is still the
                    // caller's transient slice) before propagating.
                    self.scene_source_overrides.removeByPtr(gop.key_ptr);
                    return err;
                };
            }
            gop.value_ptr.* = value;
        }

        /// Remove a scene-source override previously stored under `name`
        /// (exact key only — no stem fallback), freeing both the owned
        /// key and source copies. No-op when absent. Used by
        /// `editor_api`'s transactional current-scene reload to roll a
        /// freshly-installed bad override back out.
        pub fn removeSceneSourceOverride(self: *Game, name: []const u8) void {
            if (self.scene_source_overrides.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }

        /// Resolve a scene-source override for `key`, which may be either
        /// a scene name (`"main"`, the `loadSceneFromSource` path) or an
        /// include-relative path (`"scenes/frag.jsonc"`, the
        /// `loadSceneFile` path). Exact key match first; otherwise the
        /// path's stem (basename minus extension) is tried, so an
        /// override stored under the scene name also replaces the
        /// same-named include fragment. Returns a borrow of the stored
        /// source — valid until the entry is replaced or the game
        /// deinitializes.
        pub fn sceneSourceOverride(self: *const Game, key: []const u8) ?[]const u8 {
            if (self.scene_source_overrides.count() == 0) return null;
            if (self.scene_source_overrides.get(key)) |src| return src;
            const base = std.fs.path.basename(key);
            const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
            if (stem.len == 0 or std.mem.eql(u8, stem, key)) return null;
            return self.scene_source_overrides.get(stem);
        }

        /// Register a runtime JSONC scene by name.
        /// The scene file is loaded from disk when setScene() is called.
        pub fn registerJsoncScene(self: *Game, name: []const u8, scene_path: []const u8, prefab_dir: []const u8) void {
            self.jsonc_scenes.put(name, .{
                .scene_path = scene_path,
                .prefab_dir = prefab_dir,
            }) catch {};
        }

        /// Signal that the current scene should be reloaded on the next tick.
        pub fn requestReload(self: *Game) void {
            self.hot_reload_dirty = true;
        }

        /// Set the screen height on the active world's renderer.
        pub fn setScreenHeight(self: *Game, height: f32) void {
            self.renderer.setScreenHeight(height);
        }

        pub fn getCameraImpl(self: *Game) *CameraType {
            return self.renderer.getCamera();
        }

        pub fn getCameraManagerImpl(self: *Game) *CameraManagerType {
            return self.renderer.getCameraManager();
        }

        /// The lowest ACTIVE camera slot carrying `tag`, or `null` if none
        /// (camera-bound layers, labelle-engine#723/#724). `"main"` resolves to
        /// slot 0 once a `Camera` component has seeded it; a secondary tag
        /// resolves to whichever slot 1–3 the seed bound it to. Forwards to the
        /// gfx camera manager's `findByTag`.
        pub fn getCameraByTagImpl(self: *Game, tag: []const u8) ?*CameraType {
            return self.renderer.getCameraManager().findByTag(tag);
        }

        // ── Accessors ─────────────────────────────────────────────

        pub fn getRenderer(self: *Game) *RenderImpl {
            return self.renderer;
        }

        pub fn getEcsBackend(self: *Game) *EcsImpl {
            return self.ecs_backend;
        }

        pub fn entityCount(self: *Game) usize {
            return @intCast(self.ecs_backend.entityCount());
        }

        // ── Debug inspector: FPS + profiler overlay (#380) ───────────

        /// Smoothed frames-per-second for the inspector header. Always
        /// available (the frame profiler is ungated).
        pub fn fps(self: *const Game) f32 {
            return self.frame_profiler.fps();
        }

        /// Smoothed frame time in milliseconds.
        pub fn frameTimeMs(self: *const Game) f32 {
            return self.frame_profiler.frameTimeMs();
        }

        /// Min/avg/max frame-time window stats (+ derived FPS) for the
        /// inspector's frame-time section.
        pub fn frameStats(self: *const Game) frame_profiler_mod.FrameProfiler.Stats {
            return self.frame_profiler.stats();
        }

        /// Copy the recent frame-time history (ms, oldest-first) into
        /// `dst` for the inspector's mini-graph. Returns the filled
        /// prefix; a short `dst` keeps the newest frames.
        pub fn frameHistory(self: *const Game, dst: []f32) []f32 {
            return self.frame_profiler.history(dst);
        }

        /// Force per-script / per-plugin capture on (`true`), off
        /// (`false`), or defer to the `LABELLE_PROFILE` env gate
        /// (`null`). The debug inspector passes `true` while its
        /// Performance section is open and `null` when it closes, so an
        /// env-enabled headless dump keeps running regardless of panel
        /// state. Zero-cost when off: the dispatch loops still branch on
        /// one cached bool per frame.
        pub fn setProfilingCapture(self: *const Game, on: ?bool) void {
            _ = self;
            profiler.setRecording(on);
        }

        /// Whether per-unit capture is currently active (override or
        /// `LABELLE_PROFILE`). The inspector uses this to label stale
        /// rows when capture is off.
        pub fn profilingCaptureActive(self: *const Game) bool {
            _ = self;
            return profiler.recording();
        }

        /// The live per-script profile rows (`tick` + `drawGui` timings),
        /// or an empty slice when the generated `main` hasn't wired the
        /// pointer (unit-test games, or a build without scripts). The Game
        /// stores this as `*const anyopaque`; the row layout is the shared
        /// `profiler.ScriptRow`, so the cast is stable.
        pub fn scriptProfileRows(self: *const Game) []const profiler.ScriptRow {
            const ptr = self.script_profile_ptr orelse return &.{};
            if (self.script_profile_count == 0) return &.{};
            const many: [*]const profiler.ScriptRow = @ptrCast(@alignCast(ptr));
            return many[0..self.script_profile_count];
        }

        /// The live per-plugin profile rows (`tick` + `postTick` timings),
        /// or an empty slice when unwired. See `scriptProfileRows`.
        pub fn pluginProfileRows(self: *const Game) []const profiler.PluginRow {
            const ptr = self.plugin_profile_ptr orelse return &.{};
            if (self.plugin_profile_count == 0) return &.{};
            const many: [*]const profiler.PluginRow = @ptrCast(@alignCast(ptr));
            return many[0..self.plugin_profile_count];
        }
    };
}
