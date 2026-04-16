/// Scene mixin — scene registration, loading, transitions, and lifecycle.
const std = @import("std");

/// Returns the scene management mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        pub fn registerScene(
            self: *Game,
            comptime name: []const u8,
            comptime loader_fn: fn (*Game) anyerror!void,
            hooks_val: Game.SceneHooks,
        ) void {
            const wrapper = struct {
                fn load(game: *Game) anyerror!void {
                    return loader_fn(game);
                }
            }.load;
            self.scenes.put(name, .{
                .loader_fn = wrapper,
                .hooks = hooks_val,
            }) catch {};
        }

        pub fn registerSceneSimple(
            self: *Game,
            comptime name: []const u8,
            comptime loader_fn: fn (*Game) anyerror!void,
        ) void {
            self.registerScene(name, loader_fn, .{});
        }

        /// Register a scene together with its declared asset manifest.
        /// Manifest-aware overload emitted by the assembler for scenes with
        /// an `"assets": [...]` block. Delegates to `registerSceneSimple`
        /// so any future change to scene-entry construction only lives in
        /// one place, then attaches the slice via `getPtr`.
        ///
        /// Lifetime: `assets` is stored by reference on the `SceneEntry`
        /// and must outlive the `Game`. The assembler passes a file-scope
        /// slice from `SceneAssetManifests.entries` in the generated
        /// `main.zig`, which is program-lifetime. Runtime callers passing
        /// a stack-allocated slice would leave `SceneEntry.assets`
        /// dangling — prefer an allocator-owned or static slice.
        pub fn registerSceneWithAssets(
            self: *Game,
            comptime name: []const u8,
            comptime loader_fn: fn (*Game) anyerror!void,
            assets: []const []const u8,
        ) void {
            self.registerSceneSimple(name, loader_fn);
            if (self.scenes.getPtr(name)) |entry| {
                entry.assets = assets;
            }
        }

        /// Attach an asset manifest to a previously-registered scene.
        /// Returns `error.SceneNotFound` if `name` was never registered.
        /// Used by the assembler to thread `SceneAssetManifests.entries` into
        /// `SceneEntry.assets` after the normal `registerSceneSimple` loop
        /// (keeps the codegen diff to a single extra inline-for in the
        /// generated `main.zig`). Scripts can then read
        /// `game.scenes.get("main").?.assets` at runtime.
        ///
        /// Lifetime: `assets` is stored by reference and must outlive the
        /// `Game`. See `registerSceneWithAssets` for the usual caller
        /// pattern (file-scope slice from `SceneAssetManifests.entries`).
        pub fn setSceneAssets(
            self: *Game,
            name: []const u8,
            assets: []const []const u8,
        ) error{SceneNotFound}!void {
            const entry = self.scenes.getPtr(name) orelse return error.SceneNotFound;
            entry.assets = assets;
        }

        pub fn setScene(self: *Game, name: []const u8) !void {
            self.unloadCurrentScene();

            if (self.current_scene_name) |old_name| {
                self.allocator.free(old_name);
                self.current_scene_name = null;
            }

            self.emitHook(.{ .scene_before_load = .{ .name = name, .allocator = self.allocator } });

            if (self.scenes.get(name)) |entry| {
                // Comptime-registered scene
                try entry.loader_fn(self);
                self.current_scene_name = self.allocator.dupe(u8, name) catch null;
                self.emitHook(.{ .scene_load = .{ .name = name } });
                if (entry.hooks.onLoad) |onLoad| {
                    onLoad(self);
                }
            } else if (self.jsonc_scenes.get(name)) |_| {
                // Runtime JSONC scene — loaded at runtime by the game loop
                // The actual loading is deferred: the generated code or game code
                // handles parsing the JSONC file and creating entities.
                self.current_scene_name = self.allocator.dupe(u8, name) catch null;
                self.emitHook(.{ .scene_load = .{ .name = name } });
            } else {
                return error.SceneNotFound;
            }
        }

        /// Load a scene using resetEcsBackend for atomic world reset.
        /// Avoids per-entity teardown and zig-ecs destruction signal issues (#388).
        /// Clears the scene entity list first so Scene.deinit skips entity destruction,
        /// then resets the ECS atomically, then loads the new scene.
        pub fn setSceneAtomic(self: *Game, name: []const u8) !void {
            const entry = self.scenes.get(name) orelse return error.SceneNotFound;

            // Clear scene entity list BEFORE deinit so Scene.deinit's entity
            // destruction loop has nothing to iterate (entities will be destroyed
            // atomically by resetEcsBackend instead).
            self.clearActiveSceneEntities();

            // Unload old scene (runs script deinit, fires hooks, frees scene struct)
            self.unloadCurrentScene();

            if (self.current_scene_name) |old_name| {
                self.allocator.free(old_name);
                self.current_scene_name = null;
            }

            // Atomic reset — destroys all entities and visuals without iteration
            self.resetEcsBackend();

            // Load the new scene into the fresh ECS
            self.emitHook(.{ .scene_before_load = .{ .name = name, .allocator = self.allocator } });
            try entry.loader_fn(self);
            self.current_scene_name = self.allocator.dupe(u8, name) catch null;
            self.emitHook(.{ .scene_load = .{ .name = name } });

            if (entry.hooks.onLoad) |onLoad| {
                onLoad(self);
            }
        }

        pub fn queueSceneChange(self: *Game, name: []const u8) void {
            if (self.pending_scene_change) |old| {
                self.allocator.free(old);
            }
            self.pending_scene_change = self.allocator.dupe(u8, name) catch null;
            self.pending_scene_atomic = false;
        }

        /// Queue an atomic scene change for the next frame.
        /// Uses resetEcsBackend to avoid per-entity teardown.
        pub fn queueSceneChangeAtomic(self: *Game, name: []const u8) void {
            if (self.pending_scene_change) |old| {
                self.allocator.free(old);
            }
            self.pending_scene_change = self.allocator.dupe(u8, name) catch null;
            self.pending_scene_atomic = true;
        }

        pub fn getCurrentSceneName(self: *const Game) ?[]const u8 {
            return self.current_scene_name;
        }

        pub fn setActiveScene(
            self: *Game,
            ptr: *anyopaque,
            update_fn: *const fn (*anyopaque, f32) void,
            deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
            get_entity_fn: ?*const fn (*anyopaque, []const u8) ?Game.EntityType,
            add_entity_fn: ?*const fn (*anyopaque, Game.EntityType) void,
            clear_entities_fn: ?*const fn (*anyopaque) void,
        ) void {
            self.teardownActiveScene();
            self.active_scene_ptr = ptr;
            self.active_scene_update_fn = update_fn;
            self.active_scene_deinit_fn = deinit_fn;
            self.active_scene_get_entity_fn = get_entity_fn;
            self.active_scene_add_entity_fn = add_entity_fn;
            self.active_scene_clear_entities_fn = clear_entities_fn;
        }
    };
}
