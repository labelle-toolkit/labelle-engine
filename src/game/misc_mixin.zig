/// Misc mixin — small leaf accessors and forwarders that don't belong to
/// a larger cohesive cluster: design-coord conversion, embedded-scene /
/// JSONC scene registration, hot-reload request, screen height, camera
/// accessors, and the renderer / ECS / entity-count getters.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. The camera
/// gate (`has_camera`) and the `getCamera`/`getCameraManager` `pub const`
/// shells stay on `Game` — they fold to `void` on cameraless renderers —
/// and forward here for the impl bodies.

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
    };
}
