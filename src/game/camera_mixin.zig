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
            const obj = value.asObject() orelse return error.InvalidCameraComponentJson;

            // Read-existing-then-overlay: start from the live component (or a
            // default) so unprovided keys survive the patch.
            var comp: CameraComp = if (self.ecs_backend.getComponent(ent, CameraComp)) |c| c.* else .{};

            if (obj.getFloat("zoom")) |z| {
                comp.zoom = @floatCast(z);
            } else if (obj.getInteger("zoom")) |z| {
                comp.zoom = @floatFromInt(z);
            }

            // A PRESENT `viewport` key drives the merge; distinguish an
            // explicit JSON `null` (→ clear back to fullscreen, finding #4)
            // from an absent key (→ leave the viewport untouched).
            if (obj.get("viewport")) |vp_val| switch (vp_val) {
                .null_value => comp.viewport = null,
                .object => |vp| {
                    // Merge sub-fields into the existing (or default) viewport
                    // so a partial viewport patch is also additive.
                    var out = comp.viewport orelse camera_mod.Viewport{};
                    // Bounds-check the JSON int → i32 narrowing: an out-of-range
                    // value from studio JSON must fail the patch (-2, entity
                    // untouched — this returns before `setComponent` below), NOT
                    // panic via a raw `@intCast` (gemini on #719).
                    if (vp.getInteger("x")) |x| out.x = std.math.cast(i32, x) orelse return error.InvalidCameraComponentJson;
                    if (vp.getInteger("y")) |y| out.y = std.math.cast(i32, y) orelse return error.InvalidCameraComponentJson;
                    if (vp.getInteger("width")) |w| out.width = std.math.cast(i32, w) orelse return error.InvalidCameraComponentJson;
                    if (vp.getInteger("height")) |h| out.height = std.math.cast(i32, h) orelse return error.InvalidCameraComponentJson;
                    comp.viewport = out;
                },
                else => {}, // a non-object, non-null viewport is ignored
            };

            self.setComponent(ent, comp);
            seedCameraFromComponent(self);
        }
    };
}
