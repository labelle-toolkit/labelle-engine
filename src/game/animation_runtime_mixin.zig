/// Animation-runtime mixin — runtime `AnimationDef` overrides on a live
/// game (labelle-engine#672 driver seam, labelle-studio Play mode).
///
/// The comptime `AnimationDef` path bakes clip tables into the binary;
/// this mixin lets a host push a re-parsed `.zon` def into the RUNNING
/// game and have live animation components pick the new numbers up. It is
/// the engine half of the studio's `_editor_load_animation_def` hot-push
/// (`editor_api.zig` dispatches here); a desktop host loop watching file
/// mtimes (`ReloadWatcher`) can call the same `loadAnimationDefSource`.
///
/// ## How live entities are found — the `anim_def_name` convention
///
/// The engine can't know which game component mirrors which def (the
/// binding is a comptime `@import` in game code). A game component opts
/// in by declaring the def it was generated from:
///
/// ```zig
/// pub const AnimationState = struct {
///     pub const anim_def_name = "worker"; // animations/worker.zon
///     clip: Clip = .idle,   // u8 or enum — both refresh
///     ...
/// };
/// ```
///
/// On every successful `loadAnimationDefSource("worker", src)`, all
/// registered components whose `anim_def_name` matches are walked and
/// `refreshState`-ed (stale `frame_count`/`speed`/`mode` copies re-read,
/// out-of-range `clip`/`variant`/`frame` clamped, `dirty` set). Declaring
/// `anim_def_name` opts the component into `refreshState`'s duck-type
/// contract (`.clip/.variant/.frame/.frame_count/.speed/.mode/.dirty`).
/// Components without the decl are never touched, and a game with no
/// opted-in components compiles this walk away entirely.
///
/// ## What the game must still do itself
///
/// The refresh updates STATE; sprite-name resolution and transition
/// metadata still come from wherever the game reads them. For reloaded
/// numbers to survive the next `transition`, game code consults
/// `runtimeAnimDef(name)` (falling back to its comptime table) — the
/// `AnimDefSource` seam. Games that don't are still refreshed in place,
/// but revert to comptime numbers on their next clip switch.
const std = @import("std");
const animation_def_runtime = @import("../animation_def_runtime.zig");

/// Returns the animation-runtime mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        pub fn nextAnimationIdentity(self: *Game) u64 {
            self.animation_identity = std.math.add(u64, self.animation_identity, 1) catch
                @panic("animation identity exhausted");
            return self.animation_identity;
        }

        /// Recheck at delivery and in gameplay handlers before touching the
        /// target. A rebind preserves target identity but changes playback id.
        pub fn isAnimationMarkerTargetAlive(self: *Game, event: anytype) bool {
            if (comptime !Game.ComponentRegistry.has("SpriteAnimation")) return false;
            const entity = std.math.cast(Game.EntityType, event.entity) orelse return false;
            if (!self.ecs_backend.entityExists(entity)) return false;
            const anim = self.ecs_backend.getComponent(entity, @import("../sprite_animation.zig").SpriteAnimation) orelse return false;
            return event.target_id != 0 and anim.marker_target_id == event.target_id;
        }
        /// Register a shared JSONC definition before loading scenes/prefabs.
        /// The game owns both strings and frame tables until deinit.
        pub fn loadAnimationJsoncSource(self: *Game, name: []const u8, source: []const u8) !void {
            self.animation_library.load(name, source) catch |err| {
                self.log.err("animation '{s}': {s}", .{ name, @errorName(err) });
                return err;
            };
        }

        /// Bind a freshly deserialized component. Inline definitions retain
        /// their existing behavior. This does not require resident atlases.
        pub fn bindSpriteAnimation(self: *Game, anim: *@import("../sprite_animation.zig").SpriteAnimation) !void {
            // Replacing an unfinished cursor would erase a crossing whose
            // enqueue failed. Drain it first; the supported select API below
            // checks before changing the old clip or its borrowed frame table.
            if (anim.markers.len != 0 and anim.marker_cursor.pending()) return error.PendingAnimationMarkers;
            if (anim.definition.len == 0) {
                if (anim.markers.len != 0) return error.MarkerDefinitionRequired;
                if (anim.clip.len != 0) return error.AnimationDefinitionRequired;
                if (anim.frames.len == 0 or anim.frames.len > 255) return error.InvalidAnimationFrames;
                return;
            }
            if (anim.frames.len != 0) return error.AmbiguousAnimationFrames;
            const def = self.animation_library.get(anim.definition) orelse return error.UnknownAnimationDefinition;
            const clip = def.find(anim.clip) orelse return error.UnknownAnimationClip;
            // Queued marker strings must survive prefab arenas and rebinds.
            anim.definition = self.animation_library.definitions.getEntry(anim.definition).?.key_ptr.*;
            anim.clip = clip.name;
            anim.frames = clip.frames;
            anim.markers = clip.markers;
            anim.marker_cursor = .{};
            if (anim.marker_target_id == 0) anim.marker_target_id = self.nextAnimationIdentity();
            anim.marker_playback_id = self.nextAnimationIdentity();
            anim.marker_stalled = false;
            anim.frame = 0;
            anim.timer = 0;
            anim.forward = true;
            anim.finished_emitted = false;
            anim.repetition = 0;
            anim.definition_dirty = true;
            anim.definition_validated = false;
        }

        /// Select/restart a shared clip atomically. A retained crossing applies
        /// backpressure to replacement too; on error the old player is intact.
        pub fn selectSpriteAnimation(self: *Game, anim: *@import("../sprite_animation.zig").SpriteAnimation, definition: []const u8, clip: []const u8) !void {
            var next = anim.*;
            next.definition = definition;
            next.clip = clip;
            next.frames = &.{};
            try self.bindSpriteAnimation(&next);
            anim.* = next;
        }

        /// Call only after the clip's atlases are resident. The automatic
        /// atlas resolver does this after the current scene's manifest gate.
        pub fn validateSpriteAnimation(self: *Game, anim: *const @import("../sprite_animation.zig").SpriteAnimation) !void {
            for (anim.frames, 0..) |key, index| {
                if (!hasResidentFrame(self, key)) {
                    self.log.err("animation '{s}', clip '{s}', frame {d}: atlas key '{s}' not found", .{ anim.definition, anim.clip, index, key });
                    return error.MissingAnimationFrame;
                }
            }
        }

        fn sceneManifest(self: *Game) ?[]const []const u8 {
            const name = self.current_scene_name orelse return null;
            const entry = self.scenes.get(name) orelse return null;
            return if (entry.assets.len == 0) null else entry.assets;
        }

        fn hasResidentFrame(self: *Game, key: []const u8) bool {
            if (sceneManifest(self)) |manifest| {
                for (manifest) |name| {
                    const atlas = self.atlas_manager.getAtlas(name) orelse continue;
                    if (atlas.isLoaded() and atlas.has(key)) return true;
                }
            } else {
                // Imperative loading: the caller chooses when to validate,
                // but pending metadata never counts as a resident frame.
                var it = self.atlas_manager.atlases.valueIterator();
                while (it.next()) |atlas| {
                    if (atlas.isLoaded() and atlas.has(key)) return true;
                }
            }
            return false;
        }

        /// Validate only when a real scene manifest has become resident.
        /// Without one, the imperative caller owns the readiness boundary.
        pub fn validateSceneSpriteAnimations(self: *Game) void {
            const manifest = sceneManifest(self) orelse return;
            if (!self.assets.allReady(manifest)) return;
            const Animation = @import("../sprite_animation.zig").SpriteAnimation;
            if (comptime Game.ComponentRegistry.has("SpriteAnimation") and Game.ComponentRegistry.getType("SpriteAnimation") == Animation) {
                var view = self.ecs_backend.view(.{Animation}, .{});
                defer view.deinit();
                while (view.next()) |entity| {
                    const anim = self.ecs_backend.getComponent(entity, Animation).?;
                    if (anim.definition.len == 0 or anim.definition_validated) continue;
                    self.validateSpriteAnimation(anim) catch {
                        anim.speed = 0;
                    };
                    anim.definition_validated = true;
                }
            }
        }

        /// Parse a `.zon` animation-def source and install it as the
        /// runtime override for `name` (the def's stem, `"worker"` for
        /// `animations/worker.zon`), then refresh every live component
        /// that declares `anim_def_name == name`. On a parse/validation
        /// error NOTHING changes — the previous override (or the
        /// comptime table) stays live, so a half-saved file never
        /// corrupts a running preview. `name` and `source` are copied;
        /// the caller may free both immediately.
        pub fn loadAnimationDefSource(self: *Game, name: []const u8, source: []const u8) !void {
            var def = try animation_def_runtime.RuntimeAnimationDef.load(self.allocator, source);
            errdefer def.deinit();
            try self.runtime_anim_defs.put(name, def);
            refreshAnimationStates(self, name);
        }

        /// The live runtime override for `name`, or null when nothing
        /// was pushed. Game code resolving sprite names / transition
        /// metadata should prefer this over its comptime table when
        /// present (the `AnimDefSource` seam). The borrow stays valid
        /// until `deinit` — see `RuntimeAnimDefs`' graveyard note.
        pub fn runtimeAnimDef(self: *const Game, name: []const u8) ?*const animation_def_runtime.RuntimeAnimationDef {
            return self.runtime_anim_defs.get(name);
        }

        /// Re-sync every live component whose `anim_def_name` decl
        /// matches `name` against the current runtime override (no-op
        /// when none is installed). Called by `loadAnimationDefSource`;
        /// public so hosts with their own reload plumbing can re-run it.
        pub fn refreshAnimationStates(self: *Game, name: []const u8) void {
            const def = self.runtime_anim_defs.get(name) orelse return;
            const Registry = Game.ComponentRegistry;
            if (comptime !@hasDecl(Registry, "names")) return;
            inline for (comptime Registry.names()) |cname| {
                const C = Registry.getType(cname);
                if (comptime animDefNameOf(C)) |def_name| {
                    if (std.mem.eql(u8, def_name, name)) {
                        var view = self.ecs_backend.view(.{C}, .{});
                        defer view.deinit();
                        while (view.next()) |entity| {
                            if (self.ecs_backend.getComponent(entity, C)) |state| {
                                animation_def_runtime.refreshState(state, def);
                            }
                        }
                    }
                }
            }
        }

        /// The def name a component opted into via `pub const
        /// anim_def_name`, or null (= never refreshed).
        fn animDefNameOf(comptime C: type) ?[]const u8 {
            if (@typeInfo(C) != .@"struct") return null;
            if (!@hasDecl(C, "anim_def_name")) return null;
            return C.anim_def_name;
        }
    };
}
