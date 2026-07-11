//! Camera mixin (camera-prefabs MVP, labelle-engine#714) — the `Game`-side
//! seed / sync lifecycle for the built-in `Camera` component (`src/camera.zig`).
//!
//! Two entry points, both comptime-folded to nothing on camera-less renderers:
//!   - `seedCameraFromComponent` — find the (first) Camera entity, read its
//!     WORLD position + `zoom`, and apply them to `getCamera()`. Called once
//!     after scene instantiation (seed-on-load) and again every PAUSED frame
//!     from `editor_api.frame` (apply-while-paused). It is the same operation
//!     both times: the component reaches the live gfx camera, never the other
//!     way around.
//!   - `applyCameraComponentJson` — MERGE a JSON patch into an entity's Camera
//!     component (creating a default one when absent), then re-seed. Backs the
//!     `editor_set_component("Camera", …)` bridge export.

const std = @import("std");
const core = @import("labelle-core");
const jsonc = @import("jsonc");
const camera_mod = @import("../camera.zig");

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const CameraComp = Game.CameraComp;
    const Position = core.Position;
    // The generated render-layer enum (or `void` on layer-less renderers). Its
    // configs' `.camera` values, plus `"main"`, form the comptime tag
    // vocabulary a seed can warn against. See `tagVocabularyCheckable`.
    const LayerEnum = Game.RenderLayerEnum;

    return struct {
        // Latching warn-once flags (camera-bound layers). Seeding runs on every
        // PAUSED frame (apply-while-paused), so each diagnostic is emitted at
        // most once per process rather than every frame. Struct-scope statics:
        // one instantiation per concrete `Game`.
        var warned_unknown_tag = false;
        var warned_extra_main = false;
        var warned_extra_tag = false;
        var warned_overflow = false;

        /// Seed the gfx cameras from the authored `Camera` components
        /// (camera-bound layers, labelle-engine#723/#724). Reset-then-seed:
        ///
        ///   1. `resetSecondary()` deactivates + untags slots 1–3 so a
        ///      removed/renamed secondary camera never leaves a live bound
        ///      slot. Slot 0 (`"main"`) is untouched.
        ///   2. Iterate EVERY entity carrying `Position` + `Camera`, reading
        ///      its WORLD position (`getWorldPosition`, matching the digest and
        ///      `editor_set_entity_position`) plus `Camera.zoom`:
        ///        * tag `"main"` → configure slot 0 via `getCamera()` (the
        ///          existing single-camera behavior) and tag it `"main"`. First
        ///          `"main"` wins; extras warn once.
        ///        * any other tag → claim the next free secondary slot (1–3)
        ///          via the camera manager. First camera per tag wins; extras
        ///          and slot overflow past 3 warn once and are ignored.
        ///
        /// Zero Camera entities → nothing is seeded and slot 0's default camera
        /// is left exactly as-is (the invariant: a scene with no Camera renders
        /// as it did before this feature). A comptime no-op that never touches
        /// the (possibly `void`) camera seam on camera-less renderers, and off
        /// entirely for a project that registered its own `Camera` (finding #1).
        ///
        /// The multi-slot tagged path requires the gfx ≥1.26 TAGGED manager
        /// (`hasTaggedCameraManager`). A renderer with a settable camera but an
        /// OLD, non-tagged manager falls back to the pre-PR single-camera seed
        /// (first `{Position,Camera}` → `getCamera()`, no reset, no tags) so it
        /// still compiles and behaves exactly as before.
        pub fn seedCameraFromComponent(self: *Game) void {
            if (comptime !camera_mod.hasSettableCamera(Game)) return;
            if (comptime !Game.camera_is_builtin) return;

            if (comptime !camera_mod.hasTaggedCameraManager(Game)) {
                // Pre-PR fallback: seed the first Camera entity onto the single
                // renderer camera. No manager reset / tags — the non-tagged
                // manager type declares none of those methods, so this branch
                // must never reference them.
                var v = self.ecs_backend.view(.{ Position, CameraComp }, .{});
                defer v.deinit();
                while (v.next()) |ent| {
                    const cam = self.ecs_backend.getComponent(ent, CameraComp) orelse continue;
                    const wp = self.getWorldPosition(ent);
                    const camera = self.getCamera();
                    camera.setPosition(wp.x, wp.y);
                    camera.setZoom(cam.zoom);
                    seedCameraViewport(camera, cam.viewport);
                    return;
                }
                return;
            }

            const mgr = self.getCameraManager();
            // Clear stale secondary bindings before re-seeding (slot 0 kept).
            mgr.resetSecondary();

            var seen_main = false;
            // First-per-tag bookkeeping for the ≤ 3 secondary slots. Inline
            // fixed buffers — never heap (mirrors the tag-storage rule).
            var claimed_buf: [3][camera_mod.tag_capacity]u8 = undefined;
            var claimed_len: [3]usize = .{ 0, 0, 0 };
            var claimed_count: usize = 0;
            var next_slot: usize = 1; // slots 1..3; > 3 == exhausted

            var v = self.ecs_backend.view(.{ Position, CameraComp }, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                const cam = self.ecs_backend.getComponent(ent, CameraComp) orelse continue;
                const wp = self.getWorldPosition(ent);
                const tag = cam.tagSlice();

                // Warn once on a tag no layer binds (comptime vocabulary).
                if (comptime tagVocabularyCheckable()) {
                    if (!tagInVocabulary(tag)) {
                        warnOnce(self, &warned_unknown_tag, "camera tag '{s}' is bound by no layer", .{tag});
                    }
                }

                if (std.mem.eql(u8, tag, "main")) {
                    if (seen_main) {
                        warnOnce(self, &warned_extra_main, "multiple 'main' camera entities; keeping the first", .{});
                        continue;
                    }
                    seen_main = true;
                    // Seed slot 0 EXPLICITLY (not via `getCamera()`, which may
                    // return the *selected* camera): the main transform and the
                    // `"main"` tag must both land on slot 0.
                    const camera = mgr.getCamera(0);
                    camera.setPosition(wp.x, wp.y);
                    camera.setZoom(cam.zoom);
                    seedCameraViewport(camera, cam.viewport);
                    mgr.setTag(0, "main");
                    continue;
                }

                // Secondary tag — first camera per tag wins.
                var dup = false;
                for (0..claimed_count) |i| {
                    if (std.mem.eql(u8, claimed_buf[i][0..claimed_len[i]], tag)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) {
                    warnOnce(self, &warned_extra_tag, "multiple camera entities tagged '{s}'; keeping the first", .{tag});
                    continue;
                }

                if (next_slot > 3) {
                    warnOnce(self, &warned_overflow, "more than 3 secondary cameras; tag '{s}' ignored", .{tag});
                    continue;
                }

                const slot: u2 = @intCast(next_slot);
                mgr.setActive(slot, true);
                mgr.setTag(slot, tag);
                const scam = mgr.getCamera(slot);
                scam.setPosition(wp.x, wp.y);
                scam.setZoom(cam.zoom);
                seedCameraViewport(scam, cam.viewport);

                if (claimed_count < 3) {
                    const n = @min(tag.len, camera_mod.tag_capacity);
                    @memcpy(claimed_buf[claimed_count][0..n], tag[0..n]);
                    claimed_len[claimed_count] = n;
                    claimed_count += 1;
                }
                next_slot += 1;
            }
        }

        /// Seed a live renderer camera's screen-space viewport from the
        /// authored `Camera.viewport` (camera-bound layers Phase 2, #761).
        /// This is what carries a per-camera split-screen / minimap / PiP
        /// rect from scene authoring through to the renderer, whose
        /// per-camera `applyViewport` then calls the backend's `setViewport`.
        /// A `null` authored viewport clears any prior binding (fullscreen).
        ///
        /// Comptime-folds to nothing on a renderer whose camera type has no
        /// `screen_viewport` field (stub / older gfx) — the authored value is
        /// simply inert there, exactly as it was before this wiring. The
        /// engine `Camera.Viewport` and the gfx camera's `ScreenViewport`
        /// share the `{ x, y, width, height }` shape, so the anonymous struct
        /// literal coerces to whatever the camera field's type is.
        fn seedCameraViewport(camera: anytype, viewport: ?camera_mod.Viewport) void {
            if (comptime !@hasField(@typeInfo(@TypeOf(camera)).pointer.child, "screen_viewport")) return;
            if (viewport) |vp| {
                camera.screen_viewport = .{ .x = vp.x, .y = vp.y, .width = vp.width, .height = vp.height };
            } else {
                camera.screen_viewport = null;
            }
        }

        /// Whether the render-layer enum is a genuine config-bearing enum whose
        /// `LayerConfig` carries a `.camera` field — i.e. the tag vocabulary is
        /// introspectable. False on layer-less renderers (`void`) or pre-#724
        /// gfx (no `.camera`), where only `"main"` is a known tag and the
        /// unknown-tag warning is suppressed rather than false-firing.
        fn tagVocabularyCheckable() bool {
            if (LayerEnum == void) return false;
            if (@typeInfo(LayerEnum) != .@"enum") return false;
            if (!@hasDecl(LayerEnum, "config")) return false;
            const Cfg = @TypeOf(@field(LayerEnum, @typeInfo(LayerEnum).@"enum".fields[0].name).config());
            return @hasField(Cfg, "camera");
        }

        /// True when `tag` is `"main"` or equals some layer's `.camera` binding.
        /// Only reached under `comptime tagVocabularyCheckable()`, so the enum
        /// reflection below is never analyzed on a `void`/pre-#724 layer enum.
        fn tagInVocabulary(tag: []const u8) bool {
            if (std.mem.eql(u8, tag, "main")) return true;
            inline for (comptime std.enums.values(LayerEnum)) |l| {
                if (l.config().camera) |c| {
                    if (std.mem.eql(u8, c, tag)) return true;
                }
            }
            return false;
        }

        fn warnOnce(self: *Game, flag: *bool, comptime fmt: []const u8, args: anytype) void {
            if (flag.*) return;
            flag.* = true;
            self.log.warn(fmt, args);
        }

        /// MERGE a JSON patch into entity `ent`'s `Camera` component, then
        /// re-seed `getCamera()` so a paused preview updates live. Only the
        /// keys PRESENT in the patch are overwritten — a `{"zoom":…}` patch
        /// leaves an existing `viewport` intact (FLAG C, patch semantics). When
        /// the entity has no `Camera` yet, a default one is materialized and
        /// patched (the studio's first gizmo edit authors the component).
        ///
        /// Errors (leaving the entity untouched) when `source` is unparseable
        /// or its top level is not a JSON object. The parse tree lives in a
        /// call-scoped arena; `Camera.tag` is copied INLINE (bounded buffer,
        /// not a slice into `source`), so nothing aliases `source` past the
        /// call and the caller may free it immediately.
        pub fn applyCameraComponentJson(self: *Game, ent: Entity, source: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var parser = jsonc.JsoncParser.init(arena.allocator(), source);
            const value = try parser.parse();
            // Reject trailing junk after the object (`{...}garbage`): `parse`
            // already consumed trailing whitespace/comments, so any remaining
            // byte is a malformed payload → validation failure, not a silent
            // success that mutates the entity (codex on #719).
            if (parser.pos < parser.source.len) return error.InvalidCameraComponentJson;
            const obj = value.asObject() orelse return error.InvalidCameraComponentJson;

            // Read-existing-then-overlay: start from the live component (or a
            // default) so unprovided keys survive the patch.
            var comp: CameraComp = if (self.ecs_backend.getComponent(ent, CameraComp)) |c| c.* else .{};

            // A PRESENT `zoom` must be numeric — a wrong-shaped value (e.g.
            // `{"zoom":"2"}`) is a validation failure, NOT a silently-ignored
            // key that would author a default zoom (codex on #719). An ABSENT
            // key leaves the existing/default zoom untouched.
            if (obj.get("zoom")) |z_val| switch (z_val) {
                .float => |f| comp.zoom = @floatCast(f),
                .integer => |i| comp.zoom = @floatFromInt(i),
                else => return error.InvalidCameraComponentJson,
            };

            // A PRESENT `viewport` key drives the merge; distinguish an
            // explicit JSON `null` (→ clear back to fullscreen, finding #4)
            // from an absent key (→ leave the viewport untouched). A present
            // but wrong-shaped `viewport` (or sub-field) is a validation
            // failure, same as `zoom`.
            if (obj.get("viewport")) |vp_val| switch (vp_val) {
                .null_value => comp.viewport = null,
                .object => |vp| {
                    // Merge sub-fields into the existing (or default) viewport
                    // so a partial viewport patch is also additive.
                    var out = comp.viewport orelse camera_mod.Viewport{};
                    if (vp.get("x")) |v| out.x = try viewportInt(v);
                    if (vp.get("y")) |v| out.y = try viewportInt(v);
                    if (vp.get("width")) |v| out.width = try viewportInt(v);
                    if (vp.get("height")) |v| out.height = try viewportInt(v);
                    comp.viewport = out;
                },
                else => return error.InvalidCameraComponentJson,
            };

            // A PRESENT `tag` must be a string; it seeds the inline bounded
            // buffer (camera-bound layers, #723/#724). An ABSENT key leaves the
            // existing/default tag untouched (patch semantics, like `zoom`). A
            // wrong-shaped value is a validation failure. Because the tag is
            // copied INLINE, nothing aliases the call-scoped `source` arena.
            if (obj.get("tag")) |t_val| switch (t_val) {
                .string => |s| comp.setTagSlice(s),
                else => return error.InvalidCameraComponentJson,
            };

            self.setComponent(ent, comp);
            seedCameraFromComponent(self);
        }

        /// A viewport sub-field: must be a JSON integer in `i32` range. A
        /// non-integer or out-of-range value fails the patch (codex/gemini on
        /// #719) — never a silent skip nor a panicking raw `@intCast`.
        fn viewportInt(v: jsonc.Value) !i32 {
            return switch (v) {
                .integer => |i| std.math.cast(i32, i) orelse error.InvalidCameraComponentJson,
                else => error.InvalidCameraComponentJson,
            };
        }

        /// labelle-engine#564 — insert a default `Camera` ENTITY into the
        /// just-instantiated ROOT tree when it declares none.
        ///
        /// The engine owns *whether* a camera is needed — "an explicit
        /// `Camera` anywhere in the tree wins" is a property of the
        /// *instantiated* tree (nested-prefab contents, overrides, runtime
        /// spawns), NOT of the static scene source, so it cannot be evaluated
        /// by the assembler at comptime. The assembler owns *where* the call
        /// goes: the root-instantiation site only, never nested-prefab spawns
        /// — which is what keeps "no two cameras when you nest a scene inside a
        /// scene" true. See RFC-CAMERA-PREFABS §"How this subsumes #564".
        ///
        /// Rules (the three from #564, verbatim):
        ///   1. Scans the subtree rooted at `root` for ANY entity carrying a
        ///      `Camera` component. If one exists — anywhere in the tree — the
        ///      tree is left UNTOUCHED (the authored / explicit camera wins).
        ///   2. Otherwise materializes exactly ONE default camera: a fresh
        ///      entity with a default `Position` + default `Camera`, PARENTED
        ///      under `root` (so the `Parent` cascade groups it with the scene)
        ///      and tracked as a scene entity (so the scene-unload drain —
        ///      which pops tracked entities via `destroyEntityOnly`, NOT a
        ///      single root cascade — tears it down too).
        ///   3. Because the assembler emits this call at the root only, nested
        ///      prefabs never each get one, and a tree with several camera-less
        ///      nested subtrees still receives exactly one default at root.
        ///
        /// Returns the entity governing the tree — the pre-existing camera when
        /// found, else the freshly inserted default. Defers entirely (no-op,
        /// returns `null`) for a project that registered its OWN `Camera` in
        /// its `ComponentRegistry` (`camera_is_builtin == false`), mirroring
        /// every other built-in Camera channel (save/load, digest). Independent
        /// of whether the renderer has a settable camera: the inserted entity
        /// exists for the studio (inspector / gizmo / save-load); the render
        /// seed (`seedCameraFromComponent`) still comptime-folds away on a
        /// camera-less renderer, leaving the renderer's slot-0 fallback intact.
        pub fn ensureDefaultCamera(self: *Game, root: Entity) ?Entity {
            if (comptime !Game.camera_is_builtin) return null;

            // "Explicit Camera anywhere in the tree wins": scan every Camera
            // entity, keeping the first that belongs to `root`'s subtree.
            var v = self.ecs_backend.view(.{CameraComp}, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                if (entityInTree(self, ent, root)) return ent;
            }

            // None found — materialize a default at root scope.
            const cam = self.createEntity();
            self.setComponent(cam, Position{});
            self.setComponent(cam, CameraComp{});
            self.setParent(cam, root, .{});
            self.trackSceneEntity(cam);
            return cam;
        }

        /// True when `ent` is `root` or a (transitive) descendant of `root`,
        /// walking the `Parent` chain upward. Depth-capped like
        /// `hierarchy.wouldCreateCycle` so a malformed cycle can't spin.
        fn entityInTree(self: *Game, ent: Entity, root: Entity) bool {
            const Parent = Game.ParentComp;
            var current = ent;
            var depth: u8 = 0;
            while (depth < 33) : (depth += 1) {
                if (current == root) return true;
                if (self.ecs_backend.getComponent(current, Parent)) |p| {
                    current = p.entity;
                } else return false;
            }
            return false;
        }
    };
}
