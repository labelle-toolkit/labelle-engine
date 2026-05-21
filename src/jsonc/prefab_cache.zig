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

// ── Eager filesystem registry scan (RFC #560, ticket #561) ──────────
//
// On desktop, the flat name-keyed registry is populated up-front by
// recursively walking the project's `prefabs/` and `scenes/`
// directories. This is what makes a file resolvable by an effective
// name (its `"name"` field) that diverges from its filename basename,
// and what lets cross-file effective-name collisions be caught as a
// hard load-time error instead of silently shadowing.
//
// It is the filesystem counterpart of `addEmbeddedPrefab`, which the
// assembler emits for WASM/mobile builds (no filesystem). WASM/mobile
// must NOT run this scan — `std.Io` is `failing` there (see
// `io_helper.zig`) and prefabs arrive exclusively via the embedded
// path. The scan is therefore gated on a non-emscripten target, and
// additionally skips any directory it cannot open (a desktop project
// may legitimately ship only one of `prefabs/`/`scenes/`).

const is_wasm_emscripten = builtin.target.os.tag == .emscripten;

/// Recursively scan a project's `prefabs/` and `scenes/` directories
/// into the flat name-keyed registry held by `cache`.
///
/// `prefab_dir` is the project's prefab directory (the same value
/// passed to `loadScene`); the sibling `scenes/` directory is derived
/// by convention — `<dirname(prefab_dir)>/scenes`. Either directory
/// may be absent; a missing directory is skipped, not an error.
///
/// Each `.jsonc` file is parsed and keyed by its *effective name*
/// (`unified_format.effectiveName` — its `"name"` field if present,
/// else the filename basename without the extension). A duplicate
/// effective name across any two scanned files raises
/// `error.DuplicatePrefabName` — mirrors `addEmbeddedPrefab`; there
/// is no precedence rule, the author renames a file or sets a
/// distinct `"name"`.
///
/// No-op on WASM/mobile (`wasm32-emscripten`) — those builds rely on
/// the assembler-emitted embedded prefab/scene sources and have no
/// filesystem.
pub fn scanRegistry(cache: *PrefabCache, log: anytype, prefab_dir: []const u8) !void {
    if (is_wasm_emscripten) return;

    try scanDir(cache, log, prefab_dir);

    // Derive the sibling `scenes/` directory by convention. The
    // project layout is `<project>/prefabs` + `<project>/scenes`, so
    // replace the prefab dir's last path component with `scenes`.
    const parent = std.fs.path.dirname(prefab_dir);
    const scenes_dir = if (parent) |p|
        try std.fs.path.join(cache.temp, &.{ p, "scenes" })
    else
        try cache.temp.dupe(u8, "scenes");
    defer cache.temp.free(scenes_dir);

    try scanDir(cache, log, scenes_dir);
}

/// Recursively walk one directory, parsing every `.jsonc` file into
/// the cache keyed by effective name. A directory that cannot be
/// opened (typically absent) is silently skipped.
fn scanDir(cache: *PrefabCache, log: anytype, dir_path: []const u8) !void {
    const io = io_helper.io();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(cache.temp);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".jsonc")) continue;

        // Read + parse into the persistent allocator: the parsed
        // `Value` tree is game-lifetime data (deserialized components
        // hold slices into it), the same contract as `get`.
        const src = entry.dir.readFileAlloc(io, entry.basename, cache.persistent, .limited(1024 * 1024)) catch |err| {
            log.warn("[registry] failed to read '{s}': {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        var parser = JsoncParser.init(cache.persistent, src);
        const val = parser.parse() catch |err| {
            log.warn("[registry] failed to parse '{s}': {s}", .{ entry.path, @errorName(err) });
            continue;
        };

        // Effective name = `"name"` field, else filename basename
        // without the `.jsonc` extension.
        const basename = entry.basename[0 .. entry.basename.len - ".jsonc".len];
        const key = if (val.asObject()) |obj| uf.effectiveName(obj, basename) else basename;

        if (cache.prefabs.contains(key)) {
            log.err("[registry] duplicate name '{s}' (from '{s}'): rename the file or give one a distinct \"name\" (RFC #561)", .{ key, entry.path });
            return error.DuplicatePrefabName;
        }
        try cache.prefabs.put(try cache.persistent.dupe(u8, key), val);
    }
}
