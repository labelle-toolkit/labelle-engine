//! Image loader — CPU-decode on the worker, GPU-upload on the main
//! thread, backed by a runtime-injected `ImageBackend`.
//!
//! ## Why a runtime backend hook instead of a direct `gfx` import?
//!
//! The engine crate does **not** depend on `labelle-gfx` — `build.zig`
//! only wires `labelle-core`, `scene` and `jsonc` into the engine
//! module. That is deliberate: every asset in the monorepo-plus-URL-
//! fetch world has to be reachable through a chain of `path` / URL
//! deps that also works for backend implementations fetched by the
//! assembler, and `labelle-gfx/build.zig.zon` carries a path-relative
//! `../labelle-core` dep which breaks URL fetches (see the #440
//! ticket prologue). We do not want the engine to inherit that
//! fragility.
//!
//! So instead of `@import("labelle-gfx")`, the image loader exposes a
//! tiny `ImageBackend` struct of function pointers that the assembler
//! populates at `Game.init` time via `setBackend`. The assembler
//! already imports `labelle-gfx`, so the `decodeImage` /
//! `uploadTexture` / `unloadTexture` values live on its side of the
//! dependency boundary; the engine only ever sees plain function
//! pointers to a local `DecodedImage` POD.
//!
//! This also side-steps the nominal-type collision described in the
//! ticket: because the engine never imports labelle-gfx's
//! `DecodedImage`, there is no way for two structurally-identical
//! types to collide here — the backend adapter just marshals between
//! whatever shape `gfx.decodeImage` returns and this module's
//! `DecodedImage`, which is the shape the loader hands to the catalog.
//!
//! ## Threading
//!
//! * `decode` runs on the asset worker thread. It calls
//!   `backend.decode(file_type, data, allocator)` — `stb_image` via
//!   the backend adapter is pure CPU, no GL calls, so that is safe.
//! * `upload`, `drop`, `free` all run on the main thread from
//!   `AssetCatalog.pump()` / `AssetCatalog.deinit()` / the future
//!   #446 unload path. `upload` and `free` call back into the backend
//!   on the main thread for GL operations.
//!
//! ## Ownership of `DecodedImage.pixels`
//!
//! * `decode` allocates the pixel buffer through the provided
//!   allocator — same allocator the worker hands in, same allocator
//!   that later frees the buffer.
//! * `upload` calls `backend.upload` (which **copies** the pixels to
//!   the GPU) and then frees the CPU buffer via `allocator`. The
//!   labelle-gfx contract explicitly says `uploadTexture` does NOT
//!   take ownership.
//! * `drop` is the refcount-zero-during-decode path: free the CPU
//!   buffer, leave the GPU alone.
//! * `free` is the refcount-zero-on-ready path: release the texture
//!   handle through `backend.unload`; the CPU buffer is already gone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const loader = @import("../loader.zig");

const AssetLoaderVTable = loader.AssetLoaderVTable;
const DecodedPayload = loader.DecodedPayload;
const UploadedResource = loader.UploadedResource;
const AssetEntry = loader.AssetEntry;
const Texture = loader.Texture;

/// CPU-side decoded pixels + dimensions, allocator-owned. Kept
/// intentionally plain so the backend adapter can bridge it to
/// whatever `DecodedImage` shape labelle-gfx uses on its side of the
/// dependency boundary without a nominal-type conflict.
pub const DecodedImage = struct {
    pixels: []u8, // RGBA8, allocator-owned
    width: u32,
    height: u32,
};

/// Runtime backend hook. The assembler fills this in at `Game.init`
/// by calling `setBackend` with adapters that forward to
/// `labelle-gfx`'s `decodeImage` / `uploadTexture` / `unloadTexture`.
/// Tests inject a mock implementation the same way — see
/// `test "image loader: mock backend round-trip"` in this file.
pub const ImageBackend = struct {
    /// Worker-thread CPU decode. Returns a `DecodedImage` whose
    /// `pixels` slice is owned by `allocator`. Errors bubble to
    /// `WorkResult.err`.
    decode: *const fn (
        file_type: [:0]const u8,
        data: []const u8,
        allocator: Allocator,
    ) anyerror!DecodedImage,

    /// Main-thread GPU upload. Copies pixels to a new texture and
    /// returns the handle. Does NOT take ownership of `decoded.pixels`
    /// — the caller frees.
    upload: *const fn (decoded: DecodedImage) anyerror!Texture,

    /// Main-thread GPU release. The counterpart to `upload`.
    unload: *const fn (texture: Texture) void,
};

/// Private module-level slot for the injected backend. `null` until
/// the assembler calls `setBackend` — tests + catalog unit tests that
/// do not touch the image loader can keep ignoring it, and any
/// accidental `decode` / `upload` before initialisation surfaces as
/// `error.ImageBackendNotInitialized` rather than a null deref.
var backend: ?ImageBackend = null;

/// Install the runtime backend. Call exactly once during game init,
/// before any image asset is acquired. Idempotent enough for tests:
/// the second call just overwrites the slot.
pub fn setBackend(b: ImageBackend) void {
    backend = b;
}

/// Clear the backend slot. Used by tests to return to a clean state
/// between runs so one test's mock does not leak into the next.
pub fn clearBackend() void {
    backend = null;
}

/// Read-side accessor for tests / diagnostics.
pub fn currentBackend() ?ImageBackend {
    return backend;
}

fn decode(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: Allocator,
) anyerror!DecodedPayload {
    const b = backend orelse return error.ImageBackendNotInitialized;
    const decoded = try b.decode(file_type, data, allocator);
    return .{ .image = .{
        .pixels = decoded.pixels,
        .width = decoded.width,
        .height = decoded.height,
    } };
}

fn upload(
    entry: *AssetEntry,
    decoded_payload: DecodedPayload,
    allocator: Allocator,
) anyerror!void {
    const b = backend orelse return error.ImageBackendNotInitialized;
    const image = switch (decoded_payload) {
        .image => |img| img,
        else => return error.WrongDecodedPayloadKind,
    };

    // Hand the pixels to the GPU first — if this errors we still want
    // the CPU buffer freed by `drop` on the teardown path, so leave it
    // alive here and let the error propagate.
    const texture = try b.upload(.{
        .pixels = image.pixels,
        .width = image.width,
        .height = image.height,
    });

    // Upload succeeded: the GPU has its own copy, so we can release
    // the allocator-owned CPU buffer now. The labelle-gfx contract
    // says `uploadTexture` does NOT take ownership.
    allocator.free(image.pixels);

    entry.resource = .{ .image = texture };
}

fn drop(allocator: Allocator, decoded_payload: DecodedPayload) void {
    switch (decoded_payload) {
        .image => |img| allocator.free(img.pixels),
        // Other variants never reach the image loader's drop hook —
        // the catalog dispatches on the vtable carried by the
        // `WorkResult`, not on `DecodedPayload`'s tag. Keep the arms
        // exhaustive so this file compiles cleanly against future
        // payload shapes.
        else => {},
    }
}

fn free(entry: *AssetEntry) void {
    const resource = entry.resource orelse return;
    // Release the GPU handle if a backend is installed. If the backend
    // was cleared (e.g. a test's `clearBackend`) after an asset uploaded,
    // we can't reach the GPU — skip the `unload` call but STILL clear
    // `entry.resource` so callers that check `entry.resource != null` as
    // a cleanup-completed flag get the contract `loader.zig` documents.
    if (backend) |b| switch (resource) {
        .image => |tex| b.unload(tex),
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

/// Tiny mock backend that records every call. `decode` allocates a
/// fixed `width * height * 4`-byte RGBA buffer through the caller's
/// allocator so we can exercise both the happy path (upload frees)
/// and the discard path (drop frees) under `testing.allocator`,
/// which catches leaks and double-frees.
const MockBackend = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var last_uploaded: ?DecodedImage = null;
    var last_unloaded: Texture = 0;
    var next_texture: Texture = 1;
    var decode_fails: bool = false;
    var upload_fails: bool = false;
    var decode_width: u32 = 2;
    var decode_height: u32 = 2;

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        last_uploaded = null;
        last_unloaded = 0;
        next_texture = 1;
        decode_fails = false;
        upload_fails = false;
        decode_width = 2;
        decode_height = 2;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        allocator: Allocator,
    ) anyerror!DecodedImage {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        if (decode_fails) return error.MockDecodeError;
        const byte_count: usize = @as(usize, decode_width) * @as(usize, decode_height) * 4;
        const pixels = try allocator.alloc(u8, byte_count);
        // Fill with a recognisable byte so the upload mock can assert
        // it was called with the same bytes the decode produced.
        @memset(pixels, 0xAB);
        return .{ .pixels = pixels, .width = decode_width, .height = decode_height };
    }

    fn uploadFn(decoded: DecodedImage) anyerror!Texture {
        upload_calls += 1;
        if (upload_fails) return error.MockUploadError;
        last_uploaded = decoded;
        const t = next_texture;
        next_texture += 1;
        return t;
    }

    fn unloadFn(texture: Texture) void {
        unload_calls += 1;
        last_unloaded = texture;
    }

    const backend_value: ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

test "image loader: decode without backend errors cleanly" {
    clearBackend();
    defer clearBackend();
    try testing.expectError(
        error.ImageBackendNotInitialized,
        decode("png", "fake", testing.allocator),
    );
}

test "image loader: mock backend decode→upload→free round-trip" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    defer clearBackend();

    // 1. decode on the worker thread (synchronously in the test).
    const payload = try decode("png", "fake-png-bytes", testing.allocator);
    try testing.expectEqual(@as(u32, 1), MockBackend.decode_calls);
    try testing.expectEqual(@as(u32, 2), payload.image.width);
    try testing.expectEqual(@as(u32, 2), payload.image.height);
    try testing.expectEqual(@as(usize, 16), payload.image.pixels.len);
    try testing.expectEqual(@as(u8, 0xAB), payload.image.pixels[0]);

    // 2. upload on the main thread. The loader owns the free of the
    //    CPU-side pixels after a successful upload.
    var entry: AssetEntry = .{
        .state = .decoding,
        .refcount = 1,
        .loader = &vtable,
        .loader_kind = .image,
        .raw_bytes = "fake-png-bytes",
        .file_type = "png",
        .decoded = payload,
        .resource = null,
        .last_error = null,
    };
    try upload(&entry, payload, testing.allocator);
    try testing.expectEqual(@as(u32, 1), MockBackend.upload_calls);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(Texture, 1), entry.resource.?.image);
    // The upload mock recorded the same pixel buffer the decode produced.
    try testing.expect(MockBackend.last_uploaded != null);
    try testing.expectEqual(@as(u32, 2), MockBackend.last_uploaded.?.width);

    // 3. free on the main thread — refcount hit zero on a `.ready`
    //    entry. Releases the texture through the backend.
    free(&entry);
    try testing.expectEqual(@as(u32, 1), MockBackend.unload_calls);
    try testing.expectEqual(@as(Texture, 1), MockBackend.last_unloaded);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // `testing.allocator` would flag a leak of the pixel buffer here
    // if upload had failed to free it. It is a GPA under the hood,
    // so a double-free would also trip.
}

test "image loader: drop path frees pixels without touching GPU" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    defer clearBackend();

    // Simulate a decode landing on the result ring but the refcount
    // dropping back to zero before pump() can finalise — the catalog
    // routes the payload straight to `drop`.
    const payload = try decode("png", "fake", testing.allocator);
    drop(testing.allocator, payload);

    try testing.expectEqual(@as(u32, 0), MockBackend.upload_calls);
    try testing.expectEqual(@as(u32, 0), MockBackend.unload_calls);
}

test "image loader: upload error leaves pixels alive for drop cleanup" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    MockBackend.upload_fails = true;
    defer clearBackend();

    const payload = try decode("png", "fake", testing.allocator);
    var entry: AssetEntry = .{
        .state = .decoding,
        .refcount = 1,
        .loader = &vtable,
        .loader_kind = .image,
        .raw_bytes = "fake",
        .file_type = "png",
        .decoded = payload,
        .resource = null,
        .last_error = null,
    };
    try testing.expectError(error.MockUploadError, upload(&entry, payload, testing.allocator));
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // On the failure path, `upload` must NOT have freed the buffer —
    // the catalog still needs to hand it to `drop`. Do that here to
    // keep `testing.allocator` happy.
    drop(testing.allocator, payload);
}

test "image loader: free without a backend or resource is a no-op" {
    clearBackend();
    var entry: AssetEntry = .{
        .state = .registered,
        .refcount = 0,
        .loader = &vtable,
        .loader_kind = .image,
        .raw_bytes = "",
        .file_type = "png",
        .decoded = null,
        .resource = null,
        .last_error = null,
    };
    free(&entry);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
}

test "image loader: decode propagates backend errors" {
    MockBackend.reset();
    setBackend(MockBackend.backend_value);
    MockBackend.decode_fails = true;
    defer clearBackend();

    try testing.expectError(
        error.MockDecodeError,
        decode("png", "fake", testing.allocator),
    );
    try testing.expectEqual(@as(u32, 1), MockBackend.decode_calls);
}
