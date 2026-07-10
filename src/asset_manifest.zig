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
//! **Wiring status (#563 follow-up — this PR).** The walker is now wired into
//! the scene-load path (`game/scene_mixin.zig`): a scene that declares NO
//! explicit `meta.assets` but carries its JSONC `source` (handed over by the
//! assembler via `Game.setSceneSource`) has its manifest *derived* on first
//! load and cached onto `SceneEntry.assets`, from which the existing
//! acquire/gate/release machinery drives loading unchanged. The runtime
//! reverse index is built lazily from the live `TextureManager` (every loaded
//! atlas's sprite paths → its bundle name; see `ensureReverseIndex`). Scenes
//! WITH an explicit manifest are untouched — inference never runs for them.
//!
//! ── Completeness audit + known limitations (#566, #754) ──
//!
//! What sprite/image-ref inference over a scene's inline tree CAN see:
//!   - Inline `Sprite`/`Image` references (any string that exactly matches an
//!     atlas sprite path / image name), including refs nested inside
//!     entity-bearing component fields (`Room.movement_nodes`, etc.).
//!   - `AssetManifest.load` escape-hatch declarations anywhere in the tree.
//!   - **Prefab references** (`{ "prefab": "condenser" }`) — followed
//!      *transitively* into the referenced prefab's own tree when a
//!      `PrefabResolver` is supplied (the scene-load path wires one from the
//!      engine's `PrefabCache`; see `inferAssetsFromSourceWithPrefabs`). This
//!      closes the load-bearing gap: Flying-Platform's top-level scenes
//!      (`colony`, `main`, …) are *pure prefab compositions* (dozens of
//!      `"prefab":` entries, zero inline `Sprite`), so before #754 scene-level
//!      inference resolved ~nothing for them; now their prefabs' atlas bundles
//!      union in. Prefab→prefab chains recurse; a cycle (A→B→A) terminates via
//!      a visited-set guard; an unknown prefab name is skipped. Inference over
//!      each prefab source individually still works standalone (verified:
//!      `prefabs/rooms/wc.jsonc` → `rooms` atlas). Without a resolver (the
//!      old 3-arg entry points) a prefab ref still contributes only its literal
//!      name string, preserving pre-#754 behavior.
//!
//! What it CANNOT see (a scene relying ONLY on these still needs an explicit
//! `meta.assets` or an `AssetManifest`):
//!   1. **Scene includes.** `"include": [...]` fragments are referenced by
//!      path, not inlined into the walked tree — same shape as a prefab ref,
//!      but the included fragment's source is not reachable through the
//!      `PrefabResolver` (which is keyed by prefab effective-name, not include
//!      path). Left as a documented follow-up to #754; a scene pulling in a
//!      fragment keeps its explicit list until an include-resolver lands.
//!   2. **Script-computed sprite names.** A name assembled at runtime
//!      (`std.fmt`, config lookup) is invisible to a static walk. Lazy-on-miss
//!      (#568/#563 Phase-B) recovers these via pop-in for VISUALS; anything
//!      that must be ready *before* first render needs `AssetManifest`.
//!      Flying-Platform has one script-acquire site today
//!      (`scripts/menu/menu_ui.zig`) — the pattern the audit flags.
//!   3. **Audio banks / fonts / raw bytes.** No `Sprite`/`Image` reference
//!      surfaces these, and audio in particular often must be decoded *before*
//!      a trigger fires (lazy pop-in is too late). These are the canonical
//!      `AssetManifest.load` case. (Flying-Platform's current `.resources` are
//!      all atlases, so it has no such case yet — but any project adding a
//!      sound bank referenced only from a script will.)
//!
//! Over-load (false positives): every string is matched, so a component field
//! that happens to equal a sprite path pre-loads an unneeded bundle. Harmless
//! for correctness; the mobile memory cost is the remaining open item of #566.
//! For inline-Sprite scenes measured here the inferred set was a subset of the
//! declared list (no over-load), but this is not yet audited at scale.
//!
//! **Migration guidance.** Before dropping a scene's `meta.assets`: a scene
//! that composes prefabs is now covered (their trees are walked transitively
//! at load time), as are inline `Sprite`/`Image`-ref scenes; if it pulls in
//! `"include"` fragments (case 1) keep the explicit list OR add an
//! `AssetManifest` until an include-resolver lands; for script-loaded
//! audio/overlays (cases 2–3), add an `AssetManifest.load`.
//!
//! False-positive over-load auditing at scale is the remaining open part of
//! #566.

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
                    // Same validation as the array form below: a hash-form
                    // frame value must be an object carrying a `frame` rect.
                    // A malformed value here is the same "this isn't the atlas
                    // I think it is" signal — reject rather than index a bogus
                    // sprite key.
                    if (entry.value_ptr.* != .object) return IndexError.InvalidAtlasJson;
                    const frame = entry.value_ptr.*.object.get("frame") orelse
                        return IndexError.InvalidAtlasJson;
                    if (frame != .object) return IndexError.InvalidAtlasJson;
                    const key = try self.arena.allocator().dupe(u8, entry.key_ptr.*);
                    try self.insert(key, .{ .atlas = owned_bundle });
                }
            },
            .array => |frames_arr| {
                for (frames_arr.items) |item| {
                    // A malformed entry is a real "this isn't the atlas I
                    // think it is" signal — surface it rather than silently
                    // skipping (which would drop a sprite from the index and
                    // reappear later as a mysterious missing-texture bug).
                    // Expected TexturePacker array shape:
                    // `{ "filename": "<path>", "frame": { … }, … }`.
                    if (item != .object) return IndexError.InvalidAtlasJson;
                    const fname = item.object.get("filename") orelse
                        return IndexError.InvalidAtlasJson;
                    if (fname != .string) return IndexError.InvalidAtlasJson;
                    const frame = item.object.get("frame") orelse
                        return IndexError.InvalidAtlasJson;
                    if (frame != .object) return IndexError.InvalidAtlasJson;
                    const key = try self.arena.allocator().dupe(u8, fname.string);
                    try self.insert(key, .{ .atlas = owned_bundle });
                }
            },
            else => return IndexError.InvalidAtlasJson,
        }
    }

    /// Register an atlas resource from an explicit sprite-path list,
    /// **tolerating duplicate keys** (first-wins). Unlike `addAtlas`, a
    /// sprite path already present in the index is silently skipped rather
    /// than raising `DuplicateResourceName`.
    ///
    /// This is the entry the *runtime* reverse-index builder uses. That
    /// builder indexes EVERY currently-loaded atlas from the live
    /// `TextureManager`; two atlases that happen to declare the same sprite
    /// path there must NOT abort the whole build (the renderer's
    /// `findSprite` already resolves such a collision by first-match, so a
    /// game that ships with a cross-atlas duplicate sprite name is already
    /// running fine — inference must not be the thing that crashes it).
    /// The strict `addAtlas` / `addAtlasFromJson` collision error is
    /// retained for the codegen/authoring path where a duplicate really is
    /// a fixable content bug. Returns the number of newly-inserted keys.
    ///
    /// `bundle_name` is duped only if at least one key is inserted, so an
    /// atlas whose every sprite is already indexed costs nothing.
    pub fn addAtlasLenient(
        self: *ReverseIndex,
        bundle_name: []const u8,
        sprite_paths: []const []const u8,
    ) IndexError!usize {
        const a = self.arena.allocator();
        var owned_bundle: ?[]const u8 = null;
        var inserted: usize = 0;
        for (sprite_paths) |path| {
            if (self.map.contains(path)) continue;
            if (owned_bundle == null) owned_bundle = try a.dupe(u8, bundle_name);
            const key = try a.dupe(u8, path);
            try self.insert(key, .{ .atlas = owned_bundle.? });
            inserted += 1;
        }
        return inserted;
    }

    /// Register a standalone image resource tolerating a duplicate key
    /// (first-wins). Runtime counterpart to `addImage` — see
    /// `addAtlasLenient` for why the runtime builder can't hard-error on a
    /// collision. Returns `true` if newly inserted.
    pub fn addImageLenient(self: *ReverseIndex, asset_name: []const u8) IndexError!bool {
        if (self.map.contains(asset_name)) return false;
        const a = self.arena.allocator();
        const key = try a.dupe(u8, asset_name);
        try self.insert(key, .{ .image = key });
        return true;
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
/// **This `std.json.Value` overload does NOT follow prefab references.** It
/// infers only from the *inline* `Sprite`/`Image` refs (and nested
/// entity-bearing fields) present in the tree it is given; a `"prefab":
/// "condenser"` ref contributes only its literal name string. Transitive
/// prefab-walking (#754) lives on the `jsonc.Value` path that the scene loader
/// actually runs — see `inferAssetsJsoncWithPrefabs` /
/// `inferAssetsFromSourceWithPrefabs`, which thread a `PrefabResolver` so a
/// referenced prefab's own tree is unioned in. This overload stays inline-only
/// because the runtime `PrefabCache` holds `jsonc.Value` trees, not
/// `std.json.Value`, so a resolver here would have nothing to resolve against.
/// Scene `"include"` fragments are still followed by neither path (a smaller
/// documented follow-up to #754 — the include source is not reachable through
/// the prefab-name-keyed resolver).
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
                // Do NOT recurse into the explicit `meta.assets` list. Those
                // are hand-authored asset KEYS, not sprite-path refs — the
                // whole point of inference is to derive the set INDEPENDENTLY
                // so it can validate the explicit list. Walking them would let
                // a stale explicit entry re-inject itself into the inferred
                // set (a self-fulfilling, non-validating result). Everything
                // else under `meta` is still walked.
                if (std.mem.eql(u8, entry.key_ptr.*, "meta") and entry.value_ptr.* == .object) {
                    try walkMetaSkippingAssets(out, index, entry.value_ptr.*.object);
                    continue;
                }
                // Legacy pre-unification scenes carried the hand-authored
                // list as a top-level `"assets": [...]` field (before it moved
                // under `meta`). Skip it for the same reason as `meta.assets`.
                // Guarded on an array value so a component field that happens
                // to be named `assets` isn't accidentally dropped.
                if (std.mem.eql(u8, entry.key_ptr.*, "assets") and entry.value_ptr.* == .array) {
                    continue;
                }
                try walk(out, index, entry.value_ptr.*);
            }
        },
        // number / bool / null carry no references.
        else => {},
    }
}

fn walkMetaSkippingAssets(
    out: *InferredManifest,
    index: *const ReverseIndex,
    meta: std.json.ObjectMap,
) std.mem.Allocator.Error!void {
    var it = meta.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "assets")) continue;
        try walk(out, index, entry.value_ptr.*);
    }
}

/// Read `{"load":[...]}` out of an `AssetManifest` value node and union every
/// listed name into the set. Tolerant of a missing/mis-typed `load` (the
/// generic walk still visits nested strings, so nothing is lost).
///
/// Entries are restricted to non-empty strings: an empty `""` name would ask
/// the catalog to `acquire("")` (a guaranteed miss / no-op) and only bloats
/// the set, so it's dropped. Fuller validation — that each name is a *known*
/// resource — needs the resource set, which isn't available at walk time;
/// TODO(#563 follow-up): validate manifest entries against the built reverse
/// index / catalog once the assembler wires the real resource list in.
fn collectManifestLoad(
    out: *InferredManifest,
    manifest: std.json.Value,
) std.mem.Allocator.Error!void {
    if (manifest != .object) return;
    const load = manifest.object.get("load") orelse return;
    if (load != .array) return;
    for (load.array.items) |item| {
        if (item == .string and item.string.len > 0) try out.add(item.string);
    }
}

// ── `jsonc.Value` overloads (the scene-load wiring shape) ──
//
// The JSONC bridge parses scenes/prefabs into `jsonc.Value` (its own
// format-agnostic tree, distinct from `std.json.Value`), so the walker that
// actually runs at scene-load time consumes that shape. `inferAssetsFromSource`
// is the entry a loader calls: parse the scene source once, walk it, get the
// inferred `meta.assets` list. Structurally identical to the `std.json.Value`
// walk above, PLUS transitive prefab-reference walking (#754) — see
// `PrefabResolver`.

/// Resolves a prefab *effective name* to its parsed entity tree so the walker
/// can follow `{ "prefab": "<name>" }` references transitively into the assets
/// they contribute (#754). Returns `null` for an unknown name (the reference
/// is then skipped gracefully — no crash, no partial result).
///
/// Deliberately a tiny type-erased callback rather than a hard dependency on
/// the engine's `PrefabCache`, so `asset_manifest.zig` stays lifecycle-free
/// and unit-testable: the scene-load path wires the live `PrefabCache` behind
/// it (via `getInstalled`, a registry-only lookup with no disk/side effects);
/// a test wires a plain name→tree map. The returned `jsonc.Value` must stay
/// valid for the duration of the `inferAssets*` call (the cache's trees are
/// game-lifetime, so this holds at runtime).
pub const PrefabResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, name: []const u8) ?jsonc.Value,

    pub fn resolve(self: PrefabResolver, name: []const u8) ?jsonc.Value {
        return self.resolveFn(self.ctx, name);
    }
};

/// Threaded through the recursive `jsonc.Value` walk so every level can reach
/// the resolver + the cycle-guard set without a growing parameter list.
const JsoncWalkCtx = struct {
    out: *InferredManifest,
    index: *const ReverseIndex,
    /// `null` = don't follow prefab refs (the pre-#754 3-arg entry points).
    resolver: ?PrefabResolver,
    /// Prefab names already walked into — the cycle guard AND redundant-work
    /// dedup. Keys alias the walked trees (stable for the whole call), so no
    /// dupe is needed; the set itself is freed by the entry point.
    visited: *std.StringHashMapUnmanaged(void),
    gpa: std.mem.Allocator,
};

/// Walk a `jsonc.Value` entity tree and infer its required resource bundles.
/// The scene-load counterpart to `inferAssets`. Does NOT follow prefab
/// references — use `inferAssetsJsoncWithPrefabs` for that. Caller owns the
/// returned `InferredManifest`.
pub fn inferAssetsJsonc(
    gpa: std.mem.Allocator,
    index: *const ReverseIndex,
    scene: jsonc.Value,
) std.mem.Allocator.Error!InferredManifest {
    return inferAssetsJsoncWithPrefabs(gpa, index, scene, null);
}

/// Like `inferAssetsJsonc`, but follows `{ "prefab": "<name>" }` references
/// transitively through `resolver` (#754): a referenced prefab's own tree is
/// walked and its assets unioned in. Prefab→prefab chains recurse; cycles
/// terminate via a visited-set guard; an unknown prefab name is skipped.
/// Passing `resolver == null` is exactly `inferAssetsJsonc`.
pub fn inferAssetsJsoncWithPrefabs(
    gpa: std.mem.Allocator,
    index: *const ReverseIndex,
    scene: jsonc.Value,
    resolver: ?PrefabResolver,
) std.mem.Allocator.Error!InferredManifest {
    var out = InferredManifest{ .gpa = gpa };
    errdefer out.deinit();
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer visited.deinit(gpa);
    var ctx = JsoncWalkCtx{
        .out = &out,
        .index = index,
        .resolver = resolver,
        .visited = &visited,
        .gpa = gpa,
    };
    try walkJsonc(&ctx, scene);
    return out;
}

/// Parse a JSONC scene/prefab source and infer its required resource bundles
/// in one call — the shape a scene loader wires in. Parses into an internal
/// arena (freed before return); the returned `InferredManifest` owns its own
/// name copies. `error.ParseFailed` wraps a genuine JSONC *syntax* error;
/// `error.OutOfMemory` propagates distinctly (a transient allocation failure
/// is not a malformed scene and callers may want to retry, not reject).
///
/// Does NOT follow prefab references — see `inferAssetsFromSourceWithPrefabs`.
pub fn inferAssetsFromSource(
    gpa: std.mem.Allocator,
    index: *const ReverseIndex,
    source: []const u8,
) (error{ ParseFailed, OutOfMemory })!InferredManifest {
    return inferAssetsFromSourceWithPrefabs(gpa, index, source, null);
}

/// Like `inferAssetsFromSource`, but follows prefab references transitively
/// through `resolver` (#754). This is the entry the scene-load path (#563
/// wiring in `game/scene_mixin.zig`) calls, passing a resolver backed by the
/// engine's `PrefabCache`, so a pure prefab-composition scene (zero inline
/// `Sprite`) still derives the union of its prefabs' atlas bundles.
///
/// Only the *scene* source is parsed here; referenced prefab trees come from
/// `resolver` already-parsed (the cache holds `jsonc.Value` trees), so no
/// re-parse happens per reference.
pub fn inferAssetsFromSourceWithPrefabs(
    gpa: std.mem.Allocator,
    index: *const ReverseIndex,
    source: []const u8,
    resolver: ?PrefabResolver,
) (error{ ParseFailed, OutOfMemory })!InferredManifest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = jsonc.JsoncParser.init(arena.allocator(), source);
    const root = parser.parse() catch |err| switch (err) {
        // Keep OOM distinct — collapsing it into ParseFailed would make a
        // recoverable allocation hiccup look like a permanently broken scene.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseFailed,
    };
    return inferAssetsJsoncWithPrefabs(gpa, index, root, resolver);
}

fn walkJsonc(
    ctx: *JsoncWalkCtx,
    node: jsonc.Value,
) std.mem.Allocator.Error!void {
    switch (node) {
        .string => |s| {
            if (ctx.index.lookup(s)) |ref| try ctx.out.add(ref.resourceName());
        },
        .array => |arr| {
            for (arr.items) |item| try walkJsonc(ctx, item);
        },
        .object => |obj| {
            // Transitive prefab-walk (#754): an entity that references another
            // prefab by name pulls in that prefab's own tree. Done BEFORE the
            // generic entry walk so the referenced assets union in regardless
            // of where `"prefab"` sits among the object's keys. The generic
            // walk below still visits the `"prefab"` string value itself
            // (usually an index miss — the name isn't a sprite path), and any
            // sibling `overrides`/`components` keys, so a reference-with-
            // overrides entity contributes both its own and its prefab's refs.
            if (ctx.resolver) |resolver| {
                if (obj.getString("prefab")) |prefab_name| {
                    try walkPrefabRef(ctx, resolver, prefab_name);
                }
            }
            for (obj.entries) |entry| {
                if (std.mem.eql(u8, entry.key, "AssetManifest")) {
                    try collectManifestLoadJsonc(ctx.out, entry.value);
                }
                // Skip the explicit `meta.assets` list — see the `walk`
                // counterpart for the rationale (derive independently to
                // validate; a stale entry must not re-inject itself).
                if (std.mem.eql(u8, entry.key, "meta") and entry.value == .object) {
                    for (entry.value.object.entries) |meta_entry| {
                        if (std.mem.eql(u8, meta_entry.key, "assets")) continue;
                        try walkJsonc(ctx, meta_entry.value);
                    }
                    continue;
                }
                // Legacy top-level `"assets": [...]` list (pre-`meta` move) —
                // skip for the same reason, guarded on an array value.
                if (std.mem.eql(u8, entry.key, "assets") and entry.value == .array) {
                    continue;
                }
                try walkJsonc(ctx, entry.value);
            }
        },
        // number / bool / null / enum_literal carry no sprite references.
        else => {},
    }
}

/// Resolve a `"prefab": "<name>"` reference and walk the referenced tree,
/// unioning its assets in. The visited set is the cycle guard (A→B→A stops
/// when A is re-encountered) and also dedups redundant work in a diamond
/// (A→B, A→C, B→D, C→D walks D once). Marking BEFORE the recurse is what
/// makes the cycle terminate. An unknown name (resolver miss) is skipped —
/// inference is best-effort and must never crash on a dangling reference.
fn walkPrefabRef(
    ctx: *JsoncWalkCtx,
    resolver: PrefabResolver,
    name: []const u8,
) std.mem.Allocator.Error!void {
    const gop = try ctx.visited.getOrPut(ctx.gpa, name);
    if (gop.found_existing) return;
    const tree = resolver.resolve(name) orelse return;
    try walkJsonc(ctx, tree);
}

fn collectManifestLoadJsonc(
    out: *InferredManifest,
    manifest: jsonc.Value,
) std.mem.Allocator.Error!void {
    if (manifest != .object) return;
    const load = manifest.object.get("load") orelse return;
    if (load != .array) return;
    for (load.array.items) |item| {
        if (item == .string and item.string.len > 0) try out.add(item.string);
    }
}
