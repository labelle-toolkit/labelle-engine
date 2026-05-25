//! Prefab cache — loads and caches `Value` trees parsed from
//! `prefabs/*.jsonc` (or in-memory sources via `addEmbeddedPrefab`).
//!
//! Slice 4a of #495. Source buffers and parsed `Value` trees are
//! game-lifetime data — deserialized components hold `[]const u8`
//! slices referencing them. Uses `page_allocator` for persistent
//! data so the GPA doesn't report them as leaks.
//!
//! The cache lives behind `game.prefab_cache_ptr` (a `?*anyopaque`
//! slot on `Game`) so the bridge instantiates one cache and reuses
//! it across `loadScene`, `loadSceneFromSource`, and
//! `addEmbeddedPrefab`. The reuse contract is critical for mobile
//! builds — see the `!!! CRITICAL !!!` block in `bridge.zig`'s
//! `loadSceneFromSource`.

const std = @import("std");
const io_helper = @import("../io_helper.zig");
const builtin = @import("builtin");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const JsoncParser = jsonc.JsoncParser;
const uf = @import("unified_format.zig");

// Persistent allocator for game-lifetime data. On `wasm32-emscripten`
// we MUST go through libc (emscripten's malloc), because libc's
// allocator routes through `_emscripten_resize_heap` which calls
// `updateMemoryViews()` after `wasmMemory.grow()`. Zig's
// `page_allocator` resolves to `WasmAllocator` on emscripten and
// issues `@wasmMemoryGrow` directly — that bypasses the JS-side view
// rebinding, leaving `HEAPU32` detached, and the next `_fd_write`
// (i.e. the first `std.debug.print` after a page-alloc grow) aborts
// with a spurious "segmentation fault". Desktop targets keep
// `page_allocator` so GPA leak-detection ignores deliberately-unfreed
// game-lifetime allocations. See
// `labelle-cli/docs/wasm-segfault-investigation.md` (issue #196).
const persistent_allocator: std.mem.Allocator = if (builtin.target.os.tag == .emscripten)
    std.heap.c_allocator
else
    std.heap.page_allocator;

pub const PrefabCache = struct {
    prefabs: std.StringHashMap(Value),
    persistent: std.mem.Allocator,
    temp: std.mem.Allocator,
    prefab_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, prefab_dir: []const u8) PrefabCache {
        const persistent = persistent_allocator;
        return .{
            .prefabs = std.StringHashMap(Value).init(persistent),
            .persistent = persistent,
            .temp = allocator,
            .prefab_dir = prefab_dir,
        };
    }

    /// Lookup by name. Returns the cached `Value` tree if present;
    /// otherwise falls back to `<prefab_dir>/<name>.jsonc` on disk
    /// and caches the parse result. Filesystem fallback is desktop-
    /// only — mobile builds rely on `addEmbeddedPrefab` having
    /// pre-populated every prefab the project uses.
    ///
    /// The cache is keyed by *effective name* (RFC #561): a file
    /// `widget.jsonc` with `"name": "foo"` resolves and stores under
    /// `"foo"`. Matches `addEmbeddedPrefab`'s contract so the two
    /// registration paths share one flat registry — a disk load and
    /// an embedded source that both claim the same effective name
    /// collide rather than co-existing under different keys (#573).
    pub fn get(self: *PrefabCache, name: []const u8) ?Value {
        if (self.prefabs.get(name)) |val| return val;

        const path = std.fmt.allocPrint(self.temp, "{s}/{s}.jsonc", .{ self.prefab_dir, name }) catch return null;
        defer self.temp.free(path);
        const src = std.Io.Dir.cwd().readFileAlloc(io_helper.io(), path, self.persistent, .limited(1024 * 1024)) catch return null;
        var p = JsoncParser.init(self.persistent, src);
        const val = p.parse() catch return null;

        // Resolve to the effective name (the file's `"name"` field
        // when present, else the lookup string) and reject a
        // collision with an already-cached entry. Keeps disk and
        // embedded registrations on the same flat registry.
        const key = if (val.asObject()) |obj| uf.effectiveName(obj, name) else name;
        if (self.prefabs.contains(key)) return null;
        const duped_key = self.persistent.dupe(u8, key) catch return null;
        errdefer self.persistent.free(duped_key);
        self.prefabs.put(duped_key, val) catch return null;
        return val;
    }
};

/// Allocate a persistent `PrefabCache` and store it on the game's
/// `prefab_cache_ptr` slot. Returns the new cache pointer.
///
/// Generic over `GameType` so callers don't have to import the
/// engine's full `Game` type — any struct with a `prefab_cache_ptr:
/// ?*anyopaque` field and an `allocator` works.
pub fn initPersistentCache(game: anytype, prefab_dir: []const u8) !*PrefabCache {
    const persistent = persistent_allocator;
    const cache = try persistent.create(PrefabCache);
    cache.* = PrefabCache.init(game.allocator, prefab_dir);
    game.prefab_cache_ptr = cache;
    return cache;
}

/// Reuse the game's attached `PrefabCache` when one exists,
/// refreshing its `prefab_dir` so filesystem fallback lookups track
/// the current scene's directory. Otherwise allocate a fresh
/// persistent cache.
///
/// Shared by `loadScene`, `loadSceneFromSource`, and
/// `addEmbeddedPrefab` so the three entry points can never drift
/// apart on this critical path — the !!! CRITICAL !!! block in
/// `loadSceneFromSource` documents the mobile-build failure mode
/// this protects against.
pub fn getOrCreatePrefabCache(game: anytype, prefab_dir: []const u8) !*PrefabCache {
    if (game.prefab_cache_ptr) |ptr| {
        const cache = @as(*PrefabCache, @ptrCast(@alignCast(ptr)));
        cache.prefab_dir = prefab_dir;
        return cache;
    }
    return try initPersistentCache(game, prefab_dir);
}
