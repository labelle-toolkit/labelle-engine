//! Integration tests for the real font loader (#448, Phase 4).
//!
//! Mirrors `test/asset_catalog_test.zig`'s image-loader pattern but
//! exercises the font-specific bits the image loader can't reach:
//!
//! 1. `FontBakeParams` plumbing — the catalog must hand the params
//!    pointer to the worker, the worker forwards it to `vtable.decode`,
//!    and the font loader `@ptrCast`s it back to its own type.
//! 2. The `FontId` resource lands on `entry.resource.?.font` and
//!    `release` reaches `vtable.free`, which calls the backend's
//!    `unload` exactly once.
//! 3. Two registrations under different `FontBakeParams` produce two
//!    independent entries — proving the per-entry params slot survives
//!    round-trip through the worker.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const font_loader = engine.FontLoader;
const font_types_mod = engine.font_types_mod;

/// Mock backend recording every call. `decode` returns a fixed 1×1
/// alpha bitmap + 1-glyph table, all allocated through the caller's
/// allocator so `testing.allocator` (a GPA) catches any leak or
/// double-free. `upload` returns a sentinel `FontId` so the round-
/// trip can assert on a known value.
const MockBackend = struct {
    // `decodeFn` runs on any of the catalog's worker threads (3 of them,
    // round-robin), so its counters must be atomic — the second test
    // dispatches two registrations that can land on different workers
    // and race a non-atomic `+= 1`, which is what caused the
    // intermittent `decode_calls == 1` failure on macOS (issue #583).
    // `uploadFn` / `unloadFn` run on the main thread inside `pump()` /
    // `release()`, so plain `var` is fine for those.
    var decode_calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    /// Last `pixel_height` seen by `decodeFn`. The second test
    /// dispatches two registrations whose `decodeFn` invocations can
    /// land on different worker threads and write this concurrently,
    /// so the slot must be atomic — even though only the first test
    /// reads it. Zig has no built-in atomic float, so the `f32` bits
    /// are carried inside an atomic `u32` via `@bitCast`.
    var last_pixel_height: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0.0)));
    /// One slot per upload so the second round-trip can assert that
    /// the catalog handed back the second sentinel, not the first.
    var last_uploaded_id: engine.FontId = engine.FontId.invalid;
    var last_unloaded_id: engine.FontId = engine.FontId.invalid;

    /// First sentinel returned by `uploadFn`. Tests assert on this.
    const sentinel_a: engine.FontId = .{ .index = 11, .generation = 3 };
    const sentinel_b: engine.FontId = .{ .index = 22, .generation = 5 };

    fn reset() void {
        decode_calls.store(0, .seq_cst);
        upload_calls = 0;
        unload_calls = 0;
        last_pixel_height.store(@bitCast(@as(f32, 0.0)), .seq_cst);
        last_uploaded_id = engine.FontId.invalid;
        last_unloaded_id = engine.FontId.invalid;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        params: engine.FontBakeParams,
        allocator: std.mem.Allocator,
    ) anyerror!engine.DecodedFont {
        _ = file_type;
        _ = data;
        _ = decode_calls.fetchAdd(1, .seq_cst);
        last_pixel_height.store(@bitCast(params.pixel_height), .seq_cst);

        const bitmap = try allocator.alloc(u8, 1);
        bitmap[0] = 0xFF;

        const glyphs = try allocator.alloc(font_types_mod.Glyph, 1);
        glyphs[0] = .{
            .u0 = 0,
            .v0 = 0,
            .u1 = 1,
            .v1 = 1,
            .xoff = 0.0,
            .yoff = 0.0,
            .advance = params.pixel_height,
        };

        const index = try allocator.alloc(font_types_mod.CodepointEntry, 1);
        index[0] = .{ .codepoint = 'A', .glyph_index = 0 };

        const kerning = try allocator.alloc(font_types_mod.KernPair, 0);

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

    fn uploadFn(decoded: engine.DecodedFont) anyerror!engine.FontId {
        _ = decoded;
        upload_calls += 1;
        const id = if (upload_calls == 1) sentinel_a else sentinel_b;
        last_uploaded_id = id;
        return id;
    }

    fn unloadFn(id: engine.FontId) void {
        unload_calls += 1;
        last_unloaded_id = id;
    }

    const backend_value: engine.FontBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

/// Spin until at least `at_least` results are pending across all
/// worker result rings, or 200ms elapses. Same shape as the image
/// loader's `spinForResults` in `src/assets/catalog.zig`.
fn spinForResults(catalog: *engine.AssetCatalog, at_least: u32) !void {
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        var total: u32 = 0;
        for (&catalog.results) |*ring| {
            const head = ring.head.load(.acquire);
            const tail = ring.tail.load(.acquire);
            total += head -% tail;
        }
        if (total >= at_least) return;
        { var _req: std.c.timespec = .{ .sec = (step_ns / std.time.ns_per_s), .nsec = (step_ns % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    }
    return error.WorkerDidNotRespond;
}

test "font loader: registerFont → acquire → pump → ready → release round-trip" {
    MockBackend.reset();
    font_loader.setBackend(MockBackend.backend_value);
    defer font_loader.clearBackend();

    var catalog = engine.AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    // Static-lifetime params so the pointer the catalog borrows stays
    // valid for the full decode/upload round-trip. `const` would also
    // work; `var` lets us tweak `pixel_height` per test if needed.
    var params: engine.FontBakeParams = .{ .pixel_height = 18.0 };

    try catalog.registerFont("title", "ttf", "fake-ttf-bytes", &params);

    // Before acquire: registered, refcount 0, params pointer parked
    // on the entry waiting for the worker to receive it.
    const initial = catalog.entries.getPtr("title").?;
    try testing.expectEqual(engine.AssetState.registered, initial.state);
    try testing.expect(initial.params != null);

    _ = try catalog.acquire("title");

    try spinForResults(&catalog, 1);
    catalog.pump();

    // After pump: state .ready, resource carries the sentinel FontId,
    // and the mock saw the pixel_height we registered — proving the
    // params plumbing survived the catalog → worker → loader trip.
    const entry = catalog.entries.getPtr("title").?;
    try testing.expectEqual(engine.AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(MockBackend.sentinel_a, entry.resource.?.font);
    try testing.expectEqual(@as(u32, 1), MockBackend.decode_calls.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), MockBackend.upload_calls);
    try testing.expectEqual(@as(f32, 18.0), @as(f32, @bitCast(MockBackend.last_pixel_height.load(.seq_cst))));
    try testing.expect(catalog.isReady("title"));

    // release on a `.ready` entry triggers `vtable.free`, which calls
    // the backend's `unload` exactly once and clears
    // `entry.resource` / rewinds state to `.registered`.
    catalog.release("title");
    try testing.expectEqual(@as(u32, 1), MockBackend.unload_calls);
    try testing.expectEqual(MockBackend.sentinel_a, MockBackend.last_unloaded_id);
    try testing.expectEqual(@as(?engine.UploadedResource, null), entry.resource);
    try testing.expectEqual(engine.AssetState.registered, entry.state);
    try testing.expect(!catalog.isReady("title"));
}

test "font loader: two registrations with different pixel_height keep params independent" {
    MockBackend.reset();
    font_loader.setBackend(MockBackend.backend_value);
    defer font_loader.clearBackend();

    var catalog = engine.AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    // Two distinct params blocks. Both addresses are stable for the
    // duration of the test, satisfying the borrowed-lifetime contract
    // on `entry.params`.
    var params_small: engine.FontBakeParams = .{ .pixel_height = 12.0 };
    var params_large: engine.FontBakeParams = .{ .pixel_height = 48.0 };

    try catalog.registerFont("body", "ttf", "fake-bytes-1", &params_small);
    try catalog.registerFont("display", "ttf", "fake-bytes-2", &params_large);

    // The catalog should store each entry's params pointer verbatim.
    const body_entry = catalog.entries.getPtr("body").?;
    const display_entry = catalog.entries.getPtr("display").?;
    try testing.expectEqual(
        @as(?*const anyopaque, @ptrCast(&params_small)),
        body_entry.params,
    );
    try testing.expectEqual(
        @as(?*const anyopaque, @ptrCast(&params_large)),
        display_entry.params,
    );

    // Acquire both and let the worker(s) decode. Acquire order doesn't
    // matter — round-robin dispatch may put them on different workers.
    _ = try catalog.acquire("body");
    _ = try catalog.acquire("display");

    try spinForResults(&catalog, 2);
    // Pump twice to drain both — `UPLOAD_BUDGET_PER_FRAME` is 4 so a
    // single pump would suffice, but two keeps the test honest about
    // independent finalisation.
    catalog.pump();
    catalog.pump();

    try testing.expect(catalog.isReady("body"));
    try testing.expect(catalog.isReady("display"));
    try testing.expectEqual(@as(u32, 2), MockBackend.decode_calls.load(.seq_cst));
    try testing.expectEqual(@as(u32, 2), MockBackend.upload_calls);

    // The two entries carry distinct `FontId`s — the catalog produced
    // two independent backend handles, not one shared one.
    const body_id = catalog.entries.getPtr("body").?.resource.?.font;
    const display_id = catalog.entries.getPtr("display").?.resource.?.font;
    try testing.expect(!std.meta.eql(body_id, display_id));

    // Balance both refcounts so deinit's leftover-`.ready` sweep
    // doesn't double-unload.
    catalog.release("body");
    catalog.release("display");
    try testing.expectEqual(@as(u32, 2), MockBackend.unload_calls);
}
