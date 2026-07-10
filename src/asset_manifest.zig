//! Sprite-based asset inference — the engine half of RFC-UNIFY-SCENES-AND-PREFABS
//! §"Assets — inference + lazy fallback over `AssetCatalog`" (labelle-engine#563).
//!
//! Today a scene must hand-maintain an explicit `{"meta":{"assets":[...]}}`
//! list naming every atlas/image bundle it needs (see `SceneEntry.assets`,
//! threaded by the assembler and gated in `scene_mixin.setScene`). That list
//! duplicates information already present in the scene: every `Sprite` and
//! `Image` component already *names* the visual it references. When the two
//! drift, you get either a silent black sprite (asset missing from the list)
//! or a wasted atlas load (stale entry). This module makes the list
//! **derivable** from the entity tree so it no longer has to be authored by
//! hand.
//!
//! Two pieces, matching the RFC's exact shape:
//!
//!   1. **Reverse index** (`ReverseIndex`) — maps every *sprite path* /
//!      *image asset name* to the resource bundle that provides it
//!      (`ResourceRef`). Built once at engine startup by parsing every entry
//!      in `project.labelle`'s `.resources`. Atlas entries contribute one key
//!      per sprite path (extracted from the TexturePacker JSON); standalone
//!      image entries contribute a single self-keyed entry. Name collisions
//!      are a load-time error (exact-match, case-sensitive) rather than a
//!      silent shadow.
//!
//!   2. **Walker** (`inferAssets`) — walks a scene/prefab entity tree
//!      (`std.json.Value`, the universal shape produced by the JSONC bridge)
//!      and, for every string in component data, looks it up in the reverse
//!      index. Hits union into the inferred resource set. `AssetManifest.load`
//!      declarations (the eager escape hatch for assets inference can't see —
//!      script-computed names, audio banks, runtime overlays) are unioned in
//!      directly. The result is a deduped, order-stable list of resource
//!      bundle names — exactly the shape of the current explicit
//!      `meta.assets` list, so an inferred manifest can *supplement or
//!      validate* an explicit one without breaking existing scenes.
//!
//! **Scope of this module / PR:** the reverse-index + walker *core*. It takes
//! no gfx dependency, touches no lifecycle, and reuses the existing
//! `AssetCatalog` for the actual acquire/decode/upload/release (Phase B).
//! Wiring the walker's output into `setScene`'s acquire gate (replacing the
//! Debug eager-load fallback) and building the reverse index from the real
//! `project.labelle` `.resources` at codegen time is assembler-side follow-up
//! — see the PR body. False-positive over-load auditing is #566.

const std = @import("std");
const jsonc = @import("jsonc");

/// Where a referenced sprite/image name lives. Unified across atlas-sprites
/// and standalone images so the walker and the lazy-on-miss path (#568)
/// consume one index. RFC §"Reverse index".
pub const ResourceRef = union(enum) {
    /// The named sprite path is provided by this atlas *bundle* — acquiring
    /// the bundle loads the whole atlas (and thus the sprite).
    atlas: []const u8,
    /// The name *is* a standalone image asset — acquire it directly.
    image: []const u8,

    /// The `AssetCatalog` resource key to `acquire` for this reference. For
    /// both variants this is the bundle/asset name (the payload); the tag
    /// only records *why* it resolves, which the renderer's lazy-on-miss
    /// path uses to pick `findSprite` vs `findImage`.
    pub fn resourceName(self: ResourceRef) []const u8 {
        return switch (self) {
            .atlas => |name| name,
            .image => |name| name,
        };
    }
};

/// The `AssetManifest` component (RFC §"`AssetManifest` component"). An eager
/// escape hatch: any prefab can carry `{"AssetManifest":{"load":[...]}}` on
/// its root (or any entity) to pre-load resources the walker can't infer from
/// a `Sprite`/`Image` reference — script-computed sprite names, audio banks,
/// runtime overlays. The walker unions `load` into the prefab's required set.
///
/// This is the *parsed* shape. It is deserialized straight from the component
/// JSON block; the walker also reads it directly out of the `std.json.Value`
/// tree (see `inferAssets`) so it works before any component registry mapping.
pub const AssetManifest = struct {
    load: []const []const u8 = &.{},
};

/// Errors surfaced while building the reverse index. A `DuplicateResourceName`
/// is a load-time error by design (RFC §"Collisions"): two resources claiming
/// the same sprite/image name would otherwise shadow each other under
/// load-order-dependent, hard-to-debug conditions.
pub const IndexError = error{
    /// Two resources declare the same sprite path / image name.
    DuplicateResourceName,
    /// The atlas JSON did not have the expected TexturePacker `frames` shape.
    InvalidAtlasJson,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

/// Reverse index: `sprite-path | image-name → ResourceRef`. Owns its own
/// arena for every duped key and bundle-name payload, so callers can free the
/// resources/JSON they built it from immediately after. RFC §"Reverse index".
pub const ReverseIndex = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(ResourceRef) = .empty,

    pub fn init(gpa: std.mem.Allocator) ReverseIndex {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *ReverseIndex) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const ReverseIndex) usize {
        return self.map.count();
    }

    /// Resolve a sprite path / image name to its providing resource, or null
    /// if no registered resource declares it.
    pub fn lookup(self: *const ReverseIndex, name: []const u8) ?ResourceRef {
        return self.map.get(name);
    }

    /// Register a standalone image resource: the asset name is its own key
    /// (`name → .{ .image = name }`). RFC §"Reverse index" (entry without
    /// `.json`).
    pub fn addImage(self: *ReverseIndex, asset_name: []const u8) IndexError!void {
        const a = self.arena.allocator();
        const key = try a.dupe(u8, asset_name);
        try self.insert(key, .{ .image = key });
    }

    /// Register an atlas resource from an explicit sprite-path list. Every
    /// path becomes a key pointing at `bundle_name`. Prefer
    /// `addAtlasFromJson` when you have the TexturePacker JSON; this overload
    /// exists for callers that already parsed sprite names (and for tests).
    pub fn addAtlas(
        self: *ReverseIndex,
        bundle_name: []const u8,
        sprite_paths: []const []const u8,
    ) IndexError!void {
        const a = self.arena.allocator();
        const owned_bundle = try a.dupe(u8, bundle_name);
        for (sprite_paths) |path| {
            const key = try a.dupe(u8, path);
            try self.insert(key, .{ .atlas = owned_bundle });
        }
    }

    /// Register an atlas resource by parsing its TexturePacker JSON content
    /// and extracting every sprite path. Accepts both the hash form
    /// (`{"frames":{"path":{...}}}`) and the array form
    /// (`{"frames":[{"filename":"path",...}]}`). RFC §"Reverse index" (entry
    /// with `.json`).
    pub fn addAtlasFromJson(
        self: *ReverseIndex,
        bundle_name: []const u8,
        json_content: []const u8,
    ) IndexError!void {
        // Parse into the arena's allocator so the transient Value tree is
        // reclaimed on deinit; the sprite-name keys we keep are re-duped by
        // `addAtlas` anyway (they alias `parsed`'s buffers otherwise).
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.arena.child_allocator,
            json_content,
            .{},
        );
        defer parsed.deinit();

        if (parsed.value != .object) return IndexError.InvalidAtlasJson;
        const frames = parsed.value.object.get("frames") orelse return IndexError.InvalidAtlasJson;

        const owned_bundle = try self.arena.allocator().dupe(u8, bundle_name);
        switch (frames) {
            .object => |frames_obj| {
                var it = frames_obj.iterator();
                while (it.next()) |entry| {
                    const key = try self.arena.allocator().dupe(u8, entry.key_ptr.*);
                    try self.insert(key, .{ .atlas = owned_bundle });
                }
            },
            .array => |frames_arr| {
                for (frames_arr.items) |item| {
                    if (item != .object) continue;
                    const fname = item.object.get("filename") orelse continue;
                    if (fname != .string) continue;
                    const key = try self.arena.allocator().dupe(u8, fname.string);
                    try self.insert(key, .{ .atlas = owned_bundle });
                }
            },
            else => return IndexError.InvalidAtlasJson,
        }
    }

    fn insert(self: *ReverseIndex, key: []const u8, ref: ResourceRef) IndexError!void {
        const gop = try self.map.getOrPut(self.arena.allocator(), key);
        if (gop.found_existing) return IndexError.DuplicateResourceName;
        gop.value_ptr.* = ref;
    }
};

/// The resource set inferred (and/or declared) for one entity tree. Order is
/// insertion order (first-seen), which keeps output stable across runs for
/// diffing against an explicit `meta.assets` list. Names are owned dupes.
pub const InferredManifest = struct {
    gpa: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *InferredManifest) void {
        for (self.names.items) |n| self.gpa.free(n);
        self.names.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.* = undefined;
    }

    /// The inferred resource-bundle names — the exact shape of the explicit
    /// `meta.assets` list / `SceneEntry.assets`.
    pub fn slice(self: *const InferredManifest) []const []const u8 {
        return self.names.items;
    }

    /// True if `name` is in the inferred set (order-independent membership).
    pub fn contains(self: *const InferredManifest, name: []const u8) bool {
        return self.seen.contains(name);
    }

    fn add(self: *InferredManifest, name: []const u8) std.mem.Allocator.Error!void {
        const gop = try self.seen.getOrPut(self.gpa, name);
        if (gop.found_existing) return;
        // Re-key `seen` onto the owned copy so the borrow can't dangle.
        const owned = try self.gpa.dupe(u8, name);
        gop.key_ptr.* = owned;
        try self.names.append(self.gpa, owned);
    }
};

/// Walk an entity tree and infer its required resource bundles. RFC §"Walker".
///
/// `scene` is any `std.json.Value` node — a whole scene, a single prefab root,
/// or a subtree. The walk is recursive and shape-agnostic: it visits every
/// nested object/array and, for each *string value*, looks it up in `index`.
/// Hits contribute their `ResourceRef.resourceName()`. `AssetManifest`
/// component blocks (`{"AssetManifest":{"load":[...]}}`) found anywhere in the
/// tree contribute every `load` entry directly, whether or not the index
/// knows them (that's the whole point of the escape hatch).
///
/// False positives (a string that happens to match a sprite name but isn't a
/// visual reference) are *correctness*-harmless — they pre-load an unneeded
/// bundle. The mobile over-load cost of that is #566's audit, not this
/// function's concern.
///
/// Caller owns the returned `InferredManifest` (call `.deinit()`).
pub fn inferAssets(
    gpa: std.mem.Allocator,
    index: *const ReverseIndex,
    scene: std.json.Value,
) std.mem.Allocator.Error!InferredManifest {
    var out = InferredManifest{ .gpa = gpa };
    errdefer out.deinit();
    try walk(&out, index, scene);
    return out;
}

fn walk(
    out: *InferredManifest,
    index: *const ReverseIndex,
    node: std.json.Value,
) std.mem.Allocator.Error!void {
    switch (node) {
        .string => |s| {
            if (index.lookup(s)) |ref| try out.add(ref.resourceName());
        },
        .array => |arr| {
            for (arr.items) |item| try walk(out, index, item);
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                // Escape hatch: an `AssetManifest` component block declares
                // resources directly (audio banks, script-loaded overlays)
                // that no sprite/image reference would surface.
                if (std.mem.eql(u8, entry.key_ptr.*, "AssetManifest")) {
                    try collectManifestLoad(out, entry.value_ptr.*);
                }
                try walk(out, index, entry.value_ptr.*);
            }
        },
        // number / bool / null carry no references.
        else => {},
    }
}

/// Read `{"load":[...]}` out of an `AssetManifest` value node and union every
/// listed name into the set. Tolerant of a missing/mis-typed `load` (the
/// generic walk still visits nested strings, so nothing is lost).
fn collectManifestLoad(
    out: *InferredManifest,
    manifest: std.json.Value,
) std.mem.Allocator.Error!void {
    if (manifest != .object) return;
    const load = manifest.object.get("load") orelse return;
    if (load != .array) return;
    for (load.array.items) |item| {
        if (item == .string) try out.add(item.string);
    }
}

// ── `jsonc.Value` overloads (the scene-load wiring shape) ──
//
// The JSONC bridge parses scenes/prefabs into `jsonc.Value` (its own
// format-agnostic tree, distinct from `std.json.Value`), so the walker that
// actually runs at scene-load time consumes that shape. `inferAssetsFromSource`
// is the entry a loader calls: parse the scene source once, walk it, get the
// inferred `meta.assets` list. Structurally identical to the `std.json.Value`
// walk above.

/// Walk a `jsonc.Value` entity tree and infer its required resource bundles.
/// The scene-load counterpart to `inferAssets`. Caller owns the returned
/// `InferredManifest`.
pub fn inferAssetsJsonc(
    gpa: std.mem.Allocator,
    index: *const ReverseIndex,
    scene: jsonc.Value,
) std.mem.Allocator.Error!InferredManifest {
    var out = InferredManifest{ .gpa = gpa };
    errdefer out.deinit();
    try walkJsonc(&out, index, scene);
    return out;
}

/// Parse a JSONC scene/prefab source and infer its required resource bundles
/// in one call — the shape a scene loader wires in. Parses into an internal
/// arena (freed before return); the returned `InferredManifest` owns its own
/// name copies. `error.ParseFailed` wraps any JSONC syntax error.
pub fn inferAssetsFromSource(
    gpa: std.mem.Allocator,
    index: *const ReverseIndex,
    source: []const u8,
) !InferredManifest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = jsonc.JsoncParser.init(arena.allocator(), source);
    const root = parser.parse() catch return error.ParseFailed;
    return inferAssetsJsonc(gpa, index, root);
}

fn walkJsonc(
    out: *InferredManifest,
    index: *const ReverseIndex,
    node: jsonc.Value,
) std.mem.Allocator.Error!void {
    switch (node) {
        .string => |s| {
            if (index.lookup(s)) |ref| try out.add(ref.resourceName());
        },
        .array => |arr| {
            for (arr.items) |item| try walkJsonc(out, index, item);
        },
        .object => |obj| {
            for (obj.entries) |entry| {
                if (std.mem.eql(u8, entry.key, "AssetManifest")) {
                    try collectManifestLoadJsonc(out, entry.value);
                }
                try walkJsonc(out, index, entry.value);
            }
        },
        // number / bool / null / enum_literal carry no sprite references.
        else => {},
    }
}

fn collectManifestLoadJsonc(
    out: *InferredManifest,
    manifest: jsonc.Value,
) std.mem.Allocator.Error!void {
    if (manifest != .object) return;
    const load = manifest.object.get("load") orelse return;
    if (load != .array) return;
    for (load.array.items) |item| {
        if (item == .string) try out.add(item.string);
    }
}
