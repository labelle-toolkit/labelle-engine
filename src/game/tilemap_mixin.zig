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
const tilemap_runtime = @import("../tilemap_runtime.zig");

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Tilemap = Game.TilemapComp;
    const supported = Game.tilemap_supported;
    const Runtime = Game.TilemapRuntimeType;

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

        /// The post-sprite tilemap pass: after the entity render pass, draw
        /// every `Tilemap` entity's decoded map at its world `Position`.
        /// The engine owns pass ordering here (entities first, tilemaps
        /// after); gfx's `RetainedEngine` is untouched.
        ///
        /// T2 runs the pass in screen space (`camera_* = 0`): tiles draw at
        /// `world_pos - 0`. Aligning with a moving camera transform and
        /// Z-interleaving with sprite layers are deferred to T3 — the gfx
        /// `drawAllLayers` seam already accepts the camera offset for when
        /// that lands.
        pub fn renderTilemaps(self: *Game) void {
            if (comptime !supported) return;
            var it = self.tilemaps.iterator();
            while (it.next()) |e| {
                const pos = self.getWorldPosition(e.key_ptr.*);
                e.value_ptr.*.draw(0, 0, pos.x, pos.y, null, null);
            }
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
