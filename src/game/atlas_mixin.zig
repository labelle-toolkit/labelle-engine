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
const core = @import("labelle-core");
const assets_mod = @import("../assets/mod.zig");

/// The rect type a renderer's `Sprite.source_rect` holds, whether the field
/// is declared as `?SourceRect` (the common case) or as the rect directly.
///
/// A renderer is free to do either — `Sprite` is the renderer's own type and
/// the engine only requires the field to exist — so unwrapping the optional
/// unconditionally would refuse to compile against a perfectly valid
/// renderer (`test/asset_streaming_shim_test.zig` declares it non-optional).
pub fn SourceRectOf(comptime SpriteType: type) type {
    const Field = @FieldType(SpriteType, "source_rect");
    return switch (@typeInfo(Field)) {
        .optional => |o| o.child,
        else => Field,
    };
}

/// Map a resolved atlas lookup onto the renderer's `source_rect` type.
///
/// Split out of `resolveAtlasSprites` because this mapping is where the
/// atlas JSON stops being data and becomes geometry, and it is the seam
/// that silently went unread: `atlas.zig` parsed `spriteSourceSize` into
/// `offset_x/offset_y` and for a long time NOTHING read those fields
/// back, so trimmed frames were drawn centred on their own silhouette.
/// A pure function over a `FindSpriteResult` can be tested without a
/// renderer, an ECS, or a loaded atlas — which is what makes that class
/// of bug catchable.
///
/// Two distinct coordinate mappings are involved:
///
///   * The PHYSICAL atlas footprint (`sprite.x/y`, `sprite.width/height`)
///     is in texture-pixel coordinates regardless of rotation, so it is
///     scaled per-axis by `texture_scale_x/y` — which is `1.0` in the
///     common case and `< 1` when the user shipped a downscaled PNG
///     without re-running TexturePacker.
///   * The DISPLAY dimensions (`getWidth/Height`) are design-space and
///     stay UN-scaled; they swap when the sprite was rotated 90° in the
///     atlas. Mixing the two (multiplying `getWidth()` by
///     `texture_scale_x`) is wrong for a rotated sprite, because
///     `getWidth()` then returns a vertical dimension.
///
/// The trim fields are design-space like `display_*`. They are gated on
/// `@hasField` so this still compiles against a gfx whose `SourceRect`
/// predates them (the offsets are simply not applied there — the
/// pre-fix behaviour).
pub fn sourceRectFor(comptime SourceRect: type, result: atlas_mod.FindSpriteResult) SourceRect {
    const phys_x: f32 = @floatFromInt(result.sprite.x);
    const phys_y: f32 = @floatFromInt(result.sprite.y);
    const phys_w: f32 = @floatFromInt(result.sprite.width);
    const phys_h: f32 = @floatFromInt(result.sprite.height);
    const scaled_w = phys_w * result.texture_scale_x;
    const scaled_h = phys_h * result.texture_scale_y;

    var rect: SourceRect = .{
        .x = phys_x * result.texture_scale_x,
        .y = phys_y * result.texture_scale_y,
        // Same post-rotation orientation the renderer expects (matching
        // `getWidth/Height`), so swap when the sprite was rotated.
        .width = if (result.sprite.rotated) scaled_h else scaled_w,
        .height = if (result.sprite.rotated) scaled_w else scaled_h,
        .display_width = @floatFromInt(result.sprite.getWidth()),
        .display_height = @floatFromInt(result.sprite.getHeight()),
    };

    if (comptime @hasField(SourceRect, "trim_offset_x")) {
        // A trimmed frame's kept pixels sit at `offset_x/offset_y` inside
        // the canvas the art was authored on, and the renderer needs both
        // to pivot on that canvas instead of on the cropped silhouette.
        //
        // Rotated frames are left at zero (the pre-fix geometry).
        // `offset_*` is expressed in the UNROTATED canvas, so it would
        // have to be transformed for the rotation rather than copied —
        // but there is nothing to transform it FOR: no renderer in the
        // toolkit rotates a frame's UVs. `width`/`height` are swapped
        // below so the quad has the right shape, and the pixels are then
        // drawn unrotated, which is wrong independently of trimming. So
        // atlas rotation is unsupported end to end, and inventing a trim
        // mapping for it would be untestable guesswork. `labelle pack`
        // never rotates; if a rotating packer is ever supported, the UV
        // rotation and this mapping have to land together.
        if (!result.sprite.rotated) {
            rect.trim_offset_x = @floatFromInt(result.sprite.offset_x);
            rect.trim_offset_y = @floatFromInt(result.sprite.offset_y);
            rect.canvas_width = @floatFromInt(result.sprite.getSourceWidth());
            rect.canvas_height = @floatFromInt(result.sprite.getSourceHeight());
        }
    }
    return rect;
}

/// Returns the atlas/asset management mixin for a given Game type.
/// Convert a caller's texture handle to whatever type a renderer seam
/// takes. Both directions are real: a renderer may key on an ENUM
/// (labelle-gfx's `TextureId`) or a plain INTEGER (the tilemap
/// renderers in `test/tilemap_test.zig` use `unloadTexture(id: u32)`),
/// and a caller may hold either the engine's public `u32` or an
/// already-typed handle.
///
/// The earlier version assumed the target was always an enum and did
/// `@enumFromInt` unconditionally, which fails to compile against an
/// integer-handle renderer — `@enumFromInt` requires an enum result.
pub fn normalizeHandle(comptime Target: type, tex_id: anytype) Target {
    const src_is_int = switch (@typeInfo(@TypeOf(tex_id))) {
        .int, .comptime_int => true,
        else => false,
    };
    return switch (@typeInfo(Target)) {
        .@"enum" => if (src_is_int) @enumFromInt(tex_id) else tex_id,
        .int => if (src_is_int) @intCast(tex_id) else @intFromEnum(tex_id),
        else => tex_id,
    };
}

/// One retained direct upload (#820): the arguments `loadTextureFromMemory`
/// was called with, copied onto the game allocator so the engine can replay
/// the upload under the same id after a GPU surface restore. Freed by
/// `unloadTexture` / `Game.deinit`.
pub const DirectTexture = struct {
    file_type: [:0]const u8,
    bytes: []const u8,
};

/// `Game.direct_textures` — public `u32` handle → retained upload.
pub const DirectTextureStore = std.AutoHashMapUnmanaged(u32, DirectTexture);

pub fn Mixin(comptime Game: type) type {
    const Sprite = Game.SpriteComp;
    // The renderer plugin behind `game.renderer` (a `*RenderImpl`), named
    // once here so the comptime gates below don't need a `self`.
    const Renderer = @typeInfo(@FieldType(Game, "renderer")).pointer.child;

    // The gfx re-arm seam for minted keys (labelle-gfx#345): both decls
    // or neither — the engine never invalidates what it cannot re-upload
    // (that would turn a resume into a permanently blank texture) and
    // never retains bytes it cannot replay (wasted memory). Soft gate, so
    // the engine keeps compiling against an older gfx and degrades to the
    // v2.13.0 contract there.
    const tracks = @hasDecl(Renderer, "invalidateTexture") and
        @hasDecl(Renderer, "reuploadTextureFromMemory");

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
        ///
        /// ## Surface-loss contract (#820)
        ///
        /// This is a DIRECT upload: it bypasses the asset catalog. On a
        /// renderer with the gfx re-arm seam (`Game.tracks_direct_uploads`,
        /// gfx >= 1.31) the ENGINE carries it across a GPU surface loss
        /// (Android TERM_WINDOW / INIT_WINDOW): it retains a copy of
        /// `data` + `file_type`, drops the dead handle on `surfaceLost`
        /// (no destroy — the context is gone) and re-decodes + re-uploads
        /// on `surfaceRestored` under the SAME `u32`, before
        /// `engine__surface_restored` is delivered. The id you hold stays
        /// valid; nothing to do on either event. The retained copy is freed
        /// by `unloadTexture` / `Game.deinit`, so a game that wants the
        /// memory back releases the texture — the copy is the price of a
        /// stable id.
        ///
        /// What the engine does NOT track is anything you derived from the
        /// texture by BACKEND handle and lent elsewhere — e.g. a
        /// `game.nativeTextureId` → bgfx handle registered with the imgui
        /// bridge (`registerTexture`). The re-upload puts a NEW backend
        /// texture behind the same engine id, so that lend goes stale: in
        /// a (synchronous) `engine__surface_lost` hook `unregisterTexture`
        /// it — the imgui bridge clears borrowed slots itself on device
        /// loss, so a stale registration is at best invalid and at worst
        /// names its recycled font slot — and after
        /// `engine__surface_restored` resolve `game.nativeTextureId(id)`
        /// again and re-register. Do NOT `game.unloadTexture` the id on
        /// loss; that forfeits the tracking.
        ///
        /// On a renderer WITHOUT the seam (`tracks_direct_uploads == false`)
        /// the v2.13.0 contract stands: the texture dies with the surface;
        /// release it with `game.unloadTexture` from an
        /// `engine__surface_lost` hook (handles are still alive there) and
        /// upload again after `engine__surface_restored`; never release
        /// through a handle after restore, since the backend recycles slots
        /// and the stale handle by then names one of the catalog's
        /// re-uploaded textures. See `lifecycle_mixin.surfaceLost`.
        pub fn loadTextureFromMemoryU32(self: *Game, file_type: [:0]const u8, data: []const u8) !u32 {
            const tex_id = try self.renderer.loadTextureFromMemory(file_type, data);
            const id: u32 = if (@typeInfo(@TypeOf(tex_id)) == .@"enum") @intFromEnum(tex_id) else tex_id;
            if (comptime tracks) {
                retainDirectTexture(self, id, file_type, data) catch |err| {
                    // Either the upload is tracked or the load fails: a
                    // texture that silently would NOT come back after a
                    // resume is the exact ambiguity this seam removes.
                    self.renderer.unloadTexture(tex_id);
                    return err;
                };
            }
            return id;
        }

        // ── Direct-upload lifecycle across surface loss (#820) ────────

        pub const tracks_direct_uploads = tracks;

        fn retainDirectTexture(self: *Game, id: u32, file_type: [:0]const u8, data: []const u8) !void {
            const ft = try self.allocator.dupeZ(u8, file_type);
            errdefer self.allocator.free(ft);
            const bytes = try self.allocator.dupe(u8, data);
            errdefer self.allocator.free(bytes);
            // A renderer that hands out the same key twice would leak the
            // first copy — replace, freeing it, rather than trust it.
            if (self.direct_textures.fetchRemove(id)) |old| freeDirectTexture(self, old.value);
            try self.direct_textures.put(self.allocator, id, .{ .file_type = ft, .bytes = bytes });
        }

        fn freeDirectTexture(self: *Game, dt: DirectTexture) void {
            self.allocator.free(dt.file_type);
            self.allocator.free(dt.bytes);
        }

        /// `surfaceLost` half: tell the renderer every retained id's
        /// backend handle is dead. NOT `unloadTexture` — the GPU context is
        /// gone (destroying on it is UB) and after re-init the backend
        /// recycles slot numbers, so a late free through the stale handle
        /// kills whichever live texture landed in that slot. The engine ids
        /// and the retained bytes are untouched. No-op without the seam.
        pub fn invalidateDirectTextures(self: *Game) void {
            if (comptime !tracks) return;
            const Param = @typeInfo(@TypeOf(Renderer.invalidateTexture)).@"fn".params[1].type.?;
            var it = self.direct_textures.keyIterator();
            while (it.next()) |id| {
                self.renderer.invalidateTexture(normalizeHandle(Param, id.*));
            }
        }

        /// `surfaceRestored` half: re-decode + re-upload every retained
        /// direct upload under its ORIGINAL engine id. A failed re-upload
        /// is logged and the entry kept (the id then draws nothing, exactly
        /// like an invalidated key, until the game releases it); a stray
        /// unload in between (`TextureNotRegistered`) is impossible here
        /// because `unloadTexture` drops the retained entry too. No-op
        /// without the seam.
        pub fn reuploadDirectTextures(self: *Game) void {
            if (comptime !tracks) return;
            const Param = @typeInfo(@TypeOf(Renderer.reuploadTextureFromMemory)).@"fn".params[1].type.?;
            var it = self.direct_textures.iterator();
            var ok: usize = 0;
            while (it.next()) |entry| {
                const dt = entry.value_ptr.*;
                self.renderer.reuploadTextureFromMemory(normalizeHandle(Param, entry.key_ptr.*), dt.file_type, dt.bytes) catch |err| {
                    std.log.warn(
                        "surface_restored: re-upload of direct texture {d} ({s}, {d} bytes) failed: {s}",
                        .{ entry.key_ptr.*, dt.file_type, dt.bytes.len, @errorName(err) },
                    );
                    continue;
                };
                ok += 1;
            }
            if (self.direct_textures.count() > 0) {
                std.log.info("surface_restored: re-uploaded {d}/{d} direct textures under their original ids", .{ ok, self.direct_textures.count() });
            }
        }

        /// `Game.deinit` half: free the retained copies. The renderer frees
        /// the GPU side in its own teardown.
        pub fn deinitDirectTextures(self: *Game) void {
            var it = self.direct_textures.valueIterator();
            while (it.next()) |dt| freeDirectTexture(self, dt.*);
            self.direct_textures.deinit(self.allocator);
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

            // `markPendingLoaded` gets `null` dims, so texture_scale falls
            // back to 1.0. Atlases that shipped a downscaled PNG and relied
            // on automatic scale derivation need an explicit workflow — out
            // of scope for #443.
            //
            // STALE UNTIL 2026-08: this comment used to claim the catalog
            // path does not populate the renderer's texture side-table, and
            // that `getTextureInfo` therefore returns null for
            // catalog-uploaded textures. That stopped being true with
            // labelle-gfx#248: the assembler-emitted `ImageBackendAdapter`
            // calls `renderer.registerCatalogTexture(handle, tex)`
            // immediately after `uploadTexture`, which puts the handle in
            // the very map `getTextureInfo` / `nativeTextureId` read.
            //
            // The claim outlived the fix and misled a reviewer of #814 into
            // reporting that the backend-handle seam cannot resolve catalog
            // handles. It can. Passing `null` here is now a missed
            // opportunity rather than a necessity — deriving real dims for
            // catalog atlases is a behaviour change, so it is left as
            // follow-up rather than folded into this PR.
            try self.atlas_manager.markPendingLoaded(name, id, null);
            return true;
        }

        // ── Standalone image asset shims (#831) ──
        //
        // The `.image` counterpart to the atlas / sound / font pairs, for
        // a LOOSE PNG declared as `.{ .name = "portrait", .image = "…" }`
        // (labelle-assembler#676) and drawn by the standalone `Image`
        // component (`src/image_component.zig`).
        //
        // Why these exist even though `AssetCatalog.register` + `acquire`
        // already "work": every other resource kind honours `lazy = false`
        // by loading BLOCKING at init, so the asset is resident before the
        // first frame is drawn. `acquire` alone only *starts* the worker
        // decode; the per-tick `pump()` finishes it, which means an eager
        // image can still be missing on frame 0 — `Image` skips rendering
        // while its asset is not ready. That asymmetry is issue #831.
        //
        // Deliberately NOT gated on the renderer's `loadTextureFromMemory`
        // (unlike the atlas shims): the catalog's image loader uploads
        // through the injected `ImageBackend` function pointers, never
        // through the renderer seam, so these compile against any renderer
        // — the same way the sound and font shims do.

        /// Register a standalone image's bytes with the catalog WITHOUT
        /// decoding them — the `lazy = true` half of the pair, and the
        /// image counterpart to `registerSoundFromMemory`.
        ///
        /// `file_type` is the extension the backend's `decodeImage` is
        /// written against, carrying its leading dot (`".png"`) — the
        /// spelling `registerAtlasFromMemory` already passes through.
        ///
        /// `name`, `file_type` and `image_data` are BORROWED under the
        /// catalog's `@embedFile` lifetime contract: all three must outlive
        /// the entry. `AssetAlreadyRegistered` is swallowed, matching every
        /// other `register*FromMemory` shim — a name a scene manifest
        /// already registered is not a hard failure — but ONLY when the
        /// entry holding that name is itself an image; a collision with a
        /// sound or font is `error.WrongAssetKind`, never a silent alias.
        pub fn registerImageFromMemory(self: *Game, name: []const u8, file_type: [:0]const u8, image_data: []const u8) !void {
            self.assets.register(name, .image, file_type, image_data) catch |err| switch (err) {
                // Tolerating the duplicate is only correct when the entry
                // that already owns the name IS an image. If a sound or a
                // font got there first, swallowing the error would alias
                // two resources onto one catalog slot: the kind-agnostic
                // loader would happily decode the WAV/TTF, this shim would
                // report success, and the `Image` component would then find
                // no `.image` handle and silently draw nothing. Surface the
                // collision instead — same error the atlas shim already
                // raises one step later when `entry.resource` turns out not
                // to be an image.
                error.AssetAlreadyRegistered => try requireImageEntry(self, name),
                else => return err,
            };
        }

        /// `error.WrongAssetKind` unless `name` is registered under
        /// `LoaderKind.image`. Shared by the register and load halves so a
        /// resource-name collision fails on BOTH — the lazy arm must not be
        /// able to plant an alias the eager arm later blesses.
        fn requireImageEntry(self: *Game, name: []const u8) !void {
            const entry = self.assets.entries.getPtr(name) orelse return error.AssetNotRegistered;
            if (entry.loader_kind != .image) return error.WrongAssetKind;
        }

        /// Register AND load a standalone image, BLOCKING until the GPU
        /// upload has landed — the `lazy = false` half of the pair, and the
        /// image counterpart to `loadAtlasFromMemory` / `loadSoundFromMemory`
        /// / `loadFontFromMemory`.
        ///
        /// When this returns, `game.assets.isReady(name)` is true and the
        /// entry's `resource.image` holds the backend texture handle the
        /// `Image` render seam reads — so an `Image` entity naming this
        /// asset draws on the very first frame instead of popping in a few
        /// frames later. That first-frame guarantee is the whole point of
        /// this function; `acquire` alone does not provide it.
        pub fn loadImageFromMemory(self: *Game, name: []const u8, file_type: [:0]const u8, image_data: []const u8) !void {
            try self.registerImageFromMemory(name, file_type, image_data);
            _ = try self.loadImageIfNeeded(name);
        }

        /// Block until an already-registered image asset is resident,
        /// returning `true` when this call did the loading and `false` when
        /// it was already `.ready`. The image counterpart to
        /// `loadSoundIfNeeded` / `loadFontIfNeeded`.
        ///
        /// Blocking uses the same mechanism the other kinds do
        /// (`loadAssetIfNeededInternal`), on the calling thread: `acquire`
        /// enqueues the decode on a worker, then this thread pumps the
        /// catalog itself until the upload lands. Exits on ready, on a
        /// decode/upload error, on a dropped enqueue, or immediately while
        /// the GPU surface is down — never spins unbounded.
        ///
        /// `error.WrongAssetKind` if `name` is registered as a sound or a
        /// font: the underlying loader is kind-agnostic and would "load"
        /// it successfully, leaving an `Image` component with nothing to
        /// draw. `error.GpuSurfaceUnavailable` while the surface is lost —
        /// see `loadAssetIfNeededInternal`.
        ///
        /// After the asset reaches `.ready` this also runs the standard
        /// bridge walk. A loose PNG needs no bridging (the `Image` seam
        /// resolves straight off the catalog, and `markPendingLoaded`
        /// simply reports `AtlasNotFound`, which the walk swallows), but a
        /// name that IS a registered pending atlas gets its `texture_id`
        /// wired here rather than one tick later. `bridgeAllReadyImageAssets`
        /// is reused instead of a direct `markPendingLoaded` precisely
        /// because it already encodes the post-load render gate's
        /// all-at-once rule (#638) — binding a gated atlas early from here
        /// would reintroduce the half-bound-manifest window the gate exists
        /// to close.
        pub fn loadImageIfNeeded(self: *Game, name: []const u8) !bool {
            try requireImageEntry(self, name);
            const did_load = try loadAssetIfNeededInternal(self, name);
            self.bridgeAllReadyImageAssets();
            return did_load;
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

            // Surface-loss deadlock guard (#832 review).
            //
            // While the GPU surface is down (`invalidateGpuResources` →
            // `gpu_alive = false`) `pump()` deliberately PARKS a successful
            // image result on the ring rather than uploading into a dead
            // context — see `AssetCatalog.isGpuUploadResult`. The entry
            // therefore never reaches `.ready` and never reaches `.failed`,
            // so the busy-wait below would spin forever.
            //
            // That is not a theoretical window: `surfaceLost` emits
            // `engine__surface_lost` SYNCHRONOUSLY (#820/#823), so a hook
            // that re-registers or re-loads an image runs with the gate
            // already closed. Blocking there wedges `surfaceLost` itself,
            // which means `surfaceRestored` — the only thing that reopens
            // the gate — can never run. The lifecycle contract on
            // `Events.surface_lost` already says it outright: "No new GPU
            // work should run until `surface_restored`." Say so with an
            // error instead of hanging; a hook can retry after
            // `engine__surface_restored`.
            //
            // Only `.image` entries are parked (audio and font uploads
            // don't touch the lost surface and drain normally), so the
            // guard is keyed on the entry's kind rather than applied to
            // every caller of this helper.
            const pending = self.assets.entries.getPtr(name) orelse return error.AssetNotRegistered;
            if (pending.loader_kind == .image and !self.assets.gpu_alive) {
                return error.GpuSurfaceUnavailable;
            }

            _ = try self.assets.acquire(name);
            errdefer self.assets.release(name);

            // Deterministic stuck-decode guard (#831). `acquire` only
            // enqueues a `WorkRequest` on the 0 → 1 refcount transition,
            // and `enqueueDecode` *tolerates* a full request ring: it
            // logs, leaves the state at `.registered`, and nothing
            // re-enqueues it — not `pump()`, not any other layer. The
            // busy-wait below would then spin forever on an asset that
            // will never become ready, with no error to surface.
            //
            // After a successful `acquire` the only state that means "no
            // work is in flight" is `.registered`: `.queued` / `.decoding`
            // are mid-flight, `.ready` returned above, `.failed` is caught
            // by the `lastError` branch. The entry cannot fall BACK to
            // `.registered` inside the loop either — the only path that
            // does that is `pump`'s zombie-drop, which requires refcount 0,
            // and we hold a reference. So one check here is sufficient and
            // needs no per-iteration cost.
            //
            // Not reachable on current workloads (64-slot ring vs.
            // single-digit asset counts per frame), but "the game hangs"
            // is the wrong failure mode for a full queue — a caller can
            // retry an error, it cannot retry a deadlock.
            const acquired = self.assets.entries.getPtr(name) orelse return error.AssetNotRegistered;
            if (acquired.state == .registered) return error.AssetDecodeNotQueued;

            while (!self.assets.isReady(name)) {
                if (self.assets.lastError(name)) |err| {
                    // Do NOT `resetFailed` here. The rewind belongs to the
                    // FINAL release, and `AssetCatalog.release` already
                    // performs it: at refcount 0 its `.failed` branch moves
                    // the entry back to `.registered` and clears
                    // `last_error`, so the sole-holder retry below still
                    // re-enqueues a fresh decode.
                    //
                    // Resetting here breaks the SHARED case (#832 review).
                    // When a scene or another async path already holds the
                    // asset, our `acquire` bumped refcount 1 → 2, so the
                    // `errdefer` above only drops it back to 1 — the entry
                    // stays alive at `.registered` with a nonzero refcount.
                    // `acquire` enqueues only on the 0 → 1 transition, so
                    // nothing would ever re-queue that entry: every retry
                    // would acquire, find `.registered`, and return
                    // `AssetDecodeNotQueued` forever. Leaving it `.failed`
                    // keeps reporting the REAL error until the other holder
                    // releases, at which point the entry rewinds and a
                    // retry decodes again.
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

        /// Resolve an engine texture handle to the BACKEND's own texture id —
        /// the value a backend-native accessor is keyed by (labelle-bgfx's
        /// `nativeTextureHandle`, and anything else reaching past the renderer
        /// into backend state).
        ///
        /// This exists so game scripts stop doing it themselves. Before it,
        /// the only way to get there was
        /// `game.renderer.getTextureInfo(...).backend_texture.id` — a script
        /// reaching around the engine boundary, legal only because Zig has no
        /// per-field privacy. A downstream UI kit did exactly that after
        /// gfx started minting its own keys (labelle-gfx#326).
        ///
        /// Null when the renderer exposes no `nativeTextureId` (older gfx, or
        /// a renderer without a texture registry) or the handle is unknown, so
        /// callers degrade rather than fabricate a handle.
        ///
        ///     const backend_id = game.nativeTextureId(handle) orelse return;
        ///     const native = backend_gfx.nativeTextureHandle(backend_id);
        pub fn nativeTextureId(self: *Game, tex_id: anytype) ?core.BackendTextureId {
            if (!@hasDecl(Renderer, "nativeTextureId")) return null;
            // Normalize to the renderer's handle type. The engine's PUBLIC
            // texture handle is a bare `u32` — `loadTextureFromMemory` and
            // `AssetTexture` both hand one out — while the renderer's seam
            // takes its own `TextureId`. Forwarding unchanged compiled only
            // when a caller happened to pass an already-typed handle, which
            // no engine-facing caller has.
            // Derive the handle type from the SEAM's own signature rather
            // than a `Renderer.TextureId` decl. The real `GfxRenderer`
            // wrapper does not declare one — only the test mock did, which
            // is why this compiled here and failed in a game.
            const Param = @typeInfo(@TypeOf(Renderer.nativeTextureId)).@"fn".params[1].type.?;
            const typed: Param = normalizeHandle(Param, tex_id);
            return self.renderer.nativeTextureId(typed);
        }

        /// Release a texture the game acquired through the engine (#817).
        ///
        /// The counterpart to `loadTextureFromMemory`. Without it a game could
        /// *acquire* a texture through the engine but only *release* it by
        /// reaching past the engine boundary —
        /// `game.renderer.unloadTexture(@enumFromInt(handle))` — legal only
        /// because Zig has no per-field privacy. That is the same shape of
        /// problem #814 solved for the backend-id conversion, one method over.
        ///
        /// Accepts the engine's PUBLIC bare `u32` handle (what
        /// `loadTextureFromMemory` returns) as well as an already-typed one.
        ///
        /// A renderer that exposes no `unloadTexture` degrades to a silent
        /// no-op rather than failing to compile, matching `nativeTextureId`.
        ///
        ///     const handle = try game.loadTextureFromMemory(".png", bytes);
        ///     defer game.unloadTexture(handle);
        pub fn unloadTexture(self: *Game, tex_id: anytype) void {
            if (!@hasDecl(Renderer, "unloadTexture")) return;
            // Drop the retained copy first (#820): the map is keyed by the
            // public `u32`, so normalize the caller's handle down to it.
            if (comptime tracks) {
                if (self.direct_textures.fetchRemove(normalizeHandle(u32, tex_id))) |old| freeDirectTexture(self, old.value);
            }
            // Normalize to the renderer's handle type, derived from the SEAM's
            // OWN signature rather than a `Renderer.TextureId` decl — the real
            // `GfxRenderer` wrapper declares no such type, and keying on one is
            // exactly what shipped a broken v2.12.0 for `nativeTextureId`.
            const Param = @typeInfo(@TypeOf(Renderer.unloadTexture)).@"fn".params[1].type.?;
            const typed: Param = normalizeHandle(Param, tex_id);
            self.renderer.unloadTexture(typed);
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
                        sprite.source_rect = sourceRectFor(SourceRectOf(Sprite), result);
                        self.renderer.markVisualDirty(entity);
                    }
                }
            }
        }
    };
}
