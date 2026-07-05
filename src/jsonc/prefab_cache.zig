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
    /// Directories already walked by `scanRegistry`/`scanDir`, keyed
    /// by the (trailing-slash-normalized) path. The eager scan is
    /// idempotent: a second `loadScene` (a normal scene reload —
    /// e.g. F9 in the games) re-runs the scan into this same
    /// game-lifetime cache, and a directory already in this set is
    /// skipped rather than re-walked. Without this, the second scan
    /// would re-encounter every already-registered file and wrongly
    /// raise `error.DuplicatePrefabName`. A genuine collision between
    /// two *distinct* files in a not-yet-scanned directory still
    /// errors. Keys are duped into `persistent` (game-lifetime).
    ///
    /// An entry is added *only after* a directory's walk completes
    /// successfully — a walk aborted by `error.DuplicatePrefabName`
    /// (or any other mid-walk failure) leaves the directory un-marked
    /// so a later reload (after the user fixes the collision) can
    /// retry the scan instead of being permanently locked out.
    scanned_dirs: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, prefab_dir: []const u8) PrefabCache {
        const persistent = persistent_allocator;
        return .{
            .prefabs = std.StringHashMap(Value).init(persistent),
            .persistent = persistent,
            .temp = allocator,
            .prefab_dir = prefab_dir,
            .scanned_dirs = std.StringHashMap(void).init(persistent),
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

    /// Replace — or insert — the registry entry for a prefab from an
    /// in-memory JSONC source: the labelle-studio Play-mode hot-reload
    /// path (`editor_api.editor_reload_prefab`, studio issue #24).
    ///
    /// Transactional: the source is parsed and shape-checked BEFORE the
    /// registry is touched, so a malformed/half-saved file returns an
    /// error and every future spawn keeps using the previous definition.
    /// Rejected (validated at push time so the editor gets an error
    /// instead of silent future spawn failures):
    ///   * unparseable JSONC,
    ///   * a non-object top level (a prefab must be a single entity
    ///     object — array "bundles" are a scene-file shape),
    ///   * an RFC #560 §B2 violation (`prefab` reference + `children`).
    /// Deeper semantic problems (unknown components, cycles introduced
    /// through OTHER prefabs) surface at spawn time through the loader's
    /// existing gates, which log and return a null spawn without
    /// corrupting the world.
    ///
    /// Keying matches `addEmbeddedPrefab` / `scanDir`: the entry lands
    /// under the source's *effective name* (its `"name"` field when
    /// present, else `name`). Corollary: pushing a source whose `"name"`
    /// diverges from the old one REGISTERS the new name and leaves the
    /// previous entry (old name → old data) in place until restart —
    /// a rename, not an in-place edit.
    ///
    /// Ownership/graveyard: `source` is duped into `self.persistent`
    /// (the caller may free its buffer immediately), and a REPLACED
    /// `Value` tree is never freed — it stays allocated for the game's
    /// lifetime. That is load-bearing, not sloppiness: components on
    /// already-spawned entities hold `[]const u8` slices into the old
    /// tree (see the module header), and the editor can push while the
    /// sim is paused, when no tick will ever re-read them — the same
    /// retire-don't-free reasoning as `RuntimeAnimDefs`, obtained here
    /// for free because the cache's persistent allocator never frees.
    /// On the error paths the partial parse leaks into `persistent` the
    /// same harmless way `scanDir`'s error path documents.
    ///
    /// Desktop caveat: an entry pushed for a file living in a directory
    /// `scanDir` has NOT yet walked will make that later first-time scan
    /// fail with `error.DuplicatePrefabName` (the scan treats the pushed
    /// key as a collision). Unreachable from the studio — its wasm games
    /// never run the filesystem scan and always boot a scene (scan done)
    /// before any push.
    pub fn replaceFromSource(
        self: *PrefabCache,
        log: anytype,
        name: []const u8,
        source: []const u8,
    ) error{ OutOfMemory, InvalidFormat }!void {
        const src = try self.persistent.dupe(u8, source);
        var parser = JsoncParser.init(self.persistent, src);
        const val = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.err("[prefab-reload] '{s}': source does not parse ({s}) — keeping the previous definition", .{ name, @errorName(err) });
                return error.InvalidFormat;
            },
        };
        const obj = val.asObject() orelse {
            log.err("[prefab-reload] '{s}': top level must be an object (a prefab is a single entity) — keeping the previous definition", .{name});
            return error.InvalidFormat;
        };
        // RFC #560 §B2 at push time — mirrors the gate every use site
        // re-checks (`spawnPrefabImpl`), but failing HERE keeps the old
        // definition live instead of installing one that can never spawn.
        uf.rejectB2Violation(uf.rootObject(obj), log, "hot-reloaded prefab root") catch {
            return error.InvalidFormat;
        };

        const key = uf.effectiveName(obj, name);
        if (self.prefabs.getPtr(key)) |existing| {
            // Replace in place — the map keeps its own key allocation;
            // the old Value tree is retired (never freed, see above).
            existing.* = val;
        } else {
            // Insert. `key` may alias the caller's `name` buffer (freed
            // right after the call), so the map needs its own copy.
            const duped_key = try self.persistent.dupe(u8, key);
            try self.prefabs.put(duped_key, val);
        }
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
    //
    // Strip a trailing slash first: `dirname("foo/prefabs/")` returns
    // `"foo/prefabs"`, which would derive `foo/prefabs/scenes` instead
    // of the intended sibling `foo/scenes`.
    const normalized = std.mem.trimEnd(u8, prefab_dir, "/");
    const parent = std.fs.path.dirname(normalized);
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
///
/// Transactional: parsed entries are staged in a local map and
/// committed into `cache.prefabs` only after the *entire* walk
/// completes without error. A walk aborted partway (e.g. by
/// `error.DuplicatePrefabName` on a collision the user is about to
/// fix) leaves `cache.prefabs` and `cache.scanned_dirs` untouched, so
/// a subsequent reload — after the user removes one of the colliding
/// files — re-runs the walk and succeeds. Without staging, a partial
/// first walk would leave half-populated cache entries that either
/// shadow the now-canonical file or self-collide on the retry.
///
/// Idempotent across normal reloads: a directory recorded in
/// `cache.scanned_dirs` (from a previous *successful* walk on this
/// game-lifetime cache) is skipped entirely, so a normal scene reload
/// (e.g. F9) does not re-register — and thus does not falsely collide
/// on — files the first scan already cached.
fn scanDir(cache: *PrefabCache, log: anytype, dir_path: []const u8) !void {
    const io = io_helper.io();

    // Skip directories already walked by a previous successful scan.
    // Normalize a trailing slash so `prefabs` and `prefabs/` map to
    // one key.
    const dir_key = std.mem.trimEnd(u8, dir_path, "/");
    if (cache.scanned_dirs.contains(dir_key)) return;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(cache.temp);
    defer walker.deinit();

    // Stage this walk's inserts in a temp-allocator map. We commit
    // them into `cache.prefabs` only after the loop completes without
    // error. If the loop returns early (e.g. duplicate-name), the
    // staging map is discarded by `deinit`, leaving the persistent
    // cache untouched. The parsed `Value` trees and their backing
    // `src` buffers are themselves in `cache.persistent` (game-
    // lifetime, page-allocator) and harmlessly leaked on the error
    // path — same property the rest of the cache relies on.
    var staged = std.StringHashMap(Value).init(cache.temp);
    defer staged.deinit();

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

        // Collisions are checked against both the already-committed
        // cache and the current walk's staging map — two distinct
        // files in this walk that share an effective name must error
        // even though neither is in `cache.prefabs` yet.
        if (cache.prefabs.contains(key) or staged.contains(key)) {
            log.err("[registry] duplicate name '{s}' (from '{s}'): rename the file or give one a distinct \"name\" (RFC #561)", .{ key, entry.path });
            return error.DuplicatePrefabName;
        }
        // Stage with a persistent-allocator key: it will be moved into
        // `cache.prefabs` (which uses `cache.persistent`) on commit.
        try staged.put(try cache.persistent.dupe(u8, key), val);
    }

    // Commit: walk succeeded, fold the staged entries into the
    // permanent cache and mark the directory done.
    var it = staged.iterator();
    while (it.next()) |kv| {
        try cache.prefabs.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    try cache.scanned_dirs.put(try cache.persistent.dupe(u8, dir_key), {});
}
