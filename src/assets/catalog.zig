//! AssetCatalog — metadata-only registry + refcounted handles for
//! every streamable asset in the game (atlases, audio, fonts, …).
//!
//! This is the foundation of `src/assets/`. Subsequent tickets
//! layer the worker thread (#439), real loaders (#440/#441), the
//! frame-pump body (#442), the legacy atlas shim (#443), and the
//! scene-transition wiring (#444/#445/#446) on top of it.
//!
//! ## Invariants
//!
//! 1. **Threading.** `AssetEntry` is owned exclusively by the main
//!    thread. State transitions (`registered → queued → decoding →
//!    ready/failed`) and refcount mutations happen only inside
//!    `pump()` and the public methods on this struct. There is no
//!    mutex on the catalog itself: future worker-thread interaction
//!    (#439) flows through bounded SPSC ring buffers — the worker
//!    never touches an `AssetEntry` directly.
//!
//! 2. **`@embedFile` lifetime.** `raw_bytes` and `file_type` on every
//!    entry are *borrowed slices*, never copied. They originate from
//!    `@embedFile` calls in the assembler-generated init code, which
//!    means they live for the entire program. The same lifetime
//!    guarantee that engine #434's `PendingImage` already relies on.
//!    The asset *name* used as the hash-map key is borrowed under the
//!    same contract — typically the resource name from
//!    `project.labelle`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const loader_mod = @import("loader.zig");
const worker_mod = @import("worker.zig");

pub const LoaderKind = loader_mod.LoaderKind;
pub const DecodedPayload = loader_mod.DecodedPayload;
pub const UploadedResource = loader_mod.UploadedResource;
pub const Texture = loader_mod.Texture;
pub const AssetLoaderVTable = loader_mod.AssetLoaderVTable;
pub const AssetState = loader_mod.AssetState;
pub const AssetEntry = loader_mod.AssetEntry;
pub const WorkRequest = worker_mod.WorkRequest;
pub const WorkResult = worker_mod.WorkResult;

/// Upper bound on finalised uploads per `pump()` call. Caps the main-
/// thread time budget spent inside `loader.upload` — important for a
/// frame-pump that runs every tick once the legacy atlas shim (#443)
/// lands. If more results are sitting on the ring, the next `pump()`
/// will drain the remainder. Matches the RFC §2 sketch.
pub const UPLOAD_BUDGET_PER_FRAME: u8 = 4;

pub const AssetCatalog = struct {
    allocator: Allocator,
    entries: std.StringHashMap(AssetEntry),
    /// Main → worker ring. The catalog is the sole producer (from
    /// `acquire`); the worker is the sole consumer.
    requests: worker_mod.RequestRing,
    /// Worker → main ring. The worker is the sole producer; `pump()`
    /// (#442) will be the sole consumer. For now `deinit` drains it.
    results: worker_mod.ResultRing,
    worker: worker_mod.AssetWorker,
    worker_started: bool,

    /// Builds the catalog. The worker thread is spawned lazily on
    /// the first `acquire` — this keeps `init`'s signature infallible
    /// relative to `std.Thread.spawn` failures *and* dodges the
    /// classic "return-by-value captures a stack pointer" trap: the
    /// rings need to live at a stable address before the worker
    /// captures `&self.requests`, and the stable address only exists
    /// once the caller has moved the returned value into its own
    /// slot.
    pub fn init(allocator: Allocator) AssetCatalog {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(AssetEntry).init(allocator),
            .requests = worker_mod.RequestRing.init(),
            .results = worker_mod.ResultRing.init(),
            .worker = undefined,
            .worker_started = false,
        };
    }

    /// Ensures the background worker is running. Idempotent. Called
    /// from `acquire` on the first `0 → 1` refcount transition so
    /// catalogs that never `acquire` (e.g. most unit tests) don't
    /// pay the thread-spawn cost at all.
    fn ensureWorker(self: *AssetCatalog) !void {
        if (self.worker_started) return;
        self.worker = worker_mod.AssetWorker.init(
            self.allocator,
            &self.requests,
            &self.results,
        );
        try self.worker.start();
        self.worker_started = true;
    }

    pub fn deinit(self: *AssetCatalog) void {
        // 1. Stop the worker (sets the shutdown flag and joins).
        //    Only meaningful if `acquire` ever ran and kicked the
        //    lazy spawn — otherwise `worker` is undefined.
        if (self.worker_started) {
            self.worker.stop();
            self.worker_started = false;
        }

        // 2. Drain any in-flight results. Real loaders (Phase 4) will
        //    have allocator-owned CPU payloads here; placeholders are
        //    no-ops but the contract is already wired so #440 / #441
        //    can drop the TODOs.
        while (self.results.tryDequeue()) |result| {
            if (result.decoded) |payload| {
                // Use the vtable carried on the result itself — avoids
                // a hashmap lookup and survives the case where an entry
                // was removed after its WorkRequest was submitted.
                result.vtable.drop(self.allocator, payload);
            }
        }

        // 3. Release any backend resources that are still live. Anything
        //    at `.ready` at shutdown skipped the normal `release` path
        //    (game teardown, test that forgot to balance acquires, …);
        //    hand those handles back to their backends so we don't leak
        //    GPU textures / audio devices / font atlases on exit.
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (entry.state == .ready) {
                entry.loader.free(entry);
                entry.decoded = null;
                entry.state = .registered;
            }
        }
        self.entries.deinit();
    }

    /// Metadata-only registration. Does **not** decode and does **not**
    /// allocate beyond the hash-map slot itself, so it is safe to call
    /// during `Game.init` from assembler-generated code.
    ///
    /// `name`, `file_type` and `bytes` are borrowed — see the
    /// `@embedFile` lifetime invariant at the top of this file.
    /// Registering the same `name` twice is an error; the catalog
    /// keeps the original entry and returns `error.AssetAlreadyRegistered`.
    pub fn register(
        self: *AssetCatalog,
        name: []const u8,
        loader_kind: LoaderKind,
        file_type: [:0]const u8,
        bytes: []const u8,
    ) !void {
        if (self.entries.contains(name)) return error.AssetAlreadyRegistered;
        try self.entries.put(name, .{
            .state = .registered,
            .refcount = 0,
            .loader = loaderForKind(loader_kind),
            .loader_kind = loader_kind,
            .raw_bytes = bytes,
            .file_type = file_type,
            .decoded = null,
            .resource = null,
            .last_error = null,
        });
    }

    /// Bumps the refcount and returns a pointer to the entry. The
    /// pointer is stable until the next `register` call (StringHashMap
    /// rehash invalidates pointers); call sites must not retain it
    /// across catalog mutations.
    ///
    /// On the *first* acquire (refcount transitions 0 → 1) of a
    /// `.registered` entry, a `WorkRequest` is enqueued on the
    /// main→worker ring and the state moves to `.queued`. If the
    /// ring is full we log and leave the state at `.registered` —
    /// `pump()` (#442) will retry on its next tick. The pointer is
    /// still returned either way; callers can keep polling `isReady`.
    pub fn acquire(self: *AssetCatalog, name: []const u8) !*AssetEntry {
        // Resolve the stable hashmap-owned key up front: `name` itself may
        // be a temporary (stack buffer, formatted string, etc.), so the
        // worker must never borrow it directly — use `kv.key_ptr.*`, which
        // is the original `register`-time slice and therefore program-
        // lifetime per the `@embedFile` invariant at the top of this file.
        const kv = self.entries.getEntry(name) orelse return error.AssetNotRegistered;
        const entry = kv.value_ptr;
        const needs_enqueue = entry.refcount == 0 and entry.state == .registered;

        if (needs_enqueue) {
            // Spawn the worker BEFORE touching the refcount. If thread
            // spawn fails, `try` bubbles the error with the catalog
            // state unchanged — no leaked refcount that would trap the
            // entry at `.registered` with `refcount > 0` forever.
            try self.ensureWorker();
            const request: WorkRequest = .{
                .entry_name = kv.key_ptr.*,
                .vtable = entry.loader,
                .file_type = entry.file_type,
                .bytes = entry.raw_bytes,
            };
            if (self.requests.tryEnqueue(request)) |_| {
                entry.state = .queued;
            } else |err| switch (err) {
                // Ring saturated — pump() will retry the transition
                // on its next tick (#442). Leave the state at
                // `.registered` so the retry can fire naturally.
                error.QueueFull => std.log.debug(
                    "assets: request ring full, deferring acquire of '{s}'",
                    .{kv.key_ptr.*},
                ),
            }
        }
        entry.refcount += 1;
        return entry;
    }

    /// Drops the refcount. When it hits zero on a `.ready` entry, the
    /// backend resource is released via `entry.loader.free` (GPU
    /// texture, audio device, font atlas, …), the CPU-side decoded
    /// payload slot is cleared, and the entry is moved back to
    /// `.registered` so a future `acquire` can re-enqueue a fresh
    /// decode. Non-`.ready` states are left alone — the worker / pump
    /// pipeline owns their cleanup (zombie drops in `pump`, CPU buffer
    /// already gone for `.failed`, no resource allocated yet for
    /// `.queued` / `.decoding`).
    ///
    /// Releasing an unknown or already-zero entry is a no-op — the
    /// catalog never panics on a stale handle.
    pub fn release(self: *AssetCatalog, name: []const u8) void {
        const entry = self.entries.getPtr(name) orelse return;
        if (entry.refcount == 0) return;
        entry.refcount -= 1;
        if (entry.refcount != 0) return;

        switch (entry.state) {
            .ready => {
                // Hand the GPU/audio/font handle back to the backend.
                // The vtable contract in `loader.zig` says `free`
                // clears `entry.resource` to null — see
                // `loaders/image.zig` `free` for the canonical impl.
                entry.loader.free(entry);
                entry.decoded = null;
                entry.state = .registered;
            },
            .failed => {
                // Rewind to `.registered` so a later `acquire` re-
                // enqueues a fresh decode (transient errors — network
                // race, backend hiccup, etc. — become retryable once
                // nobody is holding the failed reference). Preserving
                // `.failed` past refcount 0 would permanently brick
                // the entry for no benefit: `last_error` is already
                // gone from the caller's POV the moment they released.
                // Clear `last_error` so the next acquire starts clean.
                entry.last_error = null;
                entry.state = .registered;
            },
            // `.registered`, `.queued`, `.decoding` have no GPU/CPU
            // payload to free from the release path — pump handles the
            // zombie-drop case for `.queued`/`.decoding` when it sees
            // a refcount-zero entry come back from the worker.
            else => {},
        }
    }

    pub fn isReady(self: *AssetCatalog, name: []const u8) bool {
        const entry = self.entries.getPtr(name) orelse return false;
        return entry.state == .ready;
    }

    /// `true` iff every name in `names` is currently `.ready`. An
    /// empty slice trivially returns `true` so callers can use the
    /// result directly as a "scene manifest is satisfied" check.
    pub fn allReady(self: *AssetCatalog, names: []const []const u8) bool {
        for (names) |name| {
            if (!self.isReady(name)) return false;
        }
        return true;
    }

    /// Fraction of `names` currently `.ready`, in `[0.0, 1.0]`.
    /// Empty slice returns `1.0` for the same reason `allReady`
    /// returns `true`. Unknown names count as not-ready.
    pub fn progress(self: *AssetCatalog, names: []const []const u8) f32 {
        if (names.len == 0) return 1.0;
        var ready: usize = 0;
        for (names) |name| {
            if (self.isReady(name)) ready += 1;
        }
        return @as(f32, @floatFromInt(ready)) / @as(f32, @floatFromInt(names.len));
    }

    pub fn lastError(self: *AssetCatalog, name: []const u8) ?anyerror {
        const entry = self.entries.getPtr(name) orelse return null;
        return entry.last_error;
    }

    /// Rewind a `.failed` entry back to `.registered` so the next
    /// `acquire` re-enqueues the decode. Without this, a transient
    /// decode/upload failure becomes permanent: `acquire` only
    /// enqueues from `.registered`, so a retry would re-bump the
    /// refcount and immediately surface the stale `last_error` from
    /// the failed attempt without re-triggering work.
    ///
    /// Caller-driven (not automatic) so the failure is observable
    /// via `lastError` first — letting the caller decide whether to
    /// retry or surface the error to the user. No-op for entries
    /// that aren't `.failed`. Clears `last_error` so a subsequent
    /// `lastError` call returns null.
    pub fn resetFailed(self: *AssetCatalog, name: []const u8) void {
        const entry = self.entries.getPtr(name) orelse return;
        if (entry.state != .failed) return;
        entry.state = .registered;
        entry.last_error = null;
    }

    /// Drains worker results and finalises uploads on the main thread.
    /// Caps itself at `UPLOAD_BUDGET_PER_FRAME` so a burst of ready
    /// decodes cannot stall a frame; the next `pump()` picks up where
    /// this one left off.
    ///
    /// Four outcomes per dequeued result, in order of precedence:
    ///
    /// 1. **Entry removed** (future `remove()` path): the entry was
    ///    deleted between enqueue and dequeue. The `result.vtable` was
    ///    copied out of the originating request so we can still drop
    ///    the allocator-owned CPU payload without a hashmap lookup.
    ///
    /// 2. **Zombie upload**: refcount hit zero while the decode was in
    ///    flight. Drop the CPU payload, rewind the entry to
    ///    `.registered` — a later `acquire` will re-enqueue the work.
    ///
    /// 3. **Worker-reported error**: bubble `result.err` into
    ///    `entry.last_error` and flip to `.failed`. Refcount stays put
    ///    — the caller's `acquire` still holds a reference until an
    ///    explicit `release`.
    ///
    /// 4. **Happy path**: call `vtable.upload`. The loader's contract
    ///    (see `loaders/image.zig` §"Ownership of DecodedImage.pixels"
    ///    and `loader.zig` `AssetLoaderVTable.upload` docs) says
    ///    upload owns the free of the CPU buffer on success AND
    ///    populates `entry.resource` with the backend handle. On
    ///    upload failure the loader's contract is that it leaves the
    ///    CPU buffer alive and returns the error — so `pump` hands
    ///    the payload to `vtable.drop` before flipping to `.failed`.
    ///    Without that, a failed upload would leak allocator-owned
    ///    pixels (confirmed: `loaders/image.zig` `upload` returns
    ///    before reaching its `allocator.free` on the error path).
    pub fn pump(self: *AssetCatalog) void {
        // Counter bounds ACTUAL GPU uploads, not dequeued results. Cheap
        // paths (zombie drops, decode errors, removed-entry cleanup) are
        // nearly free and should be cleared in a single pump tick so a
        // burst of them doesn't starve the valid uploads waiting behind
        // them in the ring.
        var uploads_done: u8 = 0;
        while (uploads_done < UPLOAD_BUDGET_PER_FRAME) {
            const result = self.results.tryDequeue() orelse return;

            // (1) Entry was removed between enqueue and dequeue. No
            // `remove()` exists today, but the RFC reserves the right
            // to add one and the worker result already carries its own
            // vtable so we can clean up without the hashmap.
            const entry = self.entries.getPtr(result.entry_name) orelse {
                if (result.decoded) |payload| {
                    result.vtable.drop(self.allocator, payload);
                }
                continue;
            };

            // (2) Released while the worker was decoding → zombie. Drop
            // the CPU payload and rewind to `.registered` so a future
            // `acquire` can re-enqueue the work cleanly.
            if (entry.refcount == 0) {
                if (result.decoded) |payload| {
                    result.vtable.drop(self.allocator, payload);
                }
                entry.decoded = null;
                entry.state = .registered;
                continue;
            }

            // (3) Worker-reported decode error. The worker already knew
            // there was no payload to free; just record the error and
            // flip state. Leave refcount intact — the caller still owns
            // their reference and must `release` to clear it.
            if (result.err) |err| {
                entry.last_error = err;
                entry.state = .failed;
                continue;
            }

            // (4) Happy path — count it against the upload budget only
            // once we're actually about to touch the GPU. `err == null`
            // implies `decoded` is populated (see worker.zig:runLoop).
            // Upload hands the pixels to the backend, populates
            // `entry.resource`, and frees the CPU buffer itself on
            // success. On failure it leaves the CPU buffer alive — so
            // we route the payload to `vtable.drop` before flipping to
            // `.failed`, else the allocator-owned pixels would leak
            // (testing.allocator catches this).
            uploads_done += 1;
            const payload = result.decoded.?;
            result.vtable.upload(entry, payload, self.allocator) catch |err| {
                result.vtable.drop(self.allocator, payload);
                entry.decoded = null;
                entry.last_error = err;
                entry.state = .failed;
                continue;
            };
            // Upload succeeded: CPU buffer was freed by the loader,
            // resource handle is parked on `entry.resource`.
            entry.decoded = null;
            entry.state = .ready;
        }
    }
};

// ---------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------

const image_loader = @import("loaders/image.zig");
const audio_loader = @import("loaders/audio.zig");
const font_loader = @import("loaders/font.zig");

fn loaderForKind(kind: LoaderKind) *const AssetLoaderVTable {
    return switch (kind) {
        .image => &image_loader.vtable,
        .audio => &audio_loader.vtable,
        .font => &font_loader.vtable,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

const dummy_bytes: []const u8 = "PNG-fake-bytes";
const dummy_file_type: [:0]const u8 = "png";

test "register then acquire bumps refcount and enqueues work" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);

    const entry = try catalog.acquire("background");
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    // First acquire moved the entry to `.queued` — the worker ring
    // has taken ownership of the request and will eventually publish
    // an `error.ImageBackendNotInitialized` result on the real image
    // loader (no backend injected in the unit-test harness).
    try testing.expectEqual(AssetState.queued, entry.state);
    try testing.expectEqual(LoaderKind.image, entry.loader_kind);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
}

test "double acquire then release ordering" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);

    const e1 = try catalog.acquire("ship");
    _ = try catalog.acquire("ship");
    try testing.expectEqual(@as(u32, 2), e1.refcount);

    catalog.release("ship");
    try testing.expectEqual(@as(u32, 1), e1.refcount);

    catalog.release("ship");
    try testing.expectEqual(@as(u32, 0), e1.refcount);
    // State stays at `.queued` until `pump()` (#442) drains the
    // worker result — `release` on a non-`.ready` entry only touches
    // the refcount.
    try testing.expectEqual(AssetState.queued, e1.state);
}

test "release on already-zero entry is a no-op" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    catalog.release("ship");
    catalog.release("ship");
    catalog.release("unknown-asset");

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(@as(u32, 0), entry.refcount);
}

test "isReady is false for a fresh registration" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    try testing.expect(!catalog.isReady("background"));
    try testing.expect(!catalog.isReady("never-registered"));
}

test "allReady returns true for an empty slice" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    const names: []const []const u8 = &.{};
    try testing.expect(catalog.allReady(names));
    try testing.expectEqual(@as(f32, 1.0), catalog.progress(names));
}

test "progress reflects mixed ready states" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("a", .image, dummy_file_type, dummy_bytes);
    try catalog.register("b", .image, dummy_file_type, dummy_bytes);

    const names: []const []const u8 = &.{ "a", "b" };
    try testing.expectEqual(@as(f32, 0.0), catalog.progress(names));
    try testing.expect(!catalog.allReady(names));

    // Simulate the worker / pump path by forcing one entry to ready.
    // The real transition lands with #442; for the unit test we just
    // need a `.ready` entry to verify the bookkeeping.
    const a = try catalog.acquire("a");
    a.state = .ready;
    try testing.expectEqual(@as(f32, 0.5), catalog.progress(names));
    try testing.expect(!catalog.allReady(names));

    const b = try catalog.acquire("b");
    b.state = .ready;
    try testing.expectEqual(@as(f32, 1.0), catalog.progress(names));
    try testing.expect(catalog.allReady(names));
}

test "lastError is null for a never-failed entry" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    try testing.expectEqual(@as(?anyerror, null), catalog.lastError("background"));
    try testing.expectEqual(@as(?anyerror, null), catalog.lastError("unknown"));
}

test "duplicate register returns AssetAlreadyRegistered" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    try testing.expectError(
        error.AssetAlreadyRegistered,
        catalog.register("ship", .image, dummy_file_type, dummy_bytes),
    );
}

test "acquire on unknown asset returns AssetNotRegistered" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(error.AssetNotRegistered, catalog.acquire("ghost"));
}

test "pump on an empty result ring is a no-op" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    // No acquire → worker never spawned, no results to drain. `pump`
    // must stay passive — no panic, no state change, no allocation.
    catalog.pump();
    const entry = catalog.entries.getPtr("background").?;
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expect(!catalog.isReady("background"));
}

test "acquire spawns worker which surfaces ImageBackendNotInitialized without a backend" {
    // Make sure no previous test left a backend injected on this
    // process-global slot — the assertions below rely on the loader
    // returning the not-initialised error, not a mock success.
    image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("background");

    // Spin up to 200ms waiting for the worker to publish a result.
    // `pump()` is still a no-op (#442) so we peek at the ring
    // directly to verify the machinery.
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    const result = while (waited_ns < deadline_ns) {
        if (catalog.results.tryDequeue()) |r| break r;
        std.Thread.sleep(step_ns);
        waited_ns += step_ns;
    } else {
        return error.WorkerDidNotRespond;
    };

    try testing.expectEqualStrings("background", result.entry_name);
    try testing.expectEqual(@as(?DecodedPayload, null), result.decoded);
    try testing.expectEqual(@as(?anyerror, error.ImageBackendNotInitialized), result.err);
}

test "deinit with a pending acquire shuts down cleanly" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("background");
    // Intentionally do not drain — deinit must join the worker and
    // drop any in-flight results without deadlocking or leaking.
}

// ---------------------------------------------------------------------
// pump() tests (#442)
// ---------------------------------------------------------------------
//
// These share a module-scoped mock backend for the image loader so
// each test can tune `decode_fails` / `upload_fails` independently.
// `testing.allocator` is a GPA under the hood, so a leaked CPU buffer
// or a double-free on any path below will fail the test.

const DecodedImage = image_loader.DecodedImage;
const ImageBackend = image_loader.ImageBackend;

const PumpMock = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var next_tex: Texture = 500;
    var decode_fails: bool = false;
    var upload_fails: bool = false;

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        next_tex = 500;
        decode_fails = false;
        upload_fails = false;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        allocator: Allocator,
    ) anyerror!DecodedImage {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        if (decode_fails) return error.PumpMockDecodeError;
        // 1×1 RGBA — tiny enough to keep the tests fast, big enough
        // that `testing.allocator` catches a leak if `drop` / upload
        // forget to free.
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0xCD);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }

    fn uploadFn(decoded: DecodedImage) anyerror!Texture {
        _ = decoded;
        upload_calls += 1;
        if (upload_fails) return error.PumpMockUploadError;
        const t = next_tex;
        next_tex += 1;
        return t;
    }

    fn unloadFn(texture: Texture) void {
        _ = texture;
        unload_calls += 1;
    }

    const backend_value: ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

/// Spin until the worker has published `at_least` results onto the
/// result ring or a 200ms deadline elapses. The worker parks for
/// ~100µs between empty polls so this is fine-grained enough for
/// tests but never a busy-wait in production.
fn spinForResults(catalog: *AssetCatalog, at_least: u32) !void {
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        // Non-atomic peek — safe here because the test is the sole
        // consumer and the worker is the sole producer. `pump()`
        // would normally race us for these slots.
        const head = catalog.results.head.load(.acquire);
        const tail = catalog.results.tail.load(.acquire);
        if (head -% tail >= at_least) return;
        std.Thread.sleep(step_ns);
    }
    return error.WorkerDidNotRespond;
}

test "pump: happy path transitions to .ready with resource populated" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("ship");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expect(entry.resource.?.image >= 500);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(?anyerror, null), entry.last_error);
    try testing.expectEqual(@as(u32, 1), PumpMock.upload_calls);
    // Catalog must report ready via the same query sites the scene
    // hooks (#444) will use.
    try testing.expect(catalog.isReady("ship"));
    // `release` on a `.ready` entry triggers `vtable.free` (#446),
    // which hands the texture back to the backend and clears
    // `entry.resource`. State rewinds to `.registered` so a later
    // `acquire` re-enqueues a fresh decode.
    catalog.release("ship");
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(u32, 0), entry.refcount);
}

test "pump: zombie drop — release before upload rewinds to .registered and frees pixels" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("transient", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("transient");

    // Wait for the worker to actually decode so there is an
    // allocator-owned pixel buffer pending on the result ring.
    try spinForResults(&catalog, 1);
    // Drop the refcount to zero *before* pump runs — this is the
    // classic "scene unloaded before its assets finished loading"
    // race the RFC §2 zombie-drop path protects against.
    catalog.release("transient");

    catalog.pump();

    const entry = catalog.entries.getPtr("transient").?;
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // Upload must NOT have fired — the zombie path skips it entirely.
    try testing.expectEqual(@as(u32, 0), PumpMock.upload_calls);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);
    // `testing.allocator` would report a leak here if the pixel buffer
    // from `decodeFn` was not handed back to `vtable.drop`.
}

test "pump: upload error bubbles to .failed and frees the CPU payload" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    PumpMock.upload_fails = true;
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("bad-upload", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("bad-upload");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("bad-upload").?;
    try testing.expectEqual(AssetState.failed, entry.state);
    try testing.expectEqual(
        @as(?anyerror, error.PumpMockUploadError),
        entry.last_error,
    );
    // Refcount is untouched — caller still owns the reference and
    // must `release` explicitly (per #442 state-transition contract).
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // CPU payload was freed by pump's drop-on-upload-failure branch.
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(u32, 1), PumpMock.upload_calls);
}

test "pump: worker-side decode error bubbles to .failed without touching upload" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    PumpMock.decode_fails = true;
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("bad-decode", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("bad-decode");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("bad-decode").?;
    try testing.expectEqual(AssetState.failed, entry.state);
    try testing.expectEqual(
        @as(?anyerror, error.PumpMockDecodeError),
        entry.last_error,
    );
    try testing.expectEqual(@as(u32, 0), PumpMock.upload_calls);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
}

test "pump: UPLOAD_BUDGET_PER_FRAME caps finalised uploads per call" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    // Enqueue double the budget + a bit more to prove multiple pumps
    // finish the drain without losing any results.
    const total: u8 = UPLOAD_BUDGET_PER_FRAME * 2 + 1;
    var name_buffers: [total][16]u8 = undefined;
    var names: [total][]const u8 = undefined;
    for (0..total) |i| {
        names[i] = std.fmt.bufPrint(&name_buffers[i], "asset_{d}", .{i}) catch unreachable;
        try catalog.register(names[i], .image, dummy_file_type, dummy_bytes);
        _ = try catalog.acquire(names[i]);
    }

    try spinForResults(&catalog, total);

    // First pump drains exactly UPLOAD_BUDGET_PER_FRAME.
    catalog.pump();
    var ready_after_first: u32 = 0;
    for (names) |n| {
        if (catalog.isReady(n)) ready_after_first += 1;
    }
    try testing.expectEqual(@as(u32, UPLOAD_BUDGET_PER_FRAME), ready_after_first);

    // Second pump picks up another budget worth.
    catalog.pump();
    var ready_after_second: u32 = 0;
    for (names) |n| {
        if (catalog.isReady(n)) ready_after_second += 1;
    }
    try testing.expectEqual(@as(u32, UPLOAD_BUDGET_PER_FRAME * 2), ready_after_second);

    // Third pump drains the remainder (1 leftover).
    catalog.pump();
    var ready_final: u32 = 0;
    for (names) |n| {
        if (catalog.isReady(n)) ready_final += 1;
    }
    try testing.expectEqual(@as(u32, total), ready_final);

    // Release every entry through the catalog so the mock's unload
    // counter balances the upload counter — `release` on a `.ready`
    // entry now fires `vtable.free` per #446.
    for (names) |n| {
        catalog.release(n);
    }
    try testing.expectEqual(@as(u32, total), PumpMock.unload_calls);
}

test "pump: empty result ring is a no-op even with an active worker" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    // Register + acquire to spawn the worker, then immediately release
    // + pump before anything has been decoded. The worker may have
    // raced and produced a result; that is fine — the zombie path
    // handles it. The core assertion is "no panic, no leak".
    try catalog.register("ghost", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("ghost");
    catalog.release("ghost");
    catalog.pump();

    const entry = catalog.entries.getPtr("ghost").?;
    // Either the worker never got there (state stuck at .queued) or
    // pump drained the zombie (state == .registered). Both are legal.
    try testing.expect(entry.state == .queued or entry.state == .registered);
}

// ---------------------------------------------------------------------
// release() tests (#446)
// ---------------------------------------------------------------------
//
// Focused on the `.ready` refcount-to-zero path: `release` must call
// `vtable.free` so backend handles (GPU textures today, audio devices /
// font atlases later) are returned to the backend. Before #446 the
// catalog only cleared CPU state and rewound to `.registered`, which
// leaked the texture handle for the whole program lifetime.

test "release on .ready entry with refcount 1 calls vtable.free and rewinds state" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("ship");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);

    // The single-owner release: refcount hits zero, `.ready` path
    // fires `vtable.free` which hands the texture back to the backend,
    // clears `entry.resource`, and rewinds state for a future acquire.
    catalog.release("ship");

    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
    try testing.expect(!catalog.isReady("ship"));
}

test "release on .ready entry with refcount > 1 decrements without unload" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("shared", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("shared");
    _ = try catalog.acquire("shared");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("shared").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expectEqual(@as(u32, 2), entry.refcount);

    // First release: two owners → one owner. No unload, state stays
    // `.ready`, resource is still live.
    catalog.release("shared");
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);

    // Second release drops to zero: backend unload fires exactly once.
    catalog.release("shared");
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
}

test "acquire after release round-trips cleanly on a ready asset" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);

    // Round 1: acquire → decode → pump → ready → release.
    _ = try catalog.acquire("ship");
    try spinForResults(&catalog, 1);
    catalog.pump();
    try testing.expect(catalog.isReady("ship"));

    catalog.release("ship");
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
    try testing.expect(!catalog.isReady("ship"));

    // Round 2: fresh acquire re-enqueues through the worker, pump
    // finalises, state is `.ready` again with a NEW texture handle.
    _ = try catalog.acquire("ship");
    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(u32, 2), PumpMock.decode_calls);
    try testing.expectEqual(@as(u32, 2), PumpMock.upload_calls);
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);

    // Final release balances the books for the catalog's deinit.
    catalog.release("ship");
    try testing.expectEqual(@as(u32, 2), PumpMock.unload_calls);
}

test "release on .failed entry decrements refcount without calling free" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    PumpMock.upload_fails = true;
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("broken", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("broken");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("broken").?;
    try testing.expectEqual(AssetState.failed, entry.state);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(u32, 1), entry.refcount);

    // `.failed` has no resource to free and pump already dropped the
    // CPU payload, so `release` never calls the vtable's `free`. On
    // refcount-to-zero we rewind to `.registered` (clearing
    // `last_error`) so a later `acquire` can retry a transient
    // failure cleanly — leaving the entry stuck at `.failed` forever
    // would permanently brick it for no benefit.
    catalog.release("broken");
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?anyerror, null), entry.last_error);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);
}

test "release past zero on a released .ready entry is idempotent" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("once", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("once");
    try spinForResults(&catalog, 1);
    catalog.pump();

    // First release frees. Second + third releases are no-ops — no
    // double unload, no double free, testing.allocator stays happy.
    catalog.release("once");
    catalog.release("once");
    catalog.release("once");

    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);

    const entry = catalog.entries.getPtr("once").?;
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
}

test "deinit frees leftover .ready entries so GPU handles do not leak" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);

    try catalog.register("leaky", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("leaky");
    try spinForResults(&catalog, 1);
    catalog.pump();

    // Intentionally skip `release` — simulate a game teardown where
    // the scene forgot to balance acquires. `deinit` must still hand
    // the GPU handle back to the backend.
    catalog.deinit();

    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
}
