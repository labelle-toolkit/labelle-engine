//! Font loader — TTF/OTF bytes → glyph atlas + metrics on the worker,
//! GPU/atlas upload on the main thread, backed by a runtime-injected
//! `FontBackend`.
//!
//! Mirrors the shape of `loaders/image.zig`. See that file for the
//! full architectural rationale around backend hooks vs. direct
//! `labelle-gfx` imports — the same reasoning applies here.
//!
//! ## Decode parameters
//!
//! Unlike images and audio, the font decode path needs more than just
//! the raw bytes: pixel height, atlas dimensions, and the codepoint
//! ranges to bake into the glyph table. The catalog stores these as
//! a `*const FontBakeParams` on `AssetEntry.params` at registration
//! time; `AssetCatalog.acquire` forwards the pointer through
//! `WorkRequest.params`; the worker hands it to `vtable.decode` which
//! `@ptrCast`s back to `*const FontBakeParams` here. Lifetime: the
//! params struct must outlive the catalog entry — typical usage has
//! it living for the program (assembler-generated globals or static
//! const in user code).
//!
//! ## Threading
//!
//! Same contract as the image loader:
//! * `decode` runs on the asset worker thread. The backend is
//!   expected to be pure CPU (stb_truetype baking).
//! * `upload`, `drop`, `free` run on the main thread from
//!   `AssetCatalog.pump()` / `AssetCatalog.deinit()` / the unload
//!   path.
//!
//! ## Ownership of the four decoded slices
//!
//! `DecodedPayload.font` carries four allocator-owned slices —
//! `bitmap`, `glyphs`, `codepoint_index`, `kerning`. The decode path
//! allocates them through the worker's allocator. The main-thread
//! `upload` calls `backend.upload`, which copies whatever it needs
//! into its own structures, then `upload` frees all four slices.
//! `drop` (refcount-zero-during-decode path) also frees all four
//! without touching the backend. `free` (refcount-zero-on-ready
//! path) hands the `FontId` back to `backend.unload` and clears
//! `entry.resource`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const loader = @import("../loader.zig");
const font_types = @import("font_types");

const AssetLoaderVTable = loader.AssetLoaderVTable;
const DecodedPayload = loader.DecodedPayload;
const UploadedResource = loader.UploadedResource;
const AssetEntry = loader.AssetEntry;

/// Inclusive codepoint range (`first`..=`last`). Used by
/// `FontBakeParams.ranges` to declare which glyphs to bake into the
/// atlas. Kept here rather than in `font_types.zig` because it is a
/// *bake-time* input, not a runtime font payload — `font_types.zig`
/// is the on-resource shape consumed by the renderer.
pub const CodepointRange = struct {
    first: u32,
    last: u32,
};

/// Decode parameters threaded from `AssetCatalog.register` through
/// `WorkRequest.params` to the worker's call into `decode` below.
/// Borrowed: lives for the program lifetime under the same
/// `@embedFile`-style contract that `raw_bytes` follows on the entry.
pub const FontBakeParams = struct {
    /// Target glyph cap height in pixels. Same shape as
    /// `stb_truetype`'s `stbtt_ScaleForPixelHeight`.
    pixel_height: f32 = 16.0,
    /// Codepoint ranges to bake. Empty means "ASCII printable
    /// 0x20..0x7E"; backends should treat null/empty identically.
    ranges: []const CodepointRange = &.{},
    /// Atlas width in pixels. Power-of-two recommended for GPU sampling.
    atlas_width: u32 = 512,
    /// Atlas height in pixels. Power-of-two recommended for GPU sampling.
    atlas_height: u32 = 512,
};

/// CPU-side decoded font payload — same shape as the `font` arm of
/// `DecodedPayload` in `loader.zig`, kept here as a plain struct so
/// the backend adapter has a stable nominal type to marshal into.
pub const DecodedFont = struct {
    bitmap: []u8,
    width: u32,
    height: u32,
    glyphs: []font_types.Glyph,
    codepoint_index: []const font_types.CodepointEntry,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    line_height: f32,
    kerning: []const font_types.KernPair,
};

/// Runtime backend hook. The assembler fills this in at `Game.init`
/// with adapters that forward to labelle-gfx's font baker. Tests
/// inject a mock the same way the image loader's tests do.
pub const FontBackend = struct {
    /// Worker-thread CPU bake. Returns a `DecodedFont` whose four
    /// slices are owned by `allocator`. Errors bubble to
    /// `WorkResult.err`.
    decode: *const fn (
        file_type: [:0]const u8,
        data: []const u8,
        params: FontBakeParams,
        allocator: Allocator,
    ) anyerror!DecodedFont,

    /// Main-thread atlas upload. Copies the bitmap to a GPU texture
    /// and stashes glyph/kerning tables wherever the backend keeps
    /// them. Does NOT take ownership of any of the four slices on
    /// `decoded` — the caller frees.
    upload: *const fn (decoded: DecodedFont) anyerror!font_types.FontId,

    /// Main-thread atlas release. The counterpart to `upload`.
    unload: *const fn (id: font_types.FontId) void,
};

/// Private module-level slot for the injected backend. `null` until
/// the assembler calls `setBackend` — accidental `decode` / `upload`
/// before initialisation surfaces as
/// `error.FontBackendNotInitialized` rather than a null deref.
var active_backend: ?FontBackend = null;

/// Install the runtime backend. Call exactly once during game init,
/// before any font asset is acquired. Idempotent enough for tests:
/// the second call just overwrites the slot.
pub fn setBackend(b: FontBackend) void {
    active_backend = b;
}

/// Clear the backend slot. Used by tests to return to a clean state
/// between runs so one test's mock does not leak into the next.
pub fn clearBackend() void {
    active_backend = null;
}

/// Read-side accessor for tests / diagnostics.
pub fn currentBackend() ?FontBackend {
    return active_backend;
}

fn decode(
    file_type: [:0]const u8,
    data: []const u8,
    params: ?*const anyopaque,
    allocator: Allocator,
) anyerror!DecodedPayload {
    const b = active_backend orelse return error.FontBackendNotInitialized;
    // Bake params are mandatory for the font loader. Use a defaulted
    // params struct if the catalog forgot to attach one — keeps the
    // error path "no backend" vs. "no params" symmetric: a missing
    // backend is a hard error, missing params is a hint that the
    // caller used `register` instead of `registerFont`. We surface
    // it as a distinct error so it shows up cleanly in `lastError`.
    const params_ptr = params orelse return error.FontBakeParamsMissing;
    const bake_params: *const FontBakeParams = @ptrCast(@alignCast(params_ptr));

    const decoded = try b.decode(file_type, data, bake_params.*, allocator);
    return .{ .font = .{
        .bitmap = decoded.bitmap,
        .width = decoded.width,
        .height = decoded.height,
        .glyphs = decoded.glyphs,
        .codepoint_index = decoded.codepoint_index,
        .ascent = decoded.ascent,
        .descent = decoded.descent,
        .line_gap = decoded.line_gap,
        .line_height = decoded.line_height,
        .kerning = decoded.kerning,
    } };
}

fn upload(
    entry: *AssetEntry,
    decoded_payload: DecodedPayload,
    allocator: Allocator,
) anyerror!void {
    const b = active_backend orelse return error.FontBackendNotInitialized;
    const font_payload = switch (decoded_payload) {
        .font => |f| f,
        else => return error.WrongDecodedPayloadKind,
    };

    // Hand the bitmap + tables to the backend first — on error we
    // want the four CPU buffers freed by `drop` on the teardown path,
    // so leave them alive and let the error propagate.
    const id = try b.upload(.{
        .bitmap = font_payload.bitmap,
        .width = font_payload.width,
        .height = font_payload.height,
        .glyphs = font_payload.glyphs,
        .codepoint_index = font_payload.codepoint_index,
        .ascent = font_payload.ascent,
        .descent = font_payload.descent,
        .line_gap = font_payload.line_gap,
        .line_height = font_payload.line_height,
        .kerning = font_payload.kerning,
    });

    // Upload succeeded: the backend has copied what it needs, so we
    // own the free of every allocator-owned slice. Mirrors the
    // labelle-gfx contract for `uploadTexture` in the image loader.
    allocator.free(font_payload.bitmap);
    allocator.free(font_payload.glyphs);
    allocator.free(font_payload.codepoint_index);
    allocator.free(font_payload.kerning);

    entry.resource = .{ .font = id };
}

fn drop(allocator: Allocator, decoded_payload: DecodedPayload) void {
    switch (decoded_payload) {
        .font => |f| {
            allocator.free(f.bitmap);
            allocator.free(f.glyphs);
            allocator.free(f.codepoint_index);
            allocator.free(f.kerning);
        },
        // Other variants never reach the font loader's drop hook — the
        // catalog dispatches on the vtable carried by the `WorkResult`,
        // not on `DecodedPayload`'s tag. Keep the arms exhaustive so
        // this file compiles cleanly against future payload shapes.
        else => {},
    }
}

fn free(entry: *AssetEntry) void {
    const resource = entry.resource orelse return;
    // Release the backend handle if a backend is still installed.
    // If the backend was cleared (e.g. a test's `clearBackend`) after
    // an asset uploaded, we can't reach the atlas — skip the `unload`
    // call but STILL clear `entry.resource` so callers that read it
    // as a cleanup-completed flag get the contract `loader.zig`
    // documents.
    if (active_backend) |b| switch (resource) {
        .font => |id| b.unload(id),
        else => {},
    };
    entry.resource = null;
}

pub const vtable: AssetLoaderVTable = .{
    .decode = decode,
    .upload = upload,
    .drop = drop,
    .free = free,
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// Mock backend that records every call and produces a fixed 1×1
/// alpha bitmap + 1-glyph table. The four output slices are allocated
/// through the caller's allocator so both the happy path (upload
/// frees) and the discard path (drop frees) can run under
/// `testing.allocator`, which catches leaks and double-frees.
const MockBackend = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var last_params: ?FontBakeParams = null;
    var last_uploaded_id: font_types.FontId = font_types.FontId.invalid;
    var next_id_index: u16 = 1;
    var decode_fails: bool = false;
    var upload_fails: bool = false;

    /// Sentinel returned by `uploadFn`. Tests assert on this to prove
    /// the resource handle survives the upload path intact.
    const sentinel_id: font_types.FontId = .{ .index = 7, .generation = 42 };

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        last_params = null;
        last_uploaded_id = font_types.FontId.invalid;
        next_id_index = 1;
        decode_fails = false;
        upload_fails = false;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        params: FontBakeParams,
        allocator: Allocator,
    ) anyerror!DecodedFont {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        last_params = params;
        if (decode_fails) return error.MockFontDecodeError;

        const bitmap = try allocator.alloc(u8, 1); // 1×1 alpha
        bitmap[0] = 0xFF;

        const glyphs = try allocator.alloc(font_types.Glyph, 1);
        glyphs[0] = .{
            .u0 = 0,
            .v0 = 0,
            .u1 = 1,
            .v1 = 1,
            .xoff = 0.0,
            .yoff = 0.0,
            .advance = params.pixel_height,
        };

        const index = try allocator.alloc(font_types.CodepointEntry, 1);
        index[0] = .{ .codepoint = 'A', .glyph_index = 0 };

        const kerning = try allocator.alloc(font_types.KernPair, 0);

        return .{
            .bitmap = bitmap,
            .width = 1,
            .height = 1,
            .glyphs = glyphs,
            .codepoint_index = index,
            .ascent = params.pixel_height,
            .descent = 0.0,
            .line_gap = 0.0,
            .line_height = params.pixel_height,
            .kerning = kerning,
        };
    }

    fn uploadFn(decoded: DecodedFont) anyerror!font_types.FontId {
        _ = decoded;
        upload_calls += 1;
        if (upload_fails) return error.MockFontUploadError;
        // Hand back a stable sentinel on the first call so the
        // round-trip test can assert on a known value; later calls
        // get fresh generations so re-uploads don't collide.
        const id: font_types.FontId = if (upload_calls == 1)
            sentinel_id
        else blk: {
            const idx = next_id_index;
            next_id_index += 1;
            break :blk .{ .index = idx, .generation = 1 };
        };
        last_uploaded_id = id;
        return id;
    }

    fn unloadFn(id: font_types.FontId) void {
        _ = id;
        unload_calls += 1;
    }

    const backend_value: FontBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

test "font loader: decode without backend errors cleanly" {
    clearBackend();
    defer clearBackend();
    const params = FontBakeParams{};
    try testing.expectError(
        error.FontBackendNotInitialized,
        decode("ttf", "fake", &params, testing.allocator),
    );
}

test "font loader: decode with missing params errors cleanly" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    defer clearBackend();
    try testing.expectError(
        error.FontBakeParamsMissing,
        decode("ttf", "fake", null, testing.allocator),
    );
}

test "font loader: mock backend decode→upload→free round-trip" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    defer clearBackend();

    const params = FontBakeParams{ .pixel_height = 24.0 };

    // 1. decode on the worker thread (synchronously in the test).
    const payload = try decode("ttf", "fake-ttf-bytes", &params, testing.allocator);
    try testing.expectEqual(@as(u32, 1), MockBackend.decode_calls);
    try testing.expectEqual(@as(u32, 1), payload.font.width);
    try testing.expectEqual(@as(u32, 1), payload.font.height);
    try testing.expectEqual(@as(usize, 1), payload.font.glyphs.len);
    try testing.expectEqual(@as(f32, 24.0), payload.font.ascent);
    // Params plumbing — the mock records `last_params` on every decode.
    try testing.expect(MockBackend.last_params != null);
    try testing.expectEqual(@as(f32, 24.0), MockBackend.last_params.?.pixel_height);

    // 2. upload on the main thread. Loader owns the free of all four
    //    slices after a successful upload.
    var entry: AssetEntry = .{
        .state = .decoding,
        .refcount = 1,
        .loader = &vtable,
        .loader_kind = .font,
        .raw_bytes = "fake-ttf-bytes",
        .file_type = "ttf",
        .params = @ptrCast(&params),
        .decoded = payload,
        .resource = null,
        .last_error = null,
    };
    try upload(&entry, payload, testing.allocator);
    try testing.expectEqual(@as(u32, 1), MockBackend.upload_calls);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(MockBackend.sentinel_id, entry.resource.?.font);

    // 3. free on the main thread — refcount hit zero on a `.ready`
    //    entry. Releases the atlas handle through the backend.
    free(&entry);
    try testing.expectEqual(@as(u32, 1), MockBackend.unload_calls);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
}

test "font loader: drop path frees all slices without touching backend" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    defer clearBackend();

    const params = FontBakeParams{};
    const payload = try decode("ttf", "fake", &params, testing.allocator);
    drop(testing.allocator, payload);

    try testing.expectEqual(@as(u32, 0), MockBackend.upload_calls);
    try testing.expectEqual(@as(u32, 0), MockBackend.unload_calls);
}

test "font loader: upload error leaves slices alive for drop cleanup" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    MockBackend.upload_fails = true;
    defer clearBackend();

    const params = FontBakeParams{};
    const payload = try decode("ttf", "fake", &params, testing.allocator);
    var entry: AssetEntry = .{
        .state = .decoding,
        .refcount = 1,
        .loader = &vtable,
        .loader_kind = .font,
        .raw_bytes = "fake",
        .file_type = "ttf",
        .params = @ptrCast(&params),
        .decoded = payload,
        .resource = null,
        .last_error = null,
    };
    try testing.expectError(error.MockFontUploadError, upload(&entry, payload, testing.allocator));
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // On the failure path, `upload` must NOT have freed the buffers —
    // the catalog still needs to hand them to `drop`. Do that here so
    // `testing.allocator` stays happy.
    drop(testing.allocator, payload);
}

test "font loader: free without a backend or resource is a no-op" {
    clearBackend();
    var entry: AssetEntry = .{
        .state = .registered,
        .refcount = 0,
        .loader = &vtable,
        .loader_kind = .font,
        .raw_bytes = "",
        .file_type = "ttf",
        .params = null,
        .decoded = null,
        .resource = null,
        .last_error = null,
    };
    free(&entry);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
}
