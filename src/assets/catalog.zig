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
pub const AssetLoaderVTable = loader_mod.AssetLoaderVTable;
pub const AssetState = loader_mod.AssetState;
pub const AssetEntry = loader_mod.AssetEntry;
pub const WorkRequest = worker_mod.WorkRequest;
pub const WorkResult = worker_mod.WorkResult;

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
                if (self.entries.getPtr(result.entry_name)) |entry| {
                    entry.loader.drop(self.allocator, payload);
                }
            }
        }

        // TODO(#446): iterate and call entry.loader.free for any entry
        // that is still `.ready` so GPU/audio/font handles go back to
        // their backends. Current placeholder loaders have no-op free,
        // so this is safe until real loaders arrive.
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
        const entry = self.entries.getPtr(name) orelse return error.AssetNotRegistered;
        const was_zero = entry.refcount == 0;
        entry.refcount += 1;

        if (was_zero and entry.state == .registered) {
            try self.ensureWorker();
            const request: WorkRequest = .{
                .entry_name = name,
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
                    .{name},
                ),
            }
        }
        return entry;
    }

    /// Drops the refcount. When it hits zero on a `.ready` entry, the
    /// CPU-side decoded payload is cleared and the entry is moved
    /// back to `.registered`. The matching GPU/audio/font free via
    /// `entry.loader.free` is wired in ticket #446.
    ///
    /// Releasing an unknown or already-zero entry is a no-op — the
    /// catalog never panics on a stale handle.
    pub fn release(self: *AssetCatalog, name: []const u8) void {
        const entry = self.entries.getPtr(name) orelse return;
        if (entry.refcount == 0) return;
        entry.refcount -= 1;
        if (entry.refcount != 0) return;

        if (entry.state == .ready) {
            // TODO(#446): entry.loader.free(entry); to release GPU /
            // audio / font handle. For now we just drop the CPU-side
            // payload reference and rewind the state.
            entry.decoded = null;
            entry.state = .registered;
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

    /// Drains worker results and finalises uploads. The real body
    /// lands in ticket #442 once #439's worker exists; for now this
    /// is a no-op so callers (and the future legacy shim in #443)
    /// can already wire it into their frame loop without churn.
    pub fn pump(self: *AssetCatalog) void {
        _ = self;
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
    // an `error.NotImplemented` result on the stub loader.
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

test "pump is a no-op until the worker lands (#442)" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    catalog.pump();
    try testing.expect(!catalog.isReady("background"));
}

test "acquire spawns worker which produces NotImplemented for stub loader" {
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
    try testing.expectEqual(@as(?anyerror, error.NotImplemented), result.err);
}

test "deinit with a pending acquire shuts down cleanly" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("background");
    // Intentionally do not drain — deinit must join the worker and
    // drop any in-flight results without deadlocking or leaking.
}
