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

    return struct {
        /// Seed the active gfx camera from the authored `Camera` component:
        /// locate the first entity carrying both `Position` and `Camera`, read
        /// its WORLD position (`getWorldPosition`, matching the digest and
        /// `editor_set_entity_position`) plus `Camera.zoom`, and apply them to
        /// `getCamera()`. A no-op — and a comptime no-op that never touches the
        /// (possibly `void`) camera seam — when the renderer has no settable
        /// camera or the scene declares no Camera entity. Single-camera MVP:
        /// the first Camera entity wins.
        pub fn seedCameraFromComponent(self: *Game) void {
            if (comptime !camera_mod.hasSettableCamera(Game)) return;
            // Defer to a project that registered its OWN `Camera` (finding #1):
            // the built-in seed is off for such projects.
            if (comptime !Game.camera_is_builtin) return;
            var v = self.ecs_backend.view(.{ Position, CameraComp }, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                const cam = self.ecs_backend.getComponent(ent, CameraComp) orelse continue;
                const wp = self.getWorldPosition(ent);
                const camera = self.getCamera();
                camera.setPosition(wp.x, wp.y);
                camera.setZoom(cam.zoom);
                return;
            }
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
        /// call-scoped arena; `Camera` has no string fields, so nothing aliases
        /// `source` past the call and the caller may free it immediately.
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
    };
}
