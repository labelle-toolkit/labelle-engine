//! Sprite-based asset inference — reverse index + walker (labelle-engine#563).
//!
//! Proves the engine half of RFC-UNIFY-SCENES-AND-PREFABS §"Assets —
//! inference": a scene that names sprites/images via `Sprite`/`Image`
//! components no longer needs a hand-authored `meta.assets` list — the walker
//! derives the same set from the entity tree. Coverage:
//!
//!   1. `ReverseIndex` from a TexturePacker atlas JSON (hash + array forms)
//!      and from standalone images, with correct `ResourceRef` tags.
//!   2. Name collisions are a load-time error.
//!   3. A scene with `Sprite` refs but NO explicit assets list infers the
//!      correct resource-bundle set.
//!   4. Explicit `meta.assets` and inferred set agree (the derivability
//!      guarantee — inferred supplements/validates, doesn't diverge).
//!   5. The `AssetManifest` escape hatch unions in assets the walker can't
//!      see from a sprite reference (audio banks, script overlays).
//!   6. `inferAssetsFromSource` — the JSONC scene-load wiring entry.
//!   7. Transitive prefab-reference walking (#754): a pure prefab-composition
//!      scene infers the union of its prefabs' bundles, prefab→prefab chains
//!      resolve, reference cycles terminate, and unknown prefab names are
//!      skipped — while inline-Sprite scenes stay unchanged.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const ReverseIndex = engine.ReverseIndex;
const ResourceRef = engine.ResourceRef;

// A minimal TexturePacker atlas JSON in the "frames-hash" shape.
const rooms_atlas_json =
    \\{
    \\  "frames": {
    \\    "room/floor.png":   { "frame": { "x": 0,  "y": 0,  "w": 64, "h": 64 } },
    \\    "room/wall.png":    { "frame": { "x": 64, "y": 0,  "w": 64, "h": 64 } },
    \\    "room/door.png":    { "frame": { "x": 0,  "y": 64, "w": 64, "h": 64 } }
    \\  },
    \\  "meta": { "size": { "w": 128, "h": 128 } }
    \\}
;

// The "frames-array" shape (filename per entry).
const chars_atlas_json =
    \\{
    \\  "frames": [
    \\    { "filename": "worker/idle.png", "frame": { "x": 0, "y": 0, "w": 32, "h": 32 } },
    \\    { "filename": "worker/walk.png", "frame": { "x": 32, "y": 0, "w": 32, "h": 32 } }
    \\  ]
    \\}
;

fn stdValue(src: []const u8, arena: std.mem.Allocator) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, src, .{});
    return parsed.value; // arena-backed; lives as long as `arena`
}

test "reverse index: atlas (hash form) maps every sprite path to its bundle" {
    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.addAtlasFromJson("rooms", rooms_atlas_json);

    try testing.expectEqual(@as(usize, 3), idx.count());
    const ref = idx.lookup("room/floor.png") orelse return error.MissingSprite;
    try testing.expectEqualStrings("rooms", ref.atlas);
    try testing.expectEqualStrings("rooms", ref.resourceName());
    try testing.expect(idx.lookup("room/does_not_exist.png") == null);
}

test "reverse index: atlas (array form) + standalone image" {
    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.addAtlasFromJson("characters", chars_atlas_json);
    try idx.addImage("logo_splash");

    const walk = idx.lookup("worker/walk.png") orelse return error.MissingSprite;
    try testing.expectEqualStrings("characters", walk.atlas);

    const logo = idx.lookup("logo_splash") orelse return error.MissingImage;
    try testing.expectEqualStrings("logo_splash", logo.image);
    try testing.expectEqualStrings("logo_splash", logo.resourceName());
}

test "reverse index: duplicate sprite path across resources is a load-time error" {
    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.addAtlas("atlas_a", &.{ "shared/tile.png", "a/only.png" });
    try testing.expectError(
        error.DuplicateResourceName,
        idx.addAtlas("atlas_b", &.{"shared/tile.png"}),
    );
    // Image colliding with a sprite path is equally rejected.
    try testing.expectError(
        error.DuplicateResourceName,
        idx.addImage("a/only.png"),
    );
}

test "walker: scene with Sprite refs but NO explicit assets list infers the set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try idx.addAtlasFromJson("characters", chars_atlas_json);
    try idx.addImage("logo_splash");

    // A scene tree with Sprite/Image references but no `meta.assets`.
    // Includes a ref nested inside an entity-bearing component field
    // (`Room.workstations[].Sprite`) — the C1 pattern the walker must reach.
    const scene_src =
        \\{
        \\  "root": {
        \\    "components": {
        \\      "Image": { "name": "logo_splash", "pivot": "center", "layer": "ui" }
        \\    },
        \\    "children": [
        \\      {
        \\        "components": {
        \\          "Sprite": { "sprite_name": "room/floor.png", "pivot": "center" },
        \\          "Room": {
        \\            "workstations": [
        \\              { "components": { "Sprite": { "sprite_name": "worker/idle.png" } } }
        \\            ]
        \\          }
        \\        }
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const scene = try stdValue(scene_src, arena);

    var inferred = try engine.inferAssets(testing.allocator, &idx, scene);
    defer inferred.deinit();

    // rooms (floor.png), characters (worker/idle.png), logo_splash (Image).
    try testing.expectEqual(@as(usize, 3), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
    try testing.expect(inferred.contains("characters"));
    try testing.expect(inferred.contains("logo_splash"));
}

test "walker: explicit meta.assets and inferred set agree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try idx.addAtlasFromJson("characters", chars_atlas_json);

    const scene_src =
        \\{
        \\  "meta": { "assets": ["rooms", "characters"] },
        \\  "root": {
        \\    "children": [
        \\      { "components": { "Sprite": { "sprite_name": "room/wall.png" } } },
        \\      { "components": { "Sprite": { "sprite_name": "worker/walk.png" } } }
        \\    ]
        \\  }
        \\}
    ;
    const scene = try stdValue(scene_src, arena);

    var inferred = try engine.inferAssets(testing.allocator, &idx, scene);
    defer inferred.deinit();

    // Read the explicit list back out and prove membership matches exactly.
    const explicit = scene.object.get("meta").?.object.get("assets").?.array;
    try testing.expectEqual(explicit.items.len, inferred.slice().len);
    for (explicit.items) |item| {
        try testing.expect(inferred.contains(item.string));
    }
    // ...and every inferred name appears in the explicit list (no drift either way).
    for (inferred.slice()) |name| {
        var found = false;
        for (explicit.items) |item| {
            if (std.mem.eql(u8, item.string, name)) found = true;
        }
        try testing.expect(found);
    }
}

test "reverse index: malformed atlas HASH-form entry is rejected" {
    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();

    // Hash-form frame value missing the required `frame` rect.
    const no_frame =
        \\{ "frames": { "room/floor.png": { "rotated": false } } }
    ;
    try testing.expectError(error.InvalidAtlasJson, idx.addAtlasFromJson("a", no_frame));

    // Hash-form frame value is a scalar, not an object.
    const scalar_value =
        \\{ "frames": { "room/floor.png": 42 } }
    ;
    try testing.expectError(error.InvalidAtlasJson, idx.addAtlasFromJson("b", scalar_value));

    // A well-formed hash atlas still parses (guards against over-strictness).
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try testing.expect(idx.lookup("room/floor.png") != null);
}

test "reverse index: malformed atlas array entry is rejected" {
    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();

    // Entry missing the required `frame` rect.
    const no_frame =
        \\{ "frames": [ { "filename": "worker/idle.png" } ] }
    ;
    try testing.expectError(error.InvalidAtlasJson, idx.addAtlasFromJson("a", no_frame));

    // Entry missing `filename`.
    const no_filename =
        \\{ "frames": [ { "frame": { "x": 0, "y": 0, "w": 8, "h": 8 } } ] }
    ;
    try testing.expectError(error.InvalidAtlasJson, idx.addAtlasFromJson("b", no_filename));

    // Non-object entry.
    const scalar_entry =
        \\{ "frames": [ "worker/idle.png" ] }
    ;
    try testing.expectError(error.InvalidAtlasJson, idx.addAtlasFromJson("c", scalar_entry));

    // A well-formed array entry still parses (guards against over-strictness).
    try idx.addAtlasFromJson("characters", chars_atlas_json);
    try testing.expect(idx.lookup("worker/idle.png") != null);
}

test "walker: explicit meta.assets is NOT re-inferred as sprite refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    // `logo_splash` is a valid index key (a standalone image), so if the
    // walker recursed into `meta.assets` it would wrongly pick it up.
    try idx.addImage("logo_splash");

    // `meta.assets` lists BOTH "rooms" and a STALE "logo_splash" — but no
    // entity actually references logo_splash. Only a Sprite → rooms is used.
    const scene_src =
        \\{
        \\  "meta": { "assets": ["rooms", "logo_splash"] },
        \\  "root": {
        \\    "children": [
        \\      { "components": { "Sprite": { "sprite_name": "room/floor.png" } } }
        \\    ]
        \\  }
        \\}
    ;
    const scene = try stdValue(scene_src, arena);

    var inferred = try engine.inferAssets(testing.allocator, &idx, scene);
    defer inferred.deinit();

    // Only "rooms" is inferred (from the real Sprite ref). The stale
    // "logo_splash" in the explicit list must NOT leak into the derived set —
    // otherwise inference could never contradict/validate a stale list.
    try testing.expectEqual(@as(usize, 1), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
    try testing.expect(!inferred.contains("logo_splash"));
}

test "walker: legacy top-level assets list is NOT re-inferred" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try idx.addImage("logo_splash");

    // Pre-unification scenes carried the hand-authored list at the TOP level
    // (before it moved under `meta`). A stale "logo_splash" there must not
    // leak into the derived set; only the real Sprite → rooms is inferred.
    const scene_src =
        \\{
        \\  "assets": ["rooms", "logo_splash"],
        \\  "root": {
        \\    "children": [
        \\      { "components": { "Sprite": { "sprite_name": "room/wall.png" } } }
        \\    ]
        \\  }
        \\}
    ;
    const scene = try stdValue(scene_src, arena);

    var inferred = try engine.inferAssets(testing.allocator, &idx, scene);
    defer inferred.deinit();

    try testing.expectEqual(@as(usize, 1), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
    try testing.expect(!inferred.contains("logo_splash"));
}

test "inferAssetsFromSource: OutOfMemory propagates distinctly (not ParseFailed)" {
    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);

    const scene_src =
        \\{ "root": { "components": { "Sprite": { "sprite_name": "room/floor.png" } } } }
    ;

    // Fail the very first allocation the JSONC parser makes: the parse must
    // surface OutOfMemory *as* OutOfMemory, not collapse it into ParseFailed
    // (a transient alloc failure is not a malformed scene).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        engine.inferAssetsFromSource(failing.allocator(), &idx, scene_src),
    );
}

test "walker: AssetManifest.load skips empty-string entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();

    const scene_src =
        \\{ "root": { "components": {
        \\  "AssetManifest": { "load": ["intro_audio", "", "cinematic_overlay"] }
        \\} } }
    ;
    const scene = try stdValue(scene_src, arena);

    var inferred = try engine.inferAssets(testing.allocator, &idx, scene);
    defer inferred.deinit();

    // The empty "" name is dropped; the two real ones remain.
    try testing.expectEqual(@as(usize, 2), inferred.slice().len);
    try testing.expect(inferred.contains("intro_audio"));
    try testing.expect(inferred.contains("cinematic_overlay"));
}

test "walker: AssetManifest.load unions in assets inference can't see" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);

    // The intro audio bank has no sprite/image reference — only the manifest
    // surfaces it. `cinematic_overlay` likewise (a script-loaded resource).
    const scene_src =
        \\{
        \\  "root": {
        \\    "components": {
        \\      "AssetManifest": { "load": ["intro_audio", "cinematic_overlay"] },
        \\      "Sprite": { "sprite_name": "room/door.png" }
        \\    }
        \\  }
        \\}
    ;
    const scene = try stdValue(scene_src, arena);

    var inferred = try engine.inferAssets(testing.allocator, &idx, scene);
    defer inferred.deinit();

    try testing.expectEqual(@as(usize, 3), inferred.slice().len);
    try testing.expect(inferred.contains("rooms")); // from the Sprite
    try testing.expect(inferred.contains("intro_audio")); // manifest-only
    try testing.expect(inferred.contains("cinematic_overlay")); // manifest-only
}

test "walker: dedupes repeated references to the same bundle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);

    // Three different sprites, all from the "rooms" bundle → one entry.
    const scene_src =
        \\{
        \\  "children": [
        \\    { "Sprite": { "sprite_name": "room/floor.png" } },
        \\    { "Sprite": { "sprite_name": "room/wall.png" } },
        \\    { "Sprite": { "sprite_name": "room/door.png" } }
        \\  ]
        \\}
    ;
    const scene = try stdValue(scene_src, arena);

    var inferred = try engine.inferAssets(testing.allocator, &idx, scene);
    defer inferred.deinit();

    try testing.expectEqual(@as(usize, 1), inferred.slice().len);
    try testing.expectEqualStrings("rooms", inferred.slice()[0]);
}

test "inferAssetsFromSource: JSONC scene source (comments + trailing commas)" {
    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try idx.addImage("logo_splash");

    // JSONC-specific syntax the raw std.json parser would reject.
    const scene_src =
        \\{
        \\  // a scene authored as JSONC
        \\  "root": {
        \\    "components": {
        \\      "Image": { "name": "logo_splash", "pivot": "center" }, // trailing comma
        \\    },
        \\    "children": [
        \\      { "components": { "Sprite": { "sprite_name": "room/floor.png" } } },
        \\    ],
        \\  },
        \\}
    ;

    var inferred = try engine.inferAssetsFromSource(testing.allocator, &idx, scene_src);
    defer inferred.deinit();

    try testing.expectEqual(@as(usize, 2), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
    try testing.expect(inferred.contains("logo_splash"));
}

// ── #754: transitive prefab-reference walking ──────────────────────────────
//
// A pure prefab-composition scene (dozens of `{ "prefab": ... }` entries, zero
// inline `Sprite`) derives its manifest by following each prefab reference into
// the referenced prefab's own tree. These tests wire a `PrefabResolver` over a
// plain name→tree map — the unit-test analog of the scene loader wiring the
// live `PrefabCache` behind the same interface.

/// A name→parsed-tree prefab registry standing in for the engine's runtime
/// `PrefabCache`. Parses prefab sources into `arena` up front and hands the
/// walker a `PrefabResolver` over the resulting map.
const PrefabReg = struct {
    map: std.StringHashMap(engine.SceneValue),
    arena: std.mem.Allocator,

    fn init(arena: std.mem.Allocator) PrefabReg {
        return .{ .map = std.StringHashMap(engine.SceneValue).init(arena), .arena = arena };
    }

    fn add(self: *PrefabReg, name: []const u8, src: []const u8) !void {
        var parser = engine.JsoncParser.init(self.arena, src);
        try self.map.put(name, try parser.parse());
    }

    fn resolveFn(ctx: *anyopaque, name: []const u8) ?engine.SceneValue {
        const self: *PrefabReg = @ptrCast(@alignCast(ctx));
        return self.map.get(name);
    }

    fn resolver(self: *PrefabReg) engine.PrefabResolver {
        return .{ .ctx = self, .resolveFn = resolveFn };
    }
};

test "prefab-walk: pure prefab-composition scene infers the union of its prefabs' bundles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try idx.addAtlasFromJson("characters", chars_atlas_json);

    // Two prefabs, each carrying an inline Sprite from a DIFFERENT atlas.
    var reg = PrefabReg.init(arena);
    try reg.add("condenser",
        \\{ "children": [
        \\  { "Sprite": { "sprite_name": "room/floor.png", "pivot": "center" } }
        \\] }
    );
    try reg.add("worker",
        \\{ "Sprite": { "sprite_name": "worker/idle.png", "pivot": "center" } }
    );

    // The scene mirrors FP's `colony`: a top-level ARRAY of `{ "prefab": ... }`
    // entries (with sibling `Position`), ZERO inline Sprite. Before #754 this
    // derived an EMPTY manifest; now it unions both prefabs' bundles.
    const scene_src =
        \\[
        \\  { "prefab": "condenser", "Position": { "x": 0, "y": 0 } },
        \\  { "prefab": "worker", "Position": { "x": 156, "y": 0 } }
        \\]
    ;

    // Without a resolver, the pre-#754 behavior: prefab names are misses → empty.
    var no_prefab = try engine.inferAssetsFromSource(testing.allocator, &idx, scene_src);
    defer no_prefab.deinit();
    try testing.expectEqual(@as(usize, 0), no_prefab.slice().len);

    // With the resolver, both prefabs' atlas bundles are derived.
    var inferred = try engine.inferAssetsFromSourceWithPrefabs(
        testing.allocator,
        &idx,
        scene_src,
        reg.resolver(),
    );
    defer inferred.deinit();

    try testing.expectEqual(@as(usize, 2), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
    try testing.expect(inferred.contains("characters"));
}

test "prefab-walk: prefab→prefab chain resolves transitively" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try idx.addAtlasFromJson("characters", chars_atlas_json);

    var reg = PrefabReg.init(arena);
    // `room` references `workstation` (a nested prefab ref, exactly like FP's
    // `condenser` → `industry__condenser_workstation`), which carries the only
    // Sprite from the `characters` atlas. `room` itself uses `rooms`.
    try reg.add("room",
        \\{ "children": [
        \\  { "Sprite": { "sprite_name": "room/wall.png" } },
        \\  { "prefab": "workstation", "Position": { "x": 10, "y": 10 } }
        \\] }
    );
    try reg.add("workstation",
        \\{ "Sprite": { "sprite_name": "worker/walk.png" } }
    );

    const scene_src =
        \\[ { "prefab": "room", "Position": { "x": 0, "y": 0 } } ]
    ;

    var inferred = try engine.inferAssetsFromSourceWithPrefabs(
        testing.allocator,
        &idx,
        scene_src,
        reg.resolver(),
    );
    defer inferred.deinit();

    // `rooms` from the room's own Sprite, `characters` from the transitively
    // resolved workstation prefab.
    try testing.expectEqual(@as(usize, 2), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
    try testing.expect(inferred.contains("characters"));
}

test "prefab-walk: a reference cycle (A→B→A) terminates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);
    try idx.addAtlasFromJson("characters", chars_atlas_json);

    var reg = PrefabReg.init(arena);
    // A → B → A. A malformed content cycle must not loop forever.
    try reg.add("a",
        \\{ "children": [
        \\  { "Sprite": { "sprite_name": "room/door.png" } },
        \\  { "prefab": "b" }
        \\] }
    );
    try reg.add("b",
        \\{ "children": [
        \\  { "Sprite": { "sprite_name": "worker/idle.png" } },
        \\  { "prefab": "a" }
        \\] }
    );

    const scene_src =
        \\[ { "prefab": "a" } ]
    ;

    var inferred = try engine.inferAssetsFromSourceWithPrefabs(
        testing.allocator,
        &idx,
        scene_src,
        reg.resolver(),
    );
    defer inferred.deinit();

    // Terminates, and still collects both atlases before the cycle is cut.
    try testing.expectEqual(@as(usize, 2), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
    try testing.expect(inferred.contains("characters"));
}

test "prefab-walk: unknown prefab name is skipped gracefully" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);

    var reg = PrefabReg.init(arena);
    try reg.add("known",
        \\{ "Sprite": { "sprite_name": "room/floor.png" } }
    );

    // The scene references one KNOWN prefab and one that the resolver can't
    // find (a dangling ref). The unknown one must be skipped, not crash, and
    // the known one still resolves.
    const scene_src =
        \\[
        \\  { "prefab": "known" },
        \\  { "prefab": "does_not_exist", "Position": { "x": 5, "y": 5 } }
        \\]
    ;

    var inferred = try engine.inferAssetsFromSourceWithPrefabs(
        testing.allocator,
        &idx,
        scene_src,
        reg.resolver(),
    );
    defer inferred.deinit();

    try testing.expectEqual(@as(usize, 1), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
}

test "prefab-walk: inline-Sprite scene is unchanged when a resolver is present" {
    // Preserve the existing behavior: a scene that ALREADY has inline Sprite
    // refs (no prefab refs) infers exactly the same set whether or not a
    // resolver is threaded — the resolver only adds coverage, never changes
    // the inline path.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var idx = ReverseIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.addAtlasFromJson("rooms", rooms_atlas_json);

    var reg = PrefabReg.init(arena);
    // A prefab exists in the registry but is never referenced by the scene.
    try reg.add("unused",
        \\{ "Sprite": { "sprite_name": "worker/idle.png" } }
    );

    const scene_src =
        \\{ "root": { "children": [
        \\  { "components": { "Sprite": { "sprite_name": "room/floor.png" } } }
        \\] } }
    ;

    var inferred = try engine.inferAssetsFromSourceWithPrefabs(
        testing.allocator,
        &idx,
        scene_src,
        reg.resolver(),
    );
    defer inferred.deinit();

    try testing.expectEqual(@as(usize, 1), inferred.slice().len);
    try testing.expect(inferred.contains("rooms"));
}
