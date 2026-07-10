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
