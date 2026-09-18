//! Pixel-water mixin — the game-facing half of the built-in `pixel_water`
//! material (COND-07, labelle-bgfx#100, RFC-PIXEL-WATER phase 5).
//!
//! WHAT LIVES WHERE. Everything animated — simulation time, the fill level,
//! the eight live impacts, ripple expiry and the deterministic
//! oldest-replacement at capacity — is owned by labelle-gfx's water-instance
//! store and reached through the renderer's `createWaterInstance` /
//! `setWaterSettings` / `setWaterLevel` / `advanceWaterTime` /
//! `addWaterRipple` decls. This mixin does NOT reimplement any of it. Its job
//! is the three things gfx cannot do:
//!
//!   1. ASSET + LIFETIME. Resolve the authored `mask` / `reflection` asset
//!      keys to renderer texture handles, create the instance once they are
//!      resident, bind it to the sprite (`Sprite.water` + `material.effect =
//!      .pixel_water`), and release it on destroy / scene reset / reload.
//!   2. AUTHORING VALIDATION with entity- and field-named diagnostics.
//!   3. STAGE BEFORE COMMIT (see `setWaterSettings`).
//!
//! GRACEFUL DEGRADE, two layers, mirroring `visuals.setMaterial`:
//!   * comptime — a renderer without `createWaterInstance` (StubRender, mocks,
//!     any gfx predating labelle-gfx#359) folds the whole side-table and every
//!     helper to a no-op / `error.PixelWaterRejected`. The engine takes no gfx
//!     dependency, so the capability is detected by `@hasDecl` and every
//!     renderer-side type is read off the renderer, never imported.
//!   * runtime — a backend that lacks the water shader reports `pixel_water`
//!     unsupported and draws the authored static reservoir sprite.
//!
//! Side-table rather than "read the id back off `Sprite.water`": an entity
//! whose sprite was removed, or which was destroyed outright, still owes gfx a
//! `releaseWaterInstance`, and the sprite component is exactly what is gone by
//! then. `reapGhostPixelWater` (the mirror of `reapGhostEmitters`) is what
//! makes that collectable. `Sprite.water` remains the DRAW binding; the
//! side-table is the LIFETIME record.

const std = @import("std");
const pw = @import("../pixel_water.zig");
const atlas_mixin = @import("atlas_mixin.zig");

const PixelWater = pw.PixelWater;
const PixelWaterSettings = pw.PixelWaterSettings;
const PixelWaterError = pw.PixelWaterError;
const PixelWaterIssue = pw.PixelWaterIssue;

/// True when the renderer plugin ships labelle-gfx#359's water-instance API.
pub fn rendererSupportsWater(comptime Renderer: type) bool {
    return @hasDecl(Renderer, "createWaterInstance") and
        @hasDecl(Renderer, "WaterInstanceId") and
        @hasDecl(Renderer, "WaterConfig");
}

/// The side-table's value type: the renderer's own generational instance id,
/// or an empty struct on a renderer without the seam (so the table's type is
/// always well-formed and no field is hidden behind a comptime gate).
pub fn WaterInstanceIdOf(comptime Renderer: type) type {
    return if (rendererSupportsWater(Renderer)) Renderer.WaterInstanceId else struct {};
}

/// The catalog references ONE reservoir holds, and the one bit of resolution
/// state that cannot be read back off the renderer.
///
/// Why the names are OWNED copies rather than the component's own slices: the
/// release is owed exactly when the component is gone (entity destroyed,
/// component removed, ECS wiped), and scene-authored names live in the
/// world's nested-entity arena — which the very same teardown frees. A
/// borrowed slice would be dangling at the only moment it is needed.
pub const WaterAssets = struct {
    /// Duped with `game.allocator`; empty when no reference is held.
    mask: []const u8 = "",
    reflection: []const u8 = "",
    /// Set when the instance was created while an authored reflection was
    /// still streaming, so the tick knows to reconfigure once it lands.
    /// Without it, whichever of the two textures finished first would decide
    /// whether the authored reflection ever appears.
    reflection_pending: bool = false,
};

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Renderer = Game.RendererType;
    const Sprite = Game.SpriteComp;

    const supported = rendererSupportsWater(Renderer);
    const WaterInstanceId = WaterInstanceIdOf(Renderer);

    // `Sprite.material.effect` carries labelle-core's `MaterialEffect`, and
    // `.pixel_water` is APPENDED by labelle-core#78. Reached through
    // `@hasField` / `@field` rather than by naming the tag, so the engine
    // still compiles against a core pin that predates the tag — the same
    // additive, capability-gated discipline the rest of the seam uses.
    const MaterialEffectType = if (@hasField(Sprite, "material"))
        @FieldType(@FieldType(Sprite, "material"), "effect")
    else
        void;

    const has_pixel_water_effect = MaterialEffectType != void and
        @hasField(MaterialEffectType, "pixel_water");
    const pixel_water_effect = if (has_pixel_water_effect)
        @field(MaterialEffectType, "pixel_water")
    else {};

    return struct {
        // ── Diagnostics ─────────────────────────────────────────────────

        fn report(self: *Game, entity: Entity, issue: PixelWaterIssue) void {
            self.log.err("PixelWater on entity {any}: field '{s}' {s}", .{
                entity,
                @tagName(issue.field),
                issue.reason.text(),
            });
        }

        // ── Authoring ───────────────────────────────────────────────────

        /// Attach (or re-attach) an authored `PixelWater` to `entity`.
        ///
        /// The single entry point for EVERY authoring path — the JSONC
        /// built-in branch (`component_apply.applyPixelWater`), the comptime
        /// `.zon` writer, the script contract, hot reload and live prefab
        /// refresh all land here, which is what makes the stage-before-commit
        /// rule hold on all of them rather than on whichever one was written
        /// first.
        ///
        /// Returns `false` (having logged a field-named diagnostic) when the
        /// candidate is invalid. On that path NOTHING is committed: no
        /// component is added, an existing component keeps its previous
        /// values, and the gfx instance is untouched.
        pub fn addPixelWater(self: *Game, entity: Entity, candidate: PixelWater) bool {
            // STAGE: validate the candidate before touching either side.
            if (pw.validateComponent(candidate)) |issue| {
                report(self, entity, issue);
                return false;
            }

            if (self.ecs_backend.getComponent(entity, PixelWater)) |existing| {
                // Re-author over a live component (hot reload / prefab
                // refresh). Structural change → explicit reconfiguration;
                // otherwise the same validated synchronization path a runtime
                // caller uses. Both commit gfx first, component second.
                const structural_changed =
                    !std.mem.eql(u8, existing.mask, candidate.mask) or
                    !std.mem.eql(u8, existing.reflection, candidate.reflection) or
                    existing.logical_size[0] != candidate.logical_size[0] or
                    existing.logical_size[1] != candidate.logical_size[1] or
                    existing.grid_pixels != candidate.grid_pixels;

                if (structural_changed) {
                    // Structural fields are the instance's identity; drop and
                    // let the tick recreate it from the new component.
                    releasePixelWaterInstance(self, entity);
                    existing.* = candidate;
                } else {
                    setWaterSettings(self, entity, candidate.settings()) catch return false;
                    setWaterLevel(self, entity, candidate.water_level) catch return false;
                }
                self.drive_pixel_water = true;
                syncWaterAssets(self, entity, candidate);
                return true;
            }

            // COMMIT: fresh component.
            self.addComponent(entity, candidate);
            self.drive_pixel_water = true;
            syncWaterAssets(self, entity, candidate);
            // Opportunistic: if the textures are already resident the
            // instance exists on this very call rather than one tick later.
            _ = resolvePixelWaterInstance(self, entity);
            return true;
        }

        // ── Asset references ────────────────────────────────────────────

        /// The ACTIVE world's asset records. Lives on `Game.World`, not on
        /// `Game`: the keys are that world's entity ids and the table
        /// survives a world swap, so a game-global one would confuse two
        /// worlds' reservoirs whenever their ids collide and would have the
        /// reaper release a shelved world's references (see the field's own
        /// comment in `game.zig`). Every caller below is by definition
        /// operating on the active world.
        fn waterAssetTable(self: *Game) *std.AutoHashMap(Entity, WaterAssets) {
            return &self.active_world.water_assets;
        }

        //
        // A reservoir pins its mask / reflection in the catalog for as long
        // as the component lives, so a streaming mask actually streams and
        // an unrelated `release` cannot evict a texture a live instance is
        // sampling. Every one of those `acquire`s is balanced: the names are
        // recorded per entity (`Game.water_assets`) and released when the
        // component goes away — destroy, `removeComponent` (via the reaper),
        // ECS reset, and `deinit`. An unbalanced `acquire` would pin the
        // texture for the rest of the process and inflate further on every
        // hot reload.

        /// Take the references `comp` needs and drop any this entity held
        /// for other names. A re-author with UNCHANGED names is a no-op —
        /// it must not bump the refcount, or repeated prefab refreshes would
        /// ratchet it up one per pass.
        fn syncWaterAssets(self: *Game, entity: Entity, comp: PixelWater) void {
            if (waterAssetTable(self).getPtr(entity)) |held| {
                if (std.mem.eql(u8, held.mask, comp.mask) and
                    std.mem.eql(u8, held.reflection, comp.reflection)) return;
                releaseWaterAssets(self, entity);
            }

            var rec: WaterAssets = .{};
            rec.mask = acquireOne(self, comp.mask);
            rec.reflection = acquireOne(self, comp.reflection);
            waterAssetTable(self).put(entity, rec) catch {
                freeAssetRecord(self, rec);
            };
        }

        /// Acquire `name` and return an OWNED copy of it, or `""` when there
        /// is nothing to hold (empty name, unregistered asset, OOM). The
        /// returned slice is the receipt: a non-empty one means a reference
        /// IS held and must be released.
        fn acquireOne(self: *Game, name: []const u8) []const u8 {
            if (name.len == 0) return "";
            _ = self.assets.acquire(name) catch return "";
            return self.allocator.dupe(u8, name) catch {
                self.assets.release(name);
                return "";
            };
        }

        fn freeAssetRecord(self: *Game, rec: WaterAssets) void {
            if (rec.mask.len != 0) {
                self.assets.release(rec.mask);
                self.allocator.free(rec.mask);
            }
            if (rec.reflection.len != 0) {
                self.assets.release(rec.reflection);
                self.allocator.free(rec.reflection);
            }
        }

        /// Drop every catalog reference `entity` holds. Safe to call on an
        /// entity that never had any.
        pub fn releaseWaterAssets(self: *Game, entity: Entity) void {
            const kv = waterAssetTable(self).fetchRemove(entity) orelse return;
            freeAssetRecord(self, kv.value);
        }

        /// Drop every reservoir's catalog references (retaining capacity).
        /// The ECS-reset / `deinit` counterpart of `releaseWaterAssets` —
        /// NOT called on a world swap, where the shelved world's components
        /// live on and still own their references.
        pub fn releaseAllWaterAssets(self: *Game) void {
            var it = waterAssetTable(self).valueIterator();
            while (it.next()) |rec| freeAssetRecord(self, rec.*);
            waterAssetTable(self).clearRetainingCapacity();
        }

        /// Release BOTH halves for `entity` — the gfx instance and the
        /// catalog references. The whole-component teardown the destroy
        /// paths and the reaper use.
        pub fn releasePixelWater(self: *Game, entity: Entity) void {
            releasePixelWaterInstance(self, entity);
            releaseWaterAssets(self, entity);
        }

        /// The live component, or `null`.
        pub fn pixelWater(self: *Game, entity: Entity) ?*PixelWater {
            return self.ecs_backend.getComponent(entity, PixelWater);
        }

        /// The gfx instance id bound to `entity`, or `null` while its
        /// textures are still streaming in.
        pub fn waterInstance(self: *Game, entity: Entity) ?WaterInstanceId {
            if (comptime !supported) return null;
            return self.water_instances.get(entity);
        }

        // ── Asset resolution + instance creation ────────────────────────

        /// The backend texture handle a catalog `.image` asset uploaded to, or
        /// `null` while it is not yet resident. Deliberately the very lookup
        /// `bridgeImageAssetsToAtlasManager` uses, so a mask resolves through
        /// the standard streaming path and the catalog keeps texture
        /// ownership — releasing a water instance can never destroy it.
        fn catalogTexture(self: *Game, name: []const u8) ?u32 {
            if (name.len == 0) return null;
            const entry = self.assets.entries.getPtr(name) orelse return null;
            if (entry.loader_kind != .image) return null;
            const resource = entry.resource orelse return null;
            return switch (resource) {
                .image => |t| t,
                else => null,
            };
        }

        /// Build the renderer's `WaterConfig` from an authored component.
        /// `null` when the REQUIRED mask is not resident yet (the reflection
        /// is optional and degrades to "no reflection").
        ///
        /// This is the ONE place authored sRGB hex becomes linear
        /// `PixelWaterRgba` — see the double-gamma note in
        /// `src/pixel_water.zig`.
        fn buildWaterConfig(self: *Game, comp: PixelWater) ?Renderer.WaterConfig {
            if (comptime !supported) return null;
            const Config = Renderer.WaterConfig;
            const TexHandle = @FieldType(Config, "mask");
            const Rgba = @FieldType(Config, "deep");

            const mask = catalogTexture(self, comp.mask) orelse return null;

            var cfg: Config = .{};
            cfg.mask = atlas_mixin.normalizeHandle(TexHandle, mask);
            if (catalogTexture(self, comp.reflection)) |r| {
                cfg.reflection = atlas_mixin.normalizeHandle(TexHandle, r);
            }
            cfg.logical_width = comp.logical_size[0];
            cfg.logical_height = comp.logical_size[1];
            cfg.grid_pixels = comp.grid_pixels;

            // `validateComponent` has already proven these parse; a defensive
            // `catch` keeps the seam total rather than trusting that.
            cfg.deep = pw.toLinearRgba(Rgba, pw.parseHexColor(comp.deep_color) catch return null);
            cfg.surface = pw.toLinearRgba(Rgba, pw.parseHexColor(comp.surface_color) catch return null);
            cfg.highlight = pw.toLinearRgba(Rgba, pw.parseHexColor(comp.highlight_color) catch return null);

            cfg.wave_amplitude_pixels = comp.wave_amplitude_pixels;
            cfg.wave_period_seconds = comp.wave_period_seconds;
            cfg.waves_enabled = comp.waves_enabled;
            cfg.distortion_pixels = comp.distortion_pixels;
            cfg.reflection_opacity = comp.reflection_opacity;
            cfg.ripple_duration_seconds = comp.ripple_duration_seconds;
            cfg.ripple_radius_pixels = comp.ripple_radius_pixels;
            cfg.ripple_strength_pixels = comp.ripple_strength_pixels;
            return cfg;
        }

        /// Create the gfx instance for `entity` if it has a `PixelWater`, has
        /// no instance yet, and its mask is resident. Returns true when an
        /// instance exists afterwards. Idempotent and cheap to call per frame
        /// — that is how a streaming mask "pops in" without a retry timer.
        pub fn resolvePixelWaterInstance(self: *Game, entity: Entity) bool {
            if (comptime !supported) return false;
            if (self.water_instances.get(entity)) |existing_id| {
                // NOT a bare `return true`. Two things can still be owed on
                // an entity that already has an instance:
                //   * the SPRITE may have arrived after the water did
                //     (authored component order, or a sprite removed and
                //     re-added), and the binding is what makes the effect
                //     draw at all;
                //   * an authored REFLECTION may have finished streaming
                //     after the mask did, and nothing else would ever apply
                //     it.
                // Both helpers are idempotent and cost a hash lookup, which
                // is what makes calling them per frame acceptable.
                applyPendingReflection(self, entity, existing_id);
                bindSpriteToInstance(self, entity, existing_id);
                return true;
            }

            const comp = self.ecs_backend.getComponent(entity, PixelWater) orelse return false;
            const cfg = buildWaterConfig(self, comp.*) orelse return false;

            const id = self.renderer.createWaterInstance(cfg) catch |err| {
                self.log.err("PixelWater on entity {any}: createWaterInstance failed: {s}", .{
                    entity, @errorName(err),
                });
                return false;
            };
            self.water_instances.put(entity, id) catch {
                _ = self.renderer.releaseWaterInstance(id);
                return false;
            };

            // Seed the authored level. A failure here is NOT ignorable: it
            // would leave a live instance at the default level while the
            // component reads the authored one — the exact component /
            // instance divergence the rest of this file exists to prevent —
            // and report success. Hand the instance back instead; the tick
            // retries from a clean slate next frame.
            self.renderer.setWaterLevel(id, comp.water_level) catch |err| {
                self.log.err("PixelWater on entity {any}: initial level sync failed: {s}", .{
                    entity, @errorName(err),
                });
                _ = self.water_instances.remove(entity);
                _ = self.renderer.releaseWaterInstance(id);
                return false;
            };

            // Remember a reflection that was still streaming when the
            // (required) mask became resident, so `applyPendingReflection`
            // can finish the job. Whichever texture lands first must not
            // decide whether the authored reflection ever appears.
            if (waterAssetTable(self).getPtr(entity)) |held| {
                held.reflection_pending = comp.reflection.len != 0 and
                    catalogTexture(self, comp.reflection) == null;
            }

            bindSpriteToInstance(self, entity, id);
            return true;
        }

        /// Push the full config again once a late-arriving reflection is
        /// resident. No-op unless one was actually pending.
        fn applyPendingReflection(self: *Game, entity: Entity, id: WaterInstanceId) void {
            if (comptime !supported) return;
            const held = waterAssetTable(self).getPtr(entity) orelse return;
            if (!held.reflection_pending) return;
            const comp = self.ecs_backend.getComponent(entity, PixelWater) orelse return;
            if (catalogTexture(self, comp.reflection) == null) return;
            const cfg = buildWaterConfig(self, comp.*) orelse return;
            self.renderer.setWaterSettings(id, cfg) catch |err| {
                self.log.err("PixelWater on entity {any}: reflection bind failed: {s}", .{
                    entity, @errorName(err),
                });
                return;
            };
            held.reflection_pending = false;
        }

        /// Point the sprite's draw at the instance: `Sprite.water` carries the
        /// id and `Sprite.material.effect` selects the effect. Both writes are
        /// `@hasField`-guarded, so a renderer with a material seam but no
        /// water seam (or neither) still compiles.
        fn bindSpriteToInstance(self: *Game, entity: Entity, id: WaterInstanceId) void {
            const sprite = self.ecs_backend.getComponent(entity, Sprite) orelse return;
            var changed = false;
            if (comptime @hasField(Sprite, "water")) {
                // Equality-guarded: this now runs on EVERY tick of an
                // already-bound reservoir (see `resolvePixelWaterInstance`),
                // and an unconditional write would mark the visual dirty
                // every frame — a redundant sync that breaks the draw batch.
                if (!std.meta.eql(sprite.water, id)) {
                    sprite.water = id;
                    changed = true;
                }
            }
            if (comptime has_pixel_water_effect) {
                if (sprite.material.effect != pixel_water_effect) {
                    sprite.material.effect = pixel_water_effect;
                    changed = true;
                }
            }
            if (changed) self.renderer.markVisualDirty(entity);
        }

        // ── Runtime helpers (delegating to gfx) ─────────────────────────

        /// Validate a complete backend-independent settings value, then
        /// synchronize the component and the gfx-owned instance.
        ///
        /// STAGE BEFORE COMMIT. The candidate is validated, and pushed to gfx,
        /// BEFORE the component is written. That order is the whole point:
        /// committing the component first and synchronizing after leaves a
        /// TORN state when validation rejects — the component holds the new
        /// value while the gfx instance still holds the old one, and nothing
        /// is left to detect the divergence because the component already
        /// looks updated. Here every rejection path (engine validation, or
        /// gfx's own) returns with BOTH sides still on the previous settings.
        ///
        /// Equal settings are a no-op: no gfx call, no revision bump.
        pub fn setWaterSettings(self: *Game, entity: Entity, next: PixelWaterSettings) PixelWaterError!void {
            const comp = self.ecs_backend.getComponent(entity, PixelWater) orelse
                return error.NoPixelWater;

            // STAGE 1 — engine validation of the candidate.
            if (pw.validateSettings(next)) |issue| {
                report(self, entity, issue);
                return error.InvalidPixelWater;
            }

            const staged = comp.withSettings(next);
            if (std.meta.eql(staged, comp.*)) return; // no-op

            // STAGE 2 — push to gfx. Its `setSettings` validates the whole
            // candidate and leaves the previous settings intact on rejection,
            // so a failure here still has the component untouched below.
            if (comptime supported) {
                if (self.water_instances.get(entity)) |id| {
                    const cfg = buildWaterConfig(self, staged) orelse {
                        // Mask no longer resident: refuse rather than commit a
                        // component the instance cannot mirror.
                        report(self, entity, .{ .field = .mask, .reason = .missing });
                        return error.PixelWaterRejected;
                    };
                    self.renderer.setWaterSettings(id, cfg) catch |err| {
                        self.log.err("PixelWater on entity {any}: renderer rejected settings: {s}", .{
                            entity, @errorName(err),
                        });
                        return error.PixelWaterRejected;
                    };
                }
            }

            // COMMIT — only now, with gfx already carrying the new value.
            comp.* = staged;
        }

        /// Set the fill fraction. Clamped to [0, 1] by gfx; NaN/Infinity is
        /// rejected here with a named diagnostic. A nonzero change preserves
        /// every active impact's X, age and strength (they stay attached to
        /// the rising surface); setting zero clears them — both rules live in
        /// gfx, this only forwards.
        pub fn setWaterLevel(self: *Game, entity: Entity, level: f32) PixelWaterError!void {
            const comp = self.ecs_backend.getComponent(entity, PixelWater) orelse
                return error.NoPixelWater;
            if (pw.validateLevel(level)) |issue| {
                report(self, entity, issue);
                return error.InvalidPixelWater;
            }
            const clamped = std.math.clamp(level, 0, 1);
            if (clamped == comp.water_level) return;

            if (comptime supported) {
                if (self.water_instances.get(entity)) |id| {
                    self.renderer.setWaterLevel(id, clamped) catch |err| {
                        self.log.err("PixelWater on entity {any}: renderer rejected level: {s}", .{
                            entity, @errorName(err),
                        });
                        return error.PixelWaterRejected;
                    };
                }
            }
            comp.water_level = clamped;
        }

        /// Toggle surface waves without destroying the authored amplitude.
        pub fn setWaterWavesEnabled(self: *Game, entity: Entity, on: bool) PixelWaterError!void {
            var s = (self.ecs_backend.getComponent(entity, PixelWater) orelse
                return error.NoPixelWater).settings();
            s.waves_enabled = on;
            return setWaterSettings(self, entity, s);
        }

        /// Record one drop impact at reservoir-local `x`, with a
        /// DIMENSIONLESS `strength` in [0, 1] that scales the authored
        /// `ripple_strength_pixels`.
        ///
        /// `strength` is bounded HERE (the runtime boundary);
        /// `ripple_strength_pixels` is bounded in `validateSettings` (the
        /// authored boundary). Both, because a bound on only one of them
        /// leaves the other as the way to exceed it. Peak displacement is
        /// therefore at most `ripple_strength_pixels`, whatever a caller
        /// passes.
        ///
        /// X bounds, the empty-reservoir refusal, expiry, the eight-slot cap
        /// and the deterministic oldest-replacement are gfx's — delegated, not
        /// duplicated. CPU acceptance is logical-bounds only: it does not
        /// query mask coverage, so an in-bounds impact over a masked-out
        /// region may consume a slot and be clipped on the GPU.
        pub fn addWaterRipple(self: *Game, entity: Entity, x: f32, strength: f32) PixelWaterError!void {
            if (self.ecs_backend.getComponent(entity, PixelWater) == null) return error.NoPixelWater;

            if (!std.math.isFinite(x)) {
                report(self, entity, .{ .field = .ripple_x, .reason = .non_finite });
                return error.InvalidPixelWater;
            }
            if (pw.validateRippleStrength(strength)) |issue| {
                report(self, entity, issue);
                return error.InvalidPixelWater;
            }

            if (comptime !supported) return error.PixelWaterRejected;
            const id = self.water_instances.get(entity) orelse return error.PixelWaterRejected;
            self.renderer.addWaterRipple(id, x, strength) catch |err| {
                self.log.err("PixelWater on entity {any}: renderer rejected ripple: {s}", .{
                    entity, @errorName(err),
                });
                return error.PixelWaterRejected;
            };
        }

        // ── Lifetime ────────────────────────────────────────────────────

        /// Opt into the engine-driven water phase. Set automatically when a
        /// scene loads a `PixelWater` (mirroring `drive_particles`), so
        /// scene-authored reservoirs just work and a game with none leaves the
        /// tick a byte-identical no-op.
        pub fn setDrivePixelWater(self: *Game, on: bool) void {
            self.drive_pixel_water = on;
        }

        /// Release the gfx instance bound to `entity` (if any) and forget it.
        /// Never touches the mask/reflection textures — the asset catalog owns
        /// those, and a second reservoir may be sharing them.
        pub fn releasePixelWaterInstance(self: *Game, entity: Entity) void {
            if (comptime !supported) return;
            if (self.water_instances.fetchRemove(entity)) |kv| {
                _ = self.renderer.releaseWaterInstance(kv.value);
                if (self.ecs_backend.getComponent(entity, Sprite)) |sprite| {
                    if (comptime @hasField(Sprite, "water")) sprite.water = .none;
                    if (comptime has_pixel_water_effect) {
                        if (sprite.material.effect == pixel_water_effect) {
                            sprite.material.effect = .none;
                        }
                    }
                    self.renderer.markVisualDirty(entity);
                }
            }
        }

        /// Release every instance and empty the table (retaining capacity).
        /// Called from `resetEcsBackend` (scene swap / load): the ECS is about
        /// to be wiped, so every entity key becomes a dangling handle.
        pub fn clearPixelWaterInstances(self: *Game) void {
            if (comptime !supported) return;
            // Through `releasePixelWaterInstance` rather than a raw release
            // loop: a world SWAP also lands here, and there the entities
            // survive — so their sprites must lose the now-dead id too, or
            // a shelved reservoir keeps a stale `Sprite.water` until
            // something happens to rebind it. `fetchRemove` invalidates the
            // iterator, hence the take-the-first-key loop.
            while (true) {
                var it = self.water_instances.iterator();
                const entry = it.next() orelse break;
                releasePixelWaterInstance(self, entry.key_ptr.*);
            }
            self.water_instances.clearRetainingCapacity();
        }

        /// Free any side-table entry whose entity no longer carries the
        /// `PixelWater` component — the orphan a `removeComponent` or an
        /// entity destroy leaves behind (`game.destroyEntity` cascades to
        /// children, so a destroyed parent can orphan several at once).
        /// Restart-on-remove iteration because `fetchRemove` invalidates the
        /// map iterator.
        pub fn reapGhostPixelWater(self: *Game) void {
            if (comptime !supported) return;
            outer: while (true) {
                var it = self.water_instances.iterator();
                while (it.next()) |entry| {
                    const entity = entry.key_ptr.*;
                    if (!self.ecs_backend.hasComponent(entity, PixelWater)) {
                        releasePixelWater(self, entity);
                        continue :outer; // iterator invalidated — restart
                    }
                }
                break;
            }
            // The asset table is the SUPERSET: a reservoir whose mask never
            // became resident holds catalog references without ever having
            // had an instance, so sweeping only the instance table above
            // would strand exactly those.
            outer_assets: while (true) {
                var it = waterAssetTable(self).iterator();
                while (it.next()) |entry| {
                    const entity = entry.key_ptr.*;
                    if (!self.ecs_backend.hasComponent(entity, PixelWater)) {
                        releaseWaterAssets(self, entity);
                        continue :outer_assets;
                    }
                }
                break;
            }
        }

        /// Release every instance and the instance table itself. Called from
        /// `Game.deinit`.
        ///
        /// The ASSET records are not touched here: they live on each `World`
        /// now, and every world's teardown (`World.deinit`) frees its own
        /// name copies. That is also why no `assets.release` happens on the
        /// `Game.deinit` path at all — the catalog is already gone by then.
        pub fn deinitPixelWaterInstances(self: *Game) void {
            if (comptime supported) clearPixelWaterInstances(self);
            self.water_instances.deinit();
        }

        /// Drop the catalog references held by a world that is about to be
        /// DESTROYED (`destroyWorld`, or the unnamed active world discarded
        /// by `setActiveWorld`). Runs while the catalog is still alive,
        /// which is exactly what `World.deinit` cannot assume; it leaves the
        /// table empty so that teardown has nothing left to free.
        pub fn releaseWorldWaterAssets(self: *Game, world: *Game.World) void {
            var it = world.water_assets.valueIterator();
            while (it.next()) |rec| freeAssetRecord(self, rec.*);
            world.water_assets.clearRetainingCapacity();
        }
    };
}
