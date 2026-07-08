//! Tilemap mixin (T2 Phase 2) — the `Game`-side lifecycle for the
//! `Tilemap` component: registration, `.tmx` decode behind the embedded
//! asset registry, the post-sprite render pass, and teardown.
//!
//! All heavy machinery is gated on `Game.tilemap_supported` (whether the
//! renderer plugin exposes gfx's tilemap seam). When unsupported,
//! `addTilemap` still attaches the component (so scene-load / save / digest
//! behave), but no decoded-map runtime is built and the render pass is a
//! no-op — keeping the feature purely additive for stub renderers.

const std = @import("std");
const core = @import("labelle-core");
const tilemap_runtime = @import("../tilemap_runtime.zig");
const tilemap_mod = @import("../tilemap.zig");

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Tilemap = Game.TilemapComp;
    const supported = Game.tilemap_supported;
    const Runtime = Game.TilemapRuntimeType;

    // T3 Z-interleave: bind `.tmx` layers to engine layers by name and draw
    // bound layers at their engine layer's z (via the renderer's per-layer
    // hook), interleaved with the sprite layers. `LayerEnum` is the
    // renderer's `Layer` (or `void` when unsupported); the interleave
    // helpers below are only ever *referenced* on the interleave path in
    // `loop_mixin.render` (gated by `Game.tilemap_interleave_supported`), so
    // they are never analyzed when `LayerEnum` is `void`.
    const LayerEnum = Game.RenderLayerEnum;
    const LayerBinding = tilemap_mod.LayerBinding;

    // Whether the renderer plugin exposes a world camera the tilemap pass
    // can render through: a `begin()/end()` camera reached via
    // `Game.getCamera()` (gfx's `GfxRendererWith`/`CameraWith` satisfy
    // this; `Game.CameraType != void` is set exactly when the renderer
    // declares `CameraType`, and `getCamera` is wired on the same gate).
    // When present, the pass runs INSIDE that camera transform so a
    // tilemap pans/zooms with the world exactly like sprites (T2 Phase 3).
    // When absent — a bare test stub or a screen-only backend — the pass
    // falls back to raw screen space, which is the identity for a static
    // view.
    const camera_capable = Game.CameraType != void and
        @hasDecl(Game.CameraType, "begin") and
        @hasDecl(Game.CameraType, "end");

    // Whether the camera also exposes `getViewport()` — the active camera's
    // visible WORLD rect. When present, the interleave path culls each bound
    // `.tmx` layer to that rect (via gfx ≥1.23.0's `view_start_*`), so a
    // panned / split-screen camera on a large map draws the tiles it actually
    // sees instead of the world-origin range (codex #711 P1). When absent
    // (a stub camera without a viewport) the cull falls back to the backend
    // screen size at the world origin — the pre-#711 behavior.
    const camera_cullable = blk: {
        if (!camera_capable) break :blk false;
        break :blk @hasDecl(Game.CameraType, "getViewport");
    };

    // World-unit margin added on every side of the per-camera cull rect so a
    // tile straddling the viewport edge is never clipped (mirrors the
    // renderer's own `cull_margin` for sprite viewport culling).
    const cull_margin: f32 = 64;

    return struct {
        /// Register raw bytes for a tilemap-related embedded asset — the
        /// `.tmx` document itself AND each tileset image it references,
        /// both keyed by their asset name (the `.tmx` file name and each
        /// tileset's `image_source`). The assembler emits these calls in
        /// `init()` for embedded builds (Phase 4); tests register fixtures
        /// directly. `name` is owned (dup'd); `bytes` is a program-lifetime
        /// borrow (`@embedFile`), stored by reference and never freed.
        pub fn addEmbeddedTilemapAsset(self: *Game, name: []const u8, bytes: []const u8) !void {
            const gop = try self.embedded_tilemap_sources.getOrPut(name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, name);
            }
            gop.value_ptr.* = bytes;
        }

        /// Bytes provider trampoline backing `tilemap_runtime.ImageProvider`.
        fn provideImage(context: ?*anyopaque, name: []const u8) ?[]const u8 {
            const game: *Game = @ptrCast(@alignCast(context.?));
            return game.embedded_tilemap_sources.get(name);
        }

        /// Attach a `Tilemap` component and (when supported) decode its
        /// `.tmx` asset + bind a draw-pass renderer. Mirrors the
        /// `addSprite`/`addShape` shape, minus renderer entity-tracking —
        /// a tilemap is not a per-entity retained visual; it renders as a
        /// dedicated post-sprite pass.
        pub fn addTilemap(self: *Game, entity: Entity, tilemap: Tilemap) void {
            self.ecs_backend.addComponent(entity, tilemap);
            self.bumpRoster(); // membership changed (#653)
            if (comptime !supported) return;
            acquireTilemap(self, entity, tilemap.asset_name);
        }

        /// (Re)build the decoded-map runtime for an entity from its asset.
        /// Idempotent: a prior runtime for `entity` is freed first, so a
        /// save/load rehydrate or a scene reload can't leak or double-bind.
        /// A missing asset / decode failure leaves the component attached
        /// with no runtime (the entity simply renders nothing) rather than
        /// failing the load.
        pub fn acquireTilemap(self: *Game, entity: Entity, asset_name: []const u8) void {
            if (comptime !supported) return;
            releaseTilemap(self, entity);

            const tmx = self.embedded_tilemap_sources.get(asset_name) orelse {
                self.log.warn("tilemap asset '{s}' not registered — nothing to decode", .{asset_name});
                return;
            };

            const rt = self.allocator.create(Runtime) catch return;
            const provider = tilemap_runtime.ImageProvider{
                .context = self,
                .getFn = provideImage,
            };
            rt.initInPlace(self.allocator, self.renderer, tmx, provider) catch |err| {
                self.log.warn("tilemap '{s}' decode failed: {s}", .{ asset_name, @errorName(err) });
                self.allocator.destroy(rt);
                return;
            };
            self.tilemaps.put(entity, rt) catch {
                rt.deinit();
                self.allocator.destroy(rt);
            };
        }

        /// Drop and free an entity's tilemap runtime, if any. Called from
        /// the entity destroy paths and before a re-acquire.
        pub fn releaseTilemap(self: *Game, entity: Entity) void {
            if (comptime !supported) return;
            if (self.tilemaps.fetchRemove(entity)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
        }

        /// Detach a `Tilemap` component AND free its decoded-map runtime —
        /// the counterpart to `addTilemap` (F4). Prefer this over the
        /// generic `removeComponent(entity, Tilemap)`, which would strip the
        /// component but leave the side-table runtime alive; `renderTilemaps`
        /// reaps such orphans defensively, but going through `removeTilemap`
        /// frees the runtime immediately.
        pub fn removeTilemap(self: *Game, entity: Entity) void {
            releaseTilemap(self, entity);
            self.removeComponent(entity, Tilemap);
        }

        /// The tilemap BACKGROUND pass: before the entity render pass, draw
        /// every `Tilemap` entity's decoded map at its world `Position`,
        /// INSIDE the world camera transform. The engine owns pass ordering
        /// here — tilemaps first (terrain under gameplay entities), sprites
        /// after (see `loop_mixin.render`); gfx's `RetainedEngine` is
        /// untouched.
        ///
        /// **World space (T2 Phase 3).** When the renderer exposes a camera
        /// (`camera_capable`), the pass is wrapped in the SAME
        /// `camera.begin()/end()` sprites render through, and each map draws
        /// with `camera_x/camera_y = 0` — the camera MATRIX (not a software
        /// offset) does the pan/zoom, so a Tilemap entity's `Position` is a
        /// true world position that stays aligned with sprites at the same
        /// world coords under any camera pan or zoom. A renderer with no
        /// camera falls back to raw screen space (the identity for a static
        /// view), preserving the T2 behaviour for headless/stub backends.
        ///
        /// **Y-axis (F3).** The map's world offset is flipped through the
        /// SAME `core.toScreenY` transform sprites use, so a tilemap and a
        /// sprite at the same `Position.y` align under `.up` (and are the
        /// identity under `.down`). Since the map draws downward from its
        /// top-left, under `.up` — where `Position.y` is the map's *bottom*
        /// edge — the flipped screen offset is additionally raised by the
        /// map's pixel height so the bottom edge lands at
        /// `toScreenY(.up, pos.y, H)`.
        ///
        /// **Ghost guard (F4/F2).** Entities whose `Tilemap` component was
        /// stripped via the generic `removeComponent` — or stale ids left
        /// over from a world swap (F2) — are reaped from the side table and
        /// never drawn: the table is keyed on the Game, not swapped with
        /// `active_world`, so it's guarded against the CURRENTLY active ECS.
        ///
        /// **Z-interleaving (T3).** `renderTilemaps` is the WHOLE-STACK
        /// background used by renderers WITHOUT the per-layer render hook
        /// (`renderWithLayerHook`) — it draws every `.tmx` layer under every
        /// sprite. On a hook-capable renderer, `loop_mixin.render` instead
        /// splits the work: `renderTilemapBackground` draws only the
        /// *unbound* `.tmx` layers pre-sprite, and `tilemapLayerHook` draws
        /// each *bound* layer at its engine layer's z, interleaved with the
        /// sprite layers and per active camera (see below).
        pub fn renderTilemaps(self: *Game) void {
            if (comptime !supported) return;

            // Fast path: games/scenes without tilemaps pay nothing per frame —
            // skip the reap iterator entirely. `reapGhostTilemaps` only ever
            // removes entries, so an empty table has nothing to reap.
            if (self.tilemaps.count() == 0) return;
            reapGhostTilemaps(self);
            if (self.tilemaps.count() == 0) return; // all entries were ghosts

            // Enter the SAME world camera transform sprites render through,
            // so the tilemap pass is world-space: pans/zooms with the world.
            // `camera_x/camera_y` passed to `draw` stay 0 — the camera matrix
            // does the transform, matching how sprites use the camera. On a
            // camera-less renderer this folds away and the pass runs in raw
            // screen space (the T2 fallback).
            //
            // LIMITATION — single active camera: this wraps the primary camera
            // ONCE. Under split-screen / multi-camera the renderer draws sprites
            // once PER active camera (each viewport), but this background pass
            // runs a single full-window time, so secondary viewports would show
            // the primary camera's terrain. Per-camera tilemap backgrounds are
            // tracked in engine#709; single-camera (the common case + the
            // colony demo) is correct.
            if (comptime camera_capable) self.getCamera().begin();
            defer if (comptime camera_capable) self.getCamera().end();

            var it = self.tilemaps.iterator();
            while (it.next()) |e| {
                const entity = e.key_ptr.*;
                const rt = e.value_ptr.*;
                const off = tilemapWorldOffset(self, entity, rt);
                rt.draw(0, 0, off.x, off.y, null, null);
            }
        }

        /// The map's world-space draw offset for `entity` (T2/T3). `x` is
        /// the entity's world `Position.x`; `y` flips the world Y into
        /// screen space exactly as the renderer flips sprite Y, then (under
        /// `.up`) raises by the map's pixel height so the map's BOTTOM edge
        /// sits at the flipped `Position.y` — identity under `.down`. Shared
        /// by the whole-stack background (`renderTilemaps`), the unbound
        /// background (`renderTilemapBackground`), and the per-layer
        /// interleave (`tilemapLayerHook`) so a bound and an unbound layer of
        /// the same map never disagree on where the map sits.
        fn tilemapWorldOffset(self: *Game, entity: Entity, rt: *Runtime) struct { x: f32, y: f32 } {
            const pos = self.getWorldPosition(entity);
            const off_y = core.toScreenY(Game.y_axis, pos.y, tilemapScreenHeight(self)) -
                switch (Game.y_axis) {
                    .up => rt.pixelHeight(),
                    .down => @as(f32, 0),
                };
            return .{ .x = pos.x, .y = off_y };
        }

        /// The per-camera CULL rect (gfx ≥1.23.0 `view_start_*` + `view_*`),
        /// expressed in the frame the tilemap offsets use: X is unflipped
        /// (same frame as `off_x`); Y is flipped through the SAME
        /// `core.toScreenY` as `off_y`, so the cull window and the drawn tiles
        /// agree. Fed the ACTIVE camera's visible world rect so a panned /
        /// split-screen camera on a large map culls to its OWN region rather
        /// than the world origin (codex #711 P1). Every side is expanded by
        /// `cull_margin`. Returns all-`null` when the camera can't report a
        /// viewport (→ gfx falls back to the backend screen size at the world
        /// origin — the pre-#711 behavior). `null` for the whole thing keeps
        /// the call-site fields optional.
        const CullRect = struct {
            start_x: ?f32 = null,
            start_y: ?f32 = null,
            width: ?f32 = null,
            height: ?f32 = null,
        };
        fn cameraCullRect(self: *Game, cam: *const Game.CameraType) CullRect {
            if (comptime !camera_cullable) return .{};
            const vp = cam.getViewport(); // Y-up world rect {x, y, width, height}
            const h = tilemapScreenHeight(self);
            // Flip both world-Y edges to the tilemap (screen-Y) frame and take
            // the min as the top; `toScreenY` is monotonic so the two edges
            // bracket the same span under either y-axis convention.
            const y0 = core.toScreenY(Game.y_axis, vp.y, h);
            const y1 = core.toScreenY(Game.y_axis, vp.y + vp.height, h);
            return .{
                .start_x = vp.x - cull_margin,
                .start_y = @min(y0, y1) - cull_margin,
                .width = vp.width + 2 * cull_margin,
                .height = vp.height + 2 * cull_margin,
            };
        }

        // ── T3 Z-interleave (hook-capable renderers only) ───────────────

        /// Resolve a `.tmx` layer name to the WORLD engine layer it renders
        /// at, or `null` when it is UNBOUND (→ background pass). Explicit
        /// `layer_bindings` win over the implicit-by-name rule; either way
        /// the target must be a known WORLD-space `LayerEnum` tag (a binding
        /// to a screen-space or unknown engine layer is treated as unbound,
        /// since a tilemap can only draw inside the world camera transform).
        fn resolveBinding(bindings: ?[]const LayerBinding, tmx_name: []const u8) ?LayerEnum {
            if (bindings) |list| {
                for (list) |b| {
                    if (std.mem.eql(u8, b.tmx_layer, tmx_name)) {
                        return worldLayerFromName(b.engine_layer);
                    }
                }
            }
            return worldLayerFromName(tmx_name);
        }

        /// `LayerEnum` tag named `name`, but only if it is a WORLD-space
        /// layer; `null` for an unknown name or a screen-space layer.
        fn worldLayerFromName(name: []const u8) ?LayerEnum {
            // Precondition (guaranteed by `Game.tilemap_interleave_supported`,
            // the only gate that reaches this fn): `LayerEnum` is a genuine
            // config-bearing enum, so `stringToEnum`/`config()` below are
            // sound. Asserted locally so the safety is obvious here too.
            comptime std.debug.assert(@typeInfo(LayerEnum) == .@"enum" and @hasDecl(LayerEnum, "config"));
            const l = std.meta.stringToEnum(LayerEnum, name) orelse return null;
            if (l.config().space != .world) return null;
            return l;
        }

        /// Pre-sprite background pass for hook-capable renderers: draws only
        /// the `.tmx` layers that are NOT bound to an engine layer (bound
        /// layers are drawn interleaved by `tilemapLayerHook`). Mirrors
        /// `renderTilemaps` (whole-stack, primary-camera, world-space) but
        /// per-layer-filtered — so a Tilemap with no bindings / no
        /// name-matching engine layers renders EXACTLY as T2. Reaps ghosts
        /// (runs before the hook, which does not).
        pub fn renderTilemapBackground(self: *Game) void {
            if (comptime !supported) return;
            if (self.tilemaps.count() == 0) return;
            reapGhostTilemaps(self);
            if (self.tilemaps.count() == 0) return;

            if (comptime camera_capable) self.getCamera().begin();
            defer if (comptime camera_capable) self.getCamera().end();

            // Cull the background (unbound) layers to the primary camera's
            // world rect — same treatment as the interleaved layers, so a
            // panned primary camera on a large map keeps its background too.
            const cull = if (comptime camera_cullable) cameraCullRect(self, self.getCamera()) else CullRect{};

            var it = self.tilemaps.iterator();
            while (it.next()) |e| {
                const entity = e.key_ptr.*;
                const rt = e.value_ptr.*;
                const comp = self.ecs_backend.getComponent(entity, Tilemap) orelse continue;
                const off = tilemapWorldOffset(self, entity, rt);
                var i: usize = 0;
                while (i < rt.layerCount()) : (i += 1) {
                    if (resolveBinding(comp.layer_bindings, rt.layerName(i)) != null) continue;
                    rt.drawLayerAt(i, 0, 0, off.x, off.y, cull.start_x, cull.start_y, cull.width, cull.height);
                }
            }
        }

        /// Per-layer render hook (T3) passed to `renderer.renderWithLayerHook`.
        /// Fires after each engine layer's sprite pass, INSIDE that layer's
        /// active camera transform for world layers — and once per active
        /// camera, so split-screen renders bound tilemap layers per viewport
        /// automatically (closes #709). For the just-drawn engine `layer`,
        /// draws every Tilemap's `.tmx` layer bound to it, at world coords
        /// (`camera_x/y = 0`; the camera matrix does the pan/zoom, matching
        /// sprites), CULLED to `cam`'s own visible world rect — so a panned or
        /// split-screen camera on a large map draws the tiles IT sees, not the
        /// world-origin range (codex #711 P1).
        pub fn tilemapLayerHook(self: *Game, layer: LayerEnum, cam: *const Game.CameraType) void {
            // Precondition (guaranteed by `Game.tilemap_interleave_supported`,
            // the only gate that passes this fn to `renderWithLayerHook`):
            // `LayerEnum` is a genuine config-bearing enum, so `layer.config()`
            // below is sound. Asserted locally so the safety is obvious here.
            comptime std.debug.assert(@typeInfo(LayerEnum) == .@"enum" and @hasDecl(LayerEnum, "config"));
            // Tilemaps are world-space; `worldLayerFromName` already filters
            // screen-space bindings, but guard here too so a screen-layer
            // hook (fired outside the camera transform) never draws terrain.
            if (layer.config().space != .world) return;
            if (self.tilemaps.count() == 0) return;

            // Cull to THIS active camera's visible world rect (the hook fires
            // once per active camera — split-screen views each get their own).
            const cull = cameraCullRect(self, cam);

            var it = self.tilemaps.iterator();
            while (it.next()) |e| {
                const entity = e.key_ptr.*;
                const rt = e.value_ptr.*;
                // A component stripped via generic `removeComponent` leaves a
                // side-table ghost; skip it (the background pass reaps it).
                const comp = self.ecs_backend.getComponent(entity, Tilemap) orelse continue;
                const off = tilemapWorldOffset(self, entity, rt);
                var i: usize = 0;
                while (i < rt.layerCount()) : (i += 1) {
                    const bound = resolveBinding(comp.layer_bindings, rt.layerName(i)) orelse continue;
                    if (bound != layer) continue;
                    rt.drawLayerAt(i, 0, 0, off.x, off.y, cull.start_x, cull.start_y, cull.width, cull.height);
                }
            }
        }

        /// Free + drop side-table runtimes whose entity no longer carries a
        /// `Tilemap` in the active ECS (generic `removeComponent`).
        /// Restart-on-remove keeps it iterator-safe and alloc-free; ghosts
        /// are rare so this stays ~O(n).
        ///
        /// **Assumes a single active world (C1 / #704).** The table is
        /// Game-global, so "not `Tilemap`-bearing in the active ECS" cannot
        /// distinguish "component was removed" (correctly reaped) from
        /// "entity belongs to a *shelved* world" (must be preserved). Under a
        /// raw world swap this reap would DESTRUCT a shelved world's runtime,
        /// and switching back would leave a `Tilemap` component with no
        /// runtime (draws nothing). That aliasing is inherent to the
        /// single-table design and the core motivation for per-world scoping;
        /// it is safe for minimal-T2 (single world; `resetEcsBackend` clears
        /// the table on scene swap / load). Tracked in #704.
        fn reapGhostTilemaps(self: *Game) void {
            reap: while (true) {
                var it = self.tilemaps.iterator();
                while (it.next()) |e| {
                    if (!self.ecs_backend.hasComponent(e.key_ptr.*, Tilemap)) {
                        const rt = e.value_ptr.*;
                        _ = self.tilemaps.remove(e.key_ptr.*);
                        rt.deinit();
                        self.allocator.destroy(rt);
                        continue :reap;
                    }
                }
                break;
            }
        }

        /// The renderer's LOGICAL screen height — the same value sprites are
        /// flipped against (`GfxRendererWith.screen_height`, set via
        /// `setScreenHeight`). Only consulted for the `.up` flip; `.down` is
        /// the identity so the value is unused there.
        fn tilemapScreenHeight(self: *Game) f32 {
            if (comptime @hasField(@TypeOf(self.renderer.*), "screen_height")) {
                return self.renderer.screen_height;
            }
            return 0;
        }

        /// Test/introspection accessor: the decoded-map runtime for an
        /// entity, or null. Returns `void`-typed `null` on stub renderers.
        pub fn tilemapRuntime(self: *Game, entity: Entity) ?*Runtime {
            if (comptime !supported) return null;
            return self.tilemaps.get(entity);
        }

        /// Free every tilemap runtime but keep the (empty) side table
        /// usable. Called on ECS reset (scene swap / `loadGameState`),
        /// where every tilemap entity id is invalidated but the map itself
        /// is reused for the incoming entities.
        pub fn clearTilemaps(self: *Game) void {
            if (comptime !supported) return;
            var it = self.tilemaps.iterator();
            while (it.next()) |e| {
                e.value_ptr.*.deinit();
                self.allocator.destroy(e.value_ptr.*);
            }
            self.tilemaps.clearRetainingCapacity();
        }

        /// Free every tilemap runtime + the side table. Called from the
        /// lifecycle mixin's `deinit`.
        pub fn deinitTilemaps(self: *Game) void {
            if (comptime !supported) return;
            clearTilemaps(self);
            self.tilemaps.deinit();
        }
    };
}
