/// Visuals mixin — sprite, shape, text, icon, and gizmo management + z-index.
const std = @import("std");
const core = @import("labelle-core");
const Position = core.Position;

/// `sourceRectFor` / `SourceRectOf` / `normalizeHandle` — the atlas→geometry
/// mapping shared with `resolveAtlasSprites`. `setSpriteFrame` MUST go through
/// the same function the per-frame resolver uses, or the two paths would drift
/// (that drift is exactly what issue #826 documents in the wild).
const atlas_mixin = @import("atlas_mixin.zig");

/// Curated per-entity material effect + uniforms (labelle-gfx#305). Sourced
/// from `labelle-core` so the engine, the renderer plugin's `Sprite.material`
/// field, and game code all name ONE nominal type (gfx re-exports the same
/// `backend_contract.Material`). Re-exported at the module root as
/// `engine.Material`. See `setMaterial` / `clearMaterial` below.
const Material = core.backend_contract.Material;

/// Returns the visual management mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Sprite = Game.SpriteComp;
    const Shape = Game.ShapeComp;
    const Text = Game.TextComp;
    const Icon = Game.IconComp;
    const Gizmo = core.GizmoComponent(Entity);

    // The three fields `setSpriteFrame` writes. Same predicate
    // `atlas_mixin.resolveAtlasSprites` gates on — a renderer is free to
    // ship a `Sprite` without any of them (`StubRender`, test mocks).
    const has_atlas_sprite_fields = @hasField(Sprite, "sprite_name") and
        @hasField(Sprite, "source_rect") and @hasField(Sprite, "texture");

    // A renderer keys textures on either an enum handle (labelle-gfx's
    // `TextureId`) or a plain integer; `normalizeHandle` bridges both.
    const TextureHandle = if (has_atlas_sprite_fields) @FieldType(Sprite, "texture") else void;

    return struct {
        pub fn addSprite(self: *Game, entity: Entity, sprite: Sprite) void {
            self.ecs_backend.addComponent(entity, sprite);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .sprite);
        }

        pub fn addShape(self: *Game, entity: Entity, shape: Shape) void {
            self.ecs_backend.addComponent(entity, shape);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .shape);
        }

        pub fn addText(self: *Game, entity: Entity, text: Text) void {
            self.ecs_backend.addComponent(entity, text);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .text);
        }

        pub fn addIcon(self: *Game, entity: Entity, icon: Icon) void {
            self.ecs_backend.addComponent(entity, icon);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .sprite);
        }

        /// Create a gizmo entity attached to a parent. The gizmo follows
        /// the parent's position automatically via GizmoComponent.
        pub fn addGizmo(self: *Game, parent: Entity, shape: Shape, offset_x: f32, offset_y: f32) Entity {
            self.assertEntityAlive(parent, "addGizmo (parent)");
            const gizmo_entity = self.createEntity();
            const parent_pos = self.getPosition(parent);

            self.ecs_backend.addComponent(gizmo_entity, Gizmo{
                .parent_entity = parent,
                .offset_x = offset_x,
                .offset_y = offset_y,
            });
            self.bumpRoster(); // Gizmo membership changed (#653)
            self.setPosition(gizmo_entity, .{
                .x = parent_pos.x + offset_x,
                .y = parent_pos.y + offset_y,
            });
            self.addShape(gizmo_entity, shape);

            return gizmo_entity;
        }

        pub fn removeSprite(self: *Game, entity: Entity) void {
            self.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Sprite);
            self.bumpRoster(); // membership changed (#653)
        }

        pub fn removeShape(self: *Game, entity: Entity) void {
            self.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Shape);
            self.bumpRoster(); // membership changed (#653)
        }

        pub fn removeText(self: *Game, entity: Entity) void {
            self.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Text);
            self.bumpRoster(); // membership changed (#653)
        }

        pub fn setZIndex(self: *Game, entity: Entity, z_index: i16) void {
            self.assertEntityAlive(entity, "setZIndex");
            var updated = false;
            if (self.ecs_backend.getComponent(entity, Sprite)) |sprite| {
                sprite.z_index = z_index;
                updated = true;
            }
            if (self.ecs_backend.getComponent(entity, Shape)) |shape| {
                shape.z_index = z_index;
                updated = true;
            }
            if (Text != void) {
                if (self.ecs_backend.getComponent(entity, Text)) |text| {
                    text.z_index = z_index;
                    updated = true;
                }
            }
            if (updated) {
                self.renderer.markVisualDirty(entity);
            }
        }

        /// Set the sprite's horizontal flip and mark the entity's visuals
        /// dirty so the renderer picks up the change on the next sync.
        ///
        /// Bundles the `sprite.flip_x = X` + `renderer.markVisualDirty(entity)`
        /// pair that callers previously had to write by hand — forgetting the
        /// dirty-mark was a silent bug (visual stayed stale).
        ///
        /// Returns silently if the entity has no `Sprite` component — callers
        /// that need to assert presence should `getComponent` themselves first.
        /// Short-circuits when the flip value already matches, avoiding a
        /// wasted dirty-mark.
        ///
        /// Comptime no-op on backends whose `Sprite` doesn't carry a `flip_x`
        /// field (`StubRender`, mock renderers in downstream tests). Keeps the
        /// helper safe to call uniformly across renderers without a wrapper.
        pub fn setSpriteFlip(self: *Game, entity: Entity, flip_x: bool) void {
            if (comptime !@hasField(Sprite, "flip_x")) return;
            self.assertEntityAlive(entity, "setSpriteFlip");
            const sprite = self.ecs_backend.getComponent(entity, Sprite) orelse return;
            if (sprite.flip_x == flip_x) return;
            sprite.flip_x = flip_x;
            self.renderer.markVisualDirty(entity);
        }

        // ── Atlas frame swap ──────────────────────────────────────

        /// Point a sprite entity at a different atlas frame by name: stamps
        /// `sprite_name`, re-resolves `source_rect` + `texture` through the
        /// per-entity sprite cache, and marks the visual dirty. One call for
        /// the whole "advance an animation frame" operation.
        ///
        /// WHY THIS EXISTS (#826): assigning `sprite.sprite_name = "other.png"`
        /// alone renders the OLD frame — the renderer draws from `source_rect`
        /// + `texture`, and nothing re-resolves those until the next
        /// `resolveAtlasSprites` pass. So every animation script grew its own
        /// `resolveSprite` helper reaching into the atlas manager by hand. Five
        /// copies of those twelve lines exist across two games and a demo.
        ///
        /// WHY `texture_scale_*` IS THE LOAD-BEARING PART: `FindSpriteResult`
        /// carries `texture_scale_x` / `texture_scale_y`, which are `1.0` for a
        /// 1:1 atlas and `< 1` when the shipped PNG was downscaled without
        /// re-running TexturePacker (a workflow the engine supports — see the
        /// `FindSpriteResult` doc comment in `src/atlas.zig`). The source rect's
        /// x/y/w/h are TEXTURE-pixel coordinates and must be multiplied by that
        /// scale, while the DISPLAY dimensions are design-space and must stay
        /// un-scaled. Every one of the five hand-rolled copies reads
        /// `found.sprite.x/y/getWidth()/getHeight()` raw, so all five silently
        /// mis-sample a downscaled atlas — sampling from beyond the texture's
        /// real extent and drawing the wrong pixels, with nothing logged. This
        /// helper delegates to `sourceRectFor`, the same pure mapping
        /// `resolveAtlasSprites` uses, so the scale (and trim geometry, and
        /// rotation) can only ever be applied one way.
        ///
        /// Resolves via `findSpriteCached` rather than `findSprite`: this is the
        /// per-frame animation path, so the entity-keyed cache turns a repeated
        /// hash walk over every loaded atlas into a version+hash compare.
        ///
        /// FAILURE POSTURE — silent, matching `setSpriteFlip` / `setMaterial`
        /// (and `resolveAtlasSprites`, which skips unresolved names without a
        /// word). No `log.warn`: this is called every frame by animation
        /// scripts, so a warn on an unresolved name would be an unbounded log
        /// flood rather than a diagnostic.
        ///  * Entity has no `Sprite` component → returns without touching
        ///    anything. Callers needing an assertion should `getComponent` first.
        ///  * Name doesn't resolve → `sprite_name` IS still stamped, but
        ///    `source_rect` / `texture` are left alone and the visual is NOT
        ///    marked dirty. Stamping the name is deliberate: it mirrors the
        ///    hand-rolled helpers, and it lets the per-frame `resolveAtlasSprites`
        ///    pass pick the frame up on its own once the atlas finishes loading
        ///    (a deferred-load swap self-heals instead of sticking forever). The
        ///    alternative — a total no-op that leaves the old name in place —
        ///    would be more literally "no-op safe" but would strand any caller
        ///    that swaps a frame before its atlas is resident.
        ///
        /// Comptime no-op on renderers whose `Sprite` lacks the atlas trio
        /// (`sprite_name` / `source_rect` / `texture`) — `StubRender` and mock
        /// renderers in downstream tests — so the helper stays safe to call
        /// uniformly, exactly like `setSpriteFlip`'s `flip_x` guard.
        pub fn setSpriteFrame(self: *Game, entity: Entity, name: []const u8) void {
            if (comptime !has_atlas_sprite_fields) return;
            self.assertEntityAlive(entity, "setSpriteFrame");
            const sprite = self.ecs_backend.getComponent(entity, Sprite) orelse return;

            sprite.sprite_name = name;

            const result = self.findSpriteCached(@intCast(entity), name) orelse return;

            sprite.source_rect = atlas_mixin.sourceRectFor(atlas_mixin.SourceRectOf(Sprite), result);
            sprite.texture = atlas_mixin.normalizeHandle(TextureHandle, result.texture_id);
            self.renderer.markVisualDirty(entity);
        }

        /// Apply a curated per-entity material effect (flash / palette_swap /
        /// dissolve / outline — labelle-gfx#305) to a sprite entity, then mark
        /// its visuals dirty so the renderer picks up the change on the next
        /// sync.
        ///
        /// The runtime mirror of the declarative `.Sprite = .{ .material = … }`
        /// scene/prefab authoring path: material rides INLINE on the sprite
        /// component (exactly like `tint` / `flip_x`), so there is no separate
        /// `Material` component to register — this setter and the scene loader's
        /// generic field coercion feed the very same `Sprite.material` field.
        ///
        /// Bundles the `sprite.material = m` + `renderer.markVisualDirty(entity)`
        /// pair (forgetting the dirty-mark leaves the visual stale — the same
        /// silent bug `setSpriteFlip` was created to prevent). Short-circuits
        /// when the material already matches, avoiding a wasted dirty-mark and
        /// the batch-breaking material re-submit it would provoke.
        ///
        /// GRACEFUL DEGRADE — two layers, no crash on either:
        ///  1. Comptime: a no-op on renderers whose `Sprite` carries no
        ///     `material` field (`StubRender`, mock renderers, and gfx builds
        ///     predating the material seam). The `@hasField` guard short-circuits
        ///     before any field access, so the setter is safe to call uniformly.
        ///  2. Runtime: on a backend that lacks the specific effect's shader,
        ///     the renderer's `materialSupported` gate draws the plain sprite
        ///     (`labelle-gfx#305`). Setting an unsupported material never
        ///     crashes — it simply has no visible effect on that backend.
        ///
        /// Returns silently if the entity has no `Sprite` component — callers
        /// that need to assert presence should `getComponent` themselves first
        /// (matches `setSpriteFlip` / `setZIndex`).
        pub fn setMaterial(self: *Game, entity: Entity, material: Material) void {
            if (comptime !@hasField(Sprite, "material")) return;
            self.assertEntityAlive(entity, "setMaterial");
            const sprite = self.ecs_backend.getComponent(entity, Sprite) orelse return;
            if (std.meta.eql(sprite.material, material)) return;
            sprite.material = material;
            self.renderer.markVisualDirty(entity);
        }

        /// Remove any material effect from a sprite entity, restoring the plain
        /// (fast-path, fully batchable) sprite draw. Equivalent to
        /// `setMaterial(entity, .{})` — `Material.effect == .none` is the
        /// no-material default that never touches the renderer's material path.
        ///
        /// Same graceful-degrade + missing-`Sprite` + short-circuit semantics as
        /// `setMaterial`.
        pub fn clearMaterial(self: *Game, entity: Entity) void {
            self.setMaterial(entity, .{});
        }
    };
}
