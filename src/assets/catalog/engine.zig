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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const loader_mod = @import("../loader.zig");
const worker_mod = @import("../worker.zig");

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

/// Number of decode worker threads. Each owns its own SPSC request +
/// result ring pair — keeps the existing single-producer / single-
/// consumer ring invariants untouched. 3 is a sensible default on a
/// quad-core big.LITTLE tablet (leaves one performance core for the
/// main + render threads); override by changing this constant.
pub const NUM_WORKERS: u8 = 3;

comptime {
    // `acquire` and `pump` both use `% NUM_WORKERS` — a zero here
    // would trap at runtime. Guard at compile time instead.
    if (NUM_WORKERS == 0) @compileError("NUM_WORKERS must be >= 1");
}

pub const AssetCatalog = struct {
    allocator: Allocator,
    entries: std.StringHashMap(AssetEntry),
    /// Main → worker rings (one per worker). The catalog is the sole
    /// producer for each ring (via `acquire`); each worker is the sole
    /// consumer of its own ring.
    requests: [NUM_WORKERS]worker_mod.RequestRing,
    /// Worker → main rings (one per worker). Each worker is the sole
    /// producer of its own ring; `pump()` is the sole consumer across all.
    results: [NUM_WORKERS]worker_mod.ResultRing,
    workers: [NUM_WORKERS]worker_mod.AssetWorker,
    workers_started: bool,
    /// Round-robin dispatch counter for `acquire`. Wraps; used modulo
    /// NUM_WORKERS to pick the target request ring so decode load is
    /// spread across cores.
    dispatch_counter: u32,
    /// Rotation cursor for `pump`'s result-ring scan. Persists across
    /// frames so fairness isn't tied to `acquire` cadence — if several
    /// frames pass without new work, the next `pump` still starts
    /// where the last one left off.
    pump_cursor: u8,
    /// `true` while the GPU surface is alive. Cleared by
    /// `invalidateGpuResources` (Android TERM_WINDOW) and restored by
    /// `reenqueueGpuResident` (INIT_WINDOW). While `false`, `pump`'s
    /// happy-path upload branch must not run — uploading into a dead
    /// context would `destroyTexture` a stale handle / crash the
    /// backend. See the GPU-context-loss design notes on
    /// `invalidateGpuResources` below (epic #386 Phase 4).
    gpu_alive: bool,

    /// Builds the catalog. The worker thread is spawned lazily on
    /// the first `acquire` — this keeps `init`'s signature infallible
    /// relative to `std.Thread.spawn` failures *and* dodges the
    /// classic "return-by-value captures a stack pointer" trap: the
    /// rings need to live at a stable address before the worker
    /// captures `&self.requests`, and the stable address only exists
    /// once the caller has moved the returned value into its own
    /// slot.
    pub fn init(allocator: Allocator) AssetCatalog {
        var requests: [NUM_WORKERS]worker_mod.RequestRing = undefined;
        var results: [NUM_WORKERS]worker_mod.ResultRing = undefined;
        for (0..NUM_WORKERS) |i| {
            requests[i] = worker_mod.RequestRing.init();
            results[i] = worker_mod.ResultRing.init();
        }
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(AssetEntry).init(allocator),
            .requests = requests,
            .results = results,
            .workers = undefined,
            .workers_started = false,
            .dispatch_counter = 0,
            .pump_cursor = 0,
            .gpu_alive = true,
        };
    }

    /// Ensures the background worker pool is running. Idempotent.
    /// Called from `acquire` on the first `0 → 1` refcount transition
    /// so catalogs that never `acquire` (e.g. most unit tests) don't
    /// pay the thread-spawn cost at all.
    fn ensureWorker(self: *AssetCatalog) !void {
        if (self.workers_started) return;

        // Init all workers first so their ring pointers are stable
        // before any thread captures them.
        for (0..NUM_WORKERS) |i| {
            self.workers[i] = worker_mod.AssetWorker.init(
                self.allocator,
                &self.requests[i],
                &self.results[i],
            );
        }

        // Spawn threads one by one. If any spawn fails, stop the ones
        // we started so the caller isn't left with half a pool running
        // and `workers_started` out of sync with reality.
        var spawned: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < spawned) : (i += 1) self.workers[i].stop();
        }
        while (spawned < NUM_WORKERS) : (spawned += 1) {
            try self.workers[spawned].start();
        }
        self.workers_started = true;
    }

    pub fn deinit(self: *AssetCatalog) void {
        // 1. Stop every worker (sets shutdown flags, joins threads).
        //    Only meaningful if `acquire` ever ran — otherwise
        //    `workers` is undefined.
        if (self.workers_started) {
            for (&self.workers) |*w| w.stop();
            self.workers_started = false;
        }

        // 2. Drain any in-flight results across every result ring.
        //    Real loaders have allocator-owned CPU payloads here; we
        //    hand them to the vtable's drop hook so nothing leaks.
        for (&self.results) |*ring| {
            while (ring.tryDequeue()) |result| {
                if (result.decoded) |payload| {
                    // Use the vtable carried on the result itself — avoids
                    // a hashmap lookup and survives the case where an entry
                    // was removed after its WorkRequest was submitted.
                    result.vtable.drop(self.allocator, payload);
                }
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
        return self.registerWithParams(name, loader_kind, file_type, bytes, null);
    }

    /// Metadata + decode-parameters registration. Same lifetime
    /// contract as `register`: every borrowed slice (`name`,
    /// `file_type`, `bytes`) AND the `params` pointer must outlive the
    /// catalog entry. Used by `registerFont` to attach a
    /// `*const FontBakeParams` so the worker can hand it to the font
    /// loader's `decode` via `WorkRequest.params`.
    pub fn registerWithParams(
        self: *AssetCatalog,
        name: []const u8,
        loader_kind: LoaderKind,
        file_type: [:0]const u8,
        bytes: []const u8,
        params: ?*const anyopaque,
    ) !void {
        if (self.entries.contains(name)) return error.AssetAlreadyRegistered;
        try self.entries.put(name, .{
            .state = .registered,
            .refcount = 0,
            .loader = loaderForKind(loader_kind),
            .loader_kind = loader_kind,
            .raw_bytes = bytes,
            .file_type = file_type,
            .params = params,
            .decoded = null,
            .resource = null,
            .last_error = null,
        });
    }

    /// Convenience wrapper for the font loader: registers under
    /// `LoaderKind.font` and attaches the `FontBakeParams` pointer
    /// the worker must forward into the loader's `decode`.
    ///
    /// `params` is borrowed (not copied) under the same `@embedFile`
    /// lifetime contract that governs the other slices on the entry.
    /// Pass a pointer to a `static const` or assembler-generated
    /// global; tests use a function-local `var` whose address is
    /// stable for the duration of the catalog.
    pub fn registerFont(
        self: *AssetCatalog,
        name: []const u8,
        file_type: [:0]const u8,
        bytes: []const u8,
        params: *const font_loader.FontBakeParams,
    ) !void {
        return self.registerWithParams(name, .font, file_type, bytes, @ptrCast(params));
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
            try self.enqueueDecode(kv.key_ptr.*, entry);
        }
        entry.refcount += 1;
        return entry;
    }

    /// Enqueues a decode `WorkRequest` for `entry` and flips its state
    /// to `.queued`. Factored out of `acquire` so the GPU-context-loss
    /// re-enqueue path (`reenqueueGpuResident`) can re-fire a decode
    /// without going through `acquire`'s refcount/needs-enqueue logic.
    ///
    /// `key` is the stable hashmap-owned key slice (program-lifetime per
    /// the `@embedFile` invariant) — never a caller-supplied temporary,
    /// since the worker borrows it on the request ring.
    ///
    /// Spawns the worker pool first; on `ensureWorker` failure the error
    /// bubbles with the entry's state unchanged. If the picked request
    /// ring is full, logs and leaves the state at `.registered` — a
    /// later acquire / re-enqueue retries.
    fn enqueueDecode(self: *AssetCatalog, key: []const u8, entry: *AssetEntry) !void {
        // Spawn the worker pool BEFORE touching state. If thread spawn
        // fails, `try` bubbles the error with the catalog state
        // unchanged — no entry left trapped mid-transition.
        try self.ensureWorker();
        const request: WorkRequest = .{
            .entry_name = key,
            .vtable = entry.loader,
            .file_type = entry.file_type,
            .bytes = entry.raw_bytes,
            .params = entry.params,
        };
        // Round-robin across the worker pool so decode load is
        // spread. If the picked ring is full (shouldn't happen in
        // practice — 64-slot capacity vs. typical 6–30 atlases —
        // but the contract tolerates it), fall through to
        // `.registered` and let a future enqueue retry.
        const idx = self.dispatch_counter % NUM_WORKERS;
        self.dispatch_counter +%= 1;
        if (self.requests[idx].tryEnqueue(request)) |_| {
            entry.state = .queued;

            // `single_threaded` (WASM) has no worker thread
            // running — `start()` is a no-op there (issue #461).
            // Drain the request we just enqueued on the main
            // thread so the result lands in the result ring
            // before the next `pump()`.
            if (builtin.single_threaded) {
                self.workers[idx].runOnce();
            }
        } else |err| switch (err) {
            error.QueueFull => std.log.debug(
                "assets: request ring {d} full, deferring decode of '{s}'",
                .{ idx, key },
            ),
        }
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

    /// First `.failed` entry's error from `names`, or null when no
    /// entry is `.failed`. Used by the scene-manifest gate (Phase 2
    /// of RFC #437) to abort `setScene` with a meaningful error
    /// rather than spinning forever in the not-ready branch.
    pub fn anyFailed(self: *AssetCatalog, names: []const []const u8) ?anyerror {
        for (names) |name| {
            if (self.lastError(name)) |err| return err;
        }
        return null;
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
        // Rotate through the result rings so a burst from one worker
        // doesn't starve the others. Uses a dedicated `pump_cursor`
        // that persists across frames — decoupled from acquire's
        // `dispatch_counter`, which may sit idle for many frames after
        // the initial scene load.
        while (uploads_done < UPLOAD_BUDGET_PER_FRAME) {
            const result = blk: {
                var tried: u8 = 0;
                while (tried < NUM_WORKERS) : (tried += 1) {
                    const idx: u8 = @intCast((@as(usize, self.pump_cursor) + tried) % NUM_WORKERS);
                    // GPU context loss (Android TERM_WINDOW): leave any
                    // happy-path upload result PARKED on the ring so an
                    // in-flight decode landing mid-TERM doesn't upload
                    // into a dead context. Peek first; only consume the
                    // result if it's a cheap drain path (removed entry,
                    // zombie, or decode error — none of which touch the
                    // GPU). `reenqueueGpuResident` flips `gpu_alive` back
                    // on and the parked results upload then. The peek
                    // never advances `tail`, so the parked slot survives.
                    if (!self.gpu_alive) {
                        const peeked = self.results[idx].peek() orelse continue;
                        if (self.isGpuUploadResult(peeked)) continue;
                    }
                    if (self.results[idx].tryDequeue()) |r| {
                        self.pump_cursor = @intCast((@as(usize, idx) + 1) % NUM_WORKERS);
                        break :blk r;
                    }
                }
                return; // all rings empty (or all remaining are GPU-parked)
            };

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

    /// `true` if draining `result` from the ring would run the
    /// GPU-touching happy-path upload (branch 4 of `pump`) for a
    /// GPU-resident asset. Used by `pump` while `gpu_alive == false` to
    /// leave such results parked on the ring rather than uploading into
    /// a dead context.
    ///
    /// A result is GPU-bound only when it would reach branch (4) *and*
    /// its payload is an image:
    ///   * the entry still exists (else branch 1 — removed, GPU-free),
    ///   * refcount > 0 (else branch 2 — zombie, GPU-free),
    ///   * `err == null` (else branch 3 — decode error, GPU-free),
    ///   * `decoded` is an `.image` (audio/font uploads don't touch the
    ///     GPU surface that TERM_WINDOW destroyed, so they may drain).
    fn isGpuUploadResult(self: *AssetCatalog, result: WorkResult) bool {
        const entry = self.entries.getPtr(result.entry_name) orelse return false;
        if (entry.refcount == 0) return false;
        if (result.err != null) return false;
        const payload = result.decoded orelse return false;
        return payload == .image;
    }

    /// GPU surface lost (Android TERM_WINDOW / `surfaceLost`).
    ///
    /// TERM_WINDOW destroys every GPU texture but leaves game state and
    /// the CPU-side allocator intact. For each GPU-resident, `.ready`
    /// asset we drop the *stale* backend handle WITHOUT calling the
    /// loader's `free` vtable: `free` would `destroyTexture` a handle
    /// the driver has already invalidated, which is undefined behaviour
    /// on a dead context. Instead we null `entry.resource` directly and
    /// rewind state to `.registered`, leaving `refcount` untouched so
    /// the asset's holders stay valid. `reenqueueGpuResident` re-fires
    /// the decode → upload pipeline once the surface returns.
    ///
    /// Only `.image` assets are invalidated — `.audio` resources are
    /// not GPU-resident and survive context loss. Entries that are
    /// mid-flight (`.queued` / `.decoding`) or not yet uploaded
    /// (`.registered` / `.failed`) are left alone; the `gpu_alive` gate
    /// in `pump` handles an in-flight decode that lands during TERM.
    pub fn invalidateGpuResources(self: *AssetCatalog) void {
        self.gpu_alive = false;
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (entry.loader_kind != .image) continue;
            if (entry.state != .ready) continue;
            // Stale handle — the GPU context is gone. Do NOT call
            // `entry.loader.free`: that destroys a now-invalid texture
            // handle. Drop the slot directly.
            entry.resource = null;
            // `decoded` is already null on a `.ready` entry (pump nulls
            // it after a successful upload); kept explicit for clarity.
            entry.decoded = null;
            entry.state = .registered;
        }
    }

    /// GPU surface restored (Android INIT_WINDOW / `surfaceRestored`).
    ///
    /// Re-fires the decode → upload pipeline for every GPU-resident
    /// asset that `invalidateGpuResources` rewound to `.registered`
    /// while still referenced (`refcount > 0`). Goes through the shared
    /// `enqueueDecode` so the worker re-decodes the CPU bitmap (which
    /// `pump` freed after the original upload) and `pump` re-uploads
    /// into the fresh context — `acquire` would not re-enqueue here
    /// because refcount is already non-zero. Refcounts are never
    /// touched. Clears the `gpu_alive` gate first so the resulting
    /// uploads are no longer parked.
    pub fn reenqueueGpuResident(self: *AssetCatalog) void {
        self.gpu_alive = true;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr;
            if (entry.loader_kind != .image) continue;
            if (entry.refcount == 0) continue;
            if (entry.state != .registered) continue;
            // Best-effort: a transient ring-full / worker-spawn failure
            // leaves the entry at `.registered` for a later retry; a
            // restored surface must not be able to fail the frame loop.
            self.enqueueDecode(kv.key_ptr.*, entry) catch |err| {
                std.log.warn(
                    "assets: re-enqueue after surface restore failed for '{s}': {s}",
                    .{ kv.key_ptr.*, @errorName(err) },
                );
            };
        }
    }
};

// ---------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------

const image_loader = @import("../loaders/image.zig");
const audio_loader = @import("../loaders/audio.zig");
const font_loader = @import("../loaders/font.zig");

fn loaderForKind(kind: LoaderKind) *const AssetLoaderVTable {
    return switch (kind) {
        .image => &image_loader.vtable,
        .audio => &audio_loader.vtable,
        .font => &font_loader.vtable,
    };
}
