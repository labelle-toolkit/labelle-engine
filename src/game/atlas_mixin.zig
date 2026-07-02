/// Atlas + streaming-asset mixin — texture/atlas loading, the Asset
/// Streaming RFC (#437) deferred-load shims (images, audio, fonts), atlas
/// sprite lookup, and per-frame `sprite_name → source_rect` resolution.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. Methods
/// gated on renderer capability (`loadTexture` / `loadTextureFromMemory`)
/// are exposed as `pub const X = if (cap) Ximpl else @compileError(...)`
/// in `game.zig`, exactly as before — this mixin supplies the `*Impl`
/// bodies plus the always-available helpers.
const std = @import("std");
const atlas_mod = @import("../atlas.zig");
const assets_mod = @import("../assets/mod.zig");

/// Returns the atlas/asset management mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Sprite = Game.SpriteComp;

    const has_atlas_sprite_fields = @hasField(Sprite, "source_rect") and @hasField(Sprite, "texture") and @hasField(Sprite, "sprite_name");

    return struct {
        // ── Atlas ─────────────────────────────────────────────────

        pub fn loadAtlasImpl(self: *Game, name: []const u8, json_path: [:0]const u8, texture_path: [:0]const u8) !void {
            const tex_id = try self.renderer.loadTexture(texture_path);
            // Convert renderer's TextureId (enum/opaque) to u32 for engine storage
            const id: u32 = if (@typeInfo(@TypeOf(tex_id)) == .@"enum")
                @intFromEnum(tex_id)
            else
                tex_id;
            const dims = queryTextureDims(self, tex_id);
            try self.atlas_manager.loadAtlasFromJson(name, json_path, id, dims);
        }

        pub fn loadAtlasComptimeImpl(self: *Game, name: []const u8, comptime sprites: []const atlas_mod.SpriteData, texture_path: [:0]const u8) !void {
            const tex_id = try self.renderer.loadTexture(texture_path);
            const id: u32 = if (@typeInfo(@TypeOf(tex_id)) == .@"enum")
                @intFromEnum(tex_id)
            else
                tex_id;
            try self.atlas_manager.loadAtlasComptime(name, sprites, id);
        }

        pub fn loadAtlasFromMemoryImpl(self: *Game, name: []const u8, json_content: []const u8, image_data: []const u8, file_type: [:0]const u8) !void {
            try self.registerAtlasFromMemory(name, json_content, image_data, file_type);
            _ = try self.loadAtlasIfNeeded(name);
        }

        /// Upload a standalone texture from an in-memory image blob, returning
        /// its renderer texture id as a plain `u32` (render-mesh seam companion,
        /// labelle-gfx#290). Forwards straight to the renderer's
        /// `loadTextureFromMemory` (the gfx `GfxRenderer` → `RetainedEngine` →
        /// backend decode+upload path) and normalises the returned `TextureId`
        /// enum/int to `u32` so the caller can hand it back to `game.drawMesh`.
        /// Same `TextureId` → `u32` conversion the atlas loaders use.
        pub fn loadTextureFromMemoryU32(self: *Game, file_type: [:0]const u8, data: []const u8) !u32 {
            const tex_id = try self.renderer.loadTextureFromMemory(file_type, data);
            return if (@typeInfo(@TypeOf(tex_id)) == .@"enum") @intFromEnum(tex_id) else tex_id;
        }

        pub fn registerAtlasFromMemoryImpl(self: *Game, name: []const u8, json_content: []const u8, image_data: []const u8, file_type: [:0]const u8) !void {
            // Keep the legacy TextureManager side-effects: parse JSON
            // eagerly so `findSprite` works after the catalog finishes
            // uploading, stash the `PendingImage` so `markPendingLoaded`
            // can derive the texture scale against the JSON's meta.size
            // once the shim learns the actual dims.
            try self.atlas_manager.registerPendingAtlas(name, json_content, image_data, file_type);

            // Mirror onto the catalog. Double-registration (e.g. when
            // the assembler's scene manifest code already registered
            // the same name on the catalog) is not an error: the
            // catalog is the source of truth for the PNG bytes, and
            // re-registering identical bytes is a no-op from the
            // loader's perspective.
            self.assets.register(name, .image, file_type, image_data) catch |err| switch (err) {
                error.AssetAlreadyRegistered => {},
                else => return err,
            };
        }

        pub fn loadAtlasIfNeededImpl(self: *Game, name: []const u8) !bool {
            const atlas = self.atlas_manager.getAtlasMut(name) orelse return error.AtlasNotFound;
            if (atlas.isLoaded()) return false;

            // Bump refcount on the catalog. First acquire on a fresh
            // entry enqueues the decode; subsequent acquires just pin
            // the refcount so the zombie-drop path in `pump()` can't
            // rewind us while we are waiting for the upload to land.
            //
            // `errdefer release` guarantees the shim returns the
            // refcount on every failure path (lastError, missing
            // entry, wrong asset kind, markPendingLoaded error, …).
            // Without it, a failed load leaks a phantom refcount that
            // keeps the entry acquired forever — and since `acquire`
            // only re-enqueues on the 0→1 transition, a retry after
            // failure would just bump the leak without re-triggering
            // a decode.
            _ = try self.assets.acquire(name);
            // Mirror of the acquire above. Runs on any error path so
            // the catalog refcount stays consistent. On the happy path
            // — when `markPendingLoaded` succeeds and we `return true`
            // — the defer does NOT fire, intentionally leaving the
            // refcount at 1 to keep the loaded entry pinned in the
            // catalog (prevents the zombie-drop path from rewinding
            // the state back to `.registered` if Phase 2 ever calls
            // `release` for an unrelated scene transition).
            errdefer self.assets.release(name);

            // Busy-pump until the decode + upload complete OR the
            // catalog surfaces an error via `lastError`. Same-thread
            // async-under-the-hood, sync-at-the-surface: no visible
            // UX change from the legacy path that called
            // `renderer.loadTextureFromMemory` directly on the main
            // thread.
            //
            // Known limitation (pre-existing from #450's acquire
            // design): if the request ring was full when `acquire`
            // fired, the work request is dropped, state stays
            // `.registered`, refcount is bumped, and neither `pump()`
            // nor any other layer re-enqueues it. This loop would
            // then spin forever. Not reachable on current workloads
            // (64-slot ring vs single-digit asset counts), but a
            // follow-up should either make `acquire` fail on
            // QueueFull or add retry logic to `pump()`.
            while (!self.assets.isReady(name)) {
                if (self.assets.lastError(name)) |err| {
                    // Rewind .failed → .registered so the next
                    // loadAtlasIfNeeded retries the decode instead of
                    // returning the stale error forever. Without this,
                    // any decode/upload failure becomes permanent: the
                    // errdefer above drops refcount to 0, but state
                    // stays .failed, and `acquire` only re-enqueues
                    // from .registered. So the retry would hit the
                    // already-set lastError and immediately return
                    // the old error without re-triggering work — a
                    // regression from the legacy direct-decode path
                    // which simply re-attempted the call.
                    self.assets.resetFailed(name);
                    return err;
                }
                self.assets.pump();
                // Don't bridge here — `loadAtlasIfNeeded` (the shim
                // calling this loop) does its own `markPendingLoaded`
                // after the asset reaches .ready, and double-bridging
                // returns AtlasNotPending. The main tick loop catches
                // late-uploaded atlases for the eager-fallback path.
                std.Thread.yield() catch {};
            }

            // Upload done — the catalog has a valid `UploadedResource`
            // for the entry. Pull the backend-assigned texture handle
            // out and seed the TextureManager's `RuntimeAtlas` so the
            // rest of the engine (sprite cache, `findSprite`, etc.)
            // can look the texture up through the legacy path.
            const entry = self.assets.entries.getPtr(name) orelse return error.AtlasNotFound;
            const resource = entry.resource orelse return error.AssetNotReady;
            const id: u32 = switch (resource) {
                .image => |t| t,
                else => return error.WrongAssetKind,
            };

            // The catalog-managed upload path does NOT populate the
            // renderer's texture side-table — the assembler-generated
            // adapter uploads directly to the GPU backend, bypassing
            // `renderer.loadTextureFromMemory`. `getTextureInfo` would
            // therefore return null for catalog-uploaded textures, so
            // `markPendingLoaded` gets `null` dims and falls back to
            // scale=1.0. Matches the legacy fallback behavior when the
            // renderer doesn't expose `getTextureInfo` at all. Atlases
            // that shipped a downscaled PNG and relied on automatic
            // texture_scale derivation will need an explicit workflow
            // once Phase 2 takes over the cold-start path — out of
            // scope for #443.
            try self.atlas_manager.markPendingLoaded(name, id, null);
            return true;
        }

        // ── Audio asset shims (Phase 4 of Asset Streaming RFC, #447) ──

        pub fn registerSoundFromMemory(self: *Game, name: []const u8, file_type: [:0]const u8, audio_data: []const u8) !void {
            self.assets.register(name, .audio, file_type, audio_data) catch |err| switch (err) {
                error.AssetAlreadyRegistered => {},
                else => return err,
            };
        }

        pub fn loadSoundFromMemory(self: *Game, name: []const u8, file_type: [:0]const u8, audio_data: []const u8) !void {
            try self.registerSoundFromMemory(name, file_type, audio_data);
            _ = try self.loadSoundIfNeeded(name);
        }

        pub fn loadAssetIfNeededInternal(self: *Game, name: []const u8) !bool {
            if (self.assets.isReady(name)) return false;
            _ = try self.assets.acquire(name);
            errdefer self.assets.release(name);
            while (!self.assets.isReady(name)) {
                if (self.assets.lastError(name)) |err| {
                    self.assets.resetFailed(name);
                    return err;
                }
                self.assets.pump();
                std.Thread.yield() catch {};
            }
            return true;
        }

        pub fn loadSoundIfNeeded(self: *Game, name: []const u8) !bool {
            return loadAssetIfNeededInternal(self, name);
        }

        // ── Font asset shims (Phase 4 of Asset Streaming RFC, #448) ──

        pub fn registerFontFromMemory(
            self: *Game,
            name: []const u8,
            file_type: [:0]const u8,
            font_data: []const u8,
            params: *const assets_mod.font_loader.FontBakeParams,
        ) !void {
            self.assets.registerFont(name, file_type, font_data, params) catch |err| switch (err) {
                error.AssetAlreadyRegistered => {},
                else => return err,
            };
        }

        pub fn loadFontFromMemory(
            self: *Game,
            name: []const u8,
            file_type: [:0]const u8,
            font_data: []const u8,
            params: *const assets_mod.font_loader.FontBakeParams,
        ) !void {
            try self.registerFontFromMemory(name, file_type, font_data, params);
            _ = try self.loadFontIfNeeded(name);
        }

        pub fn loadFontIfNeeded(self: *Game, name: []const u8) !bool {
            return loadAssetIfNeededInternal(self, name);
        }

        pub fn isAtlasLoaded(self: *Game, name: []const u8) bool {
            const atlas = self.atlas_manager.getAtlas(name) orelse return false;
            return atlas.isLoaded();
        }

        pub fn queryTextureDims(self: *Game, tex_id: anytype) ?atlas_mod.TextureManager.TextureDims {
            if (!@hasDecl(@TypeOf(self.renderer.*), "getTextureInfo")) return null;
            const info = self.renderer.getTextureInfo(tex_id) orelse return null;
            return .{
                .width = clampToU32(info.width),
                .height = clampToU32(info.height),
            };
        }

        pub fn clampToU32(v: f32) u32 {
            if (!std.math.isFinite(v) or v <= 0) return 0;
            // `@floatFromInt(maxInt(u32))` rounds *up* to 2^32 in f32
            // because the f32 mantissa is only 24 bits, so comparing
            // against it would let `@intFromFloat` see exactly 2^32 —
            // one above the u32 range, triggering UB / safety panic.
            // The largest f32 value strictly less than 2^32 is
            // 4_294_967_040 (= 2^32 - 2^8). Clamp to that.
            const max_safe: f32 = 4_294_967_040.0;
            if (v >= max_safe) return std.math.maxInt(u32);
            return @intFromFloat(v);
        }

        pub fn getTextureManager(self: *Game) *atlas_mod.TextureManager {
            return &self.atlas_manager;
        }

        /// Look up a sprite by name across all loaded atlases (uncached).
        pub fn findSprite(self: *const Game, sprite_name: []const u8) ?atlas_mod.FindSpriteResult {
            return self.atlas_manager.findSprite(sprite_name);
        }

        /// Look up a sprite for an entity using the per-entity cache.
        /// Returns cached result when atlas version and sprite name haven't changed.
        pub fn findSpriteCached(self: *Game, entity_id: u32, sprite_name: []const u8) ?atlas_mod.FindSpriteResult {
            return self.active_world.sprite_cache.lookup(entity_id, sprite_name, &self.atlas_manager);
        }

        /// Unload an atlas by name, freeing sprite data.
        pub fn unloadAtlas(self: *Game, name: []const u8) void {
            self.atlas_manager.unloadAtlas(name);
        }

        // ── Atlas Resolution ──────────────────────────────────────

        /// Resolve sprite_name → source_rect + texture for all atlas sprites.
        /// Called automatically before renderer sync each frame.
        /// Only marks entities dirty on cache misses (sprite name or atlas version changed).
        pub fn resolveAtlasSprites(self: *Game) void {
            if (!has_atlas_sprite_fields) return;
            if (self.atlas_manager.atlasCount() == 0) return;

            var v = self.ecs_backend.view(.{Sprite}, .{});
            defer v.deinit();
            while (v.next()) |entity| {
                const sprite = self.ecs_backend.getComponent(entity, Sprite).?;
                if (sprite.sprite_name.len == 0) continue;

                const misses_before = self.active_world.sprite_cache.misses;
                if (self.active_world.sprite_cache.lookup(@intCast(entity), sprite.sprite_name, &self.atlas_manager)) |result| {
                    // Only update and mark dirty on cache miss (new sprite or atlas changed)
                    if (self.active_world.sprite_cache.misses != misses_before) {
                        sprite.texture = @enumFromInt(result.texture_id);
                        // The atlas data is in the JSON's logical pixel
                        // grid. `texture_scale_*` maps that grid onto the
                        // actual texture pixels — `1.0` for the common
                        // case, `< 1` when the user shipped a downscaled
                        // PNG without re-running TexturePacker.
                        //
                        // Two distinct mappings are needed:
                        //
                        //   * The PHYSICAL atlas footprint (`sprite.x/y`,
                        //     `sprite.width/height`) is in texture-pixel
                        //     coordinates regardless of rotation. Each
                        //     axis scales independently, so x/width go
                        //     through `texture_scale_x` and y/height go
                        //     through `texture_scale_y`.
                        //
                        //   * The DISPLAY dimensions (`getWidth/Height`)
                        //     swap when the sprite was rotated 90° in the
                        //     atlas — that's the on-screen size. They
                        //     stay un-scaled.
                        //
                        // Mixing the two (multiplying `getWidth()` by
                        // `texture_scale_x`) is wrong for rotated sprites
                        // because `getWidth()` returns the post-rotation
                        // height — a vertical dimension scaled by a
                        // horizontal factor.
                        const phys_x: f32 = @floatFromInt(result.sprite.x);
                        const phys_y: f32 = @floatFromInt(result.sprite.y);
                        const phys_w: f32 = @floatFromInt(result.sprite.width);
                        const phys_h: f32 = @floatFromInt(result.sprite.height);
                        const display_w: f32 = @floatFromInt(result.sprite.getWidth());
                        const display_h: f32 = @floatFromInt(result.sprite.getHeight());
                        const scaled_w = phys_w * result.texture_scale_x;
                        const scaled_h = phys_h * result.texture_scale_y;
                        sprite.source_rect = .{
                            .x = phys_x * result.texture_scale_x,
                            .y = phys_y * result.texture_scale_y,
                            // `source_rect.width/height` are in the same
                            // post-rotation orientation that the renderer
                            // expects (matching `getWidth/Height`),
                            // so swap when the sprite was rotated.
                            .width = if (result.sprite.rotated) scaled_h else scaled_w,
                            .height = if (result.sprite.rotated) scaled_w else scaled_h,
                            .display_width = display_w,
                            .display_height = display_h,
                        };
                        self.renderer.markVisualDirty(entity);
                    }
                }
            }
        }
    };
}
