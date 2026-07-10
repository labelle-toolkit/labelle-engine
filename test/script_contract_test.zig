//! Script Runtime Contract v1 (#737) — labelle_* C-ABI surface tests.
//!
//! The module keeps its dispatch state (vtable, subscriptions, poll
//! FIFO, emit arenas) in module-scope vars, so every test starts and
//! ends with `contract.unbind()` to stay isolated — same discipline as
//! editor_api_test.zig.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const contract = engine.script_contract;

// ── Test game: two registered components + a GameEvents union ───────
//
// The assembler-shaped instantiation: a ComponentRegistry the contract
// dispatches over, and a custom `GameEvents` union for emit/subscribe.
// StubRender/MockEcs keep it headless (the editor_api tests' shape).

const Health = struct { hp: i32 = 100, regen: f32 = 0 };
const Velocity = struct { dx: f32 = 0, dy: f32 = 0 };

/// `Doomed.onRemove` is a static method — no instance to mutate. A
/// module-scope counter (reset at the start of the relevant test, the
/// nested_lifecycle_test pattern) pins that `labelle_component_remove`
/// on an ABSENT component never false-fires the hook.
var doomed_on_remove_calls: u32 = 0;

const Doomed = struct {
    tag: u8 = 0,

    pub fn onRemove(payload: engine.ComponentPayload) void {
        _ = payload;
        doomed_on_remove_calls += 1;
    }
};

/// String-bearing component — pins the copy-out-of-the-caller's-buffer
/// contract (a borrowed slice would dangle the moment the C call
/// returns).
const Label = struct { text: []const u8 = "" };

const TestComponents = engine.ComponentRegistry(.{
    .Health = Health,
    .Velocity = Velocity,
    .Doomed = Doomed,
    .Label = Label,
});

const TestEvents = union(enum) {
    turret__fired: struct { turret: u32 = 0, heat: f32 = 0 },
    wave__started: struct { index: u32 = 0 },
    // Slice-bearing payload — pins the emit-arena lifetime contract
    // (parsed name must survive from emit through dispatch).
    state__renamed: struct { name: []const u8 = "" },
    // Void payload — pins the emit accept set (empty / "{}" / "null").
    game__paused,
};

const MockEcs = core.MockEcsBackend(u32);
const ContractGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void, // no hooks — dispatchEvents just drains the buffer
    core.StubLogSink,
    TestComponents,
    &.{},
    TestEvents,
);

// ── ptr+len call helpers (the C shapes are noisy in Zig) ────────────

fn setComp(id: u64, name: []const u8, json: []const u8) i32 {
    return contract.labelle_component_set(id, name.ptr, name.len, json.ptr, json.len);
}

/// Call component_get with a buffer known to FIT the component — the
/// return is the required size (snprintf-style), which then equals
/// bytes written. The sizing test drives `labelle_component_get`
/// directly instead.
fn getComp(id: u64, name: []const u8, buf: []u8) []const u8 {
    const n = contract.labelle_component_get(id, name.ptr, name.len, buf.ptr, buf.len);
    std.debug.assert(n <= buf.len);
    return buf[0..n];
}

fn hasComp(id: u64, name: []const u8) i32 {
    return contract.labelle_component_has(id, name.ptr, name.len);
}

fn removeComp(id: u64, name: []const u8) i32 {
    return contract.labelle_component_remove(id, name.ptr, name.len);
}

/// Call the query with a buffer known to FIT the result — the return is
/// the required size (snprintf-style), which then equals bytes written.
/// The truncation test drives `labelle_query` directly instead.
fn query(names_json: []const u8, buf: []u8) []const u8 {
    const n = contract.labelle_query(names_json.ptr, names_json.len, buf.ptr, buf.len);
    std.debug.assert(n <= buf.len);
    return buf[0..n];
}

fn emitEvent(name: []const u8, json: []const u8) i32 {
    return contract.labelle_event_emit(name.ptr, name.len, json.ptr, json.len);
}

fn subscribe(name: []const u8) void {
    contract.labelle_event_subscribe(name.ptr, name.len);
}

fn poll(buf: []u8) []const u8 {
    const n = contract.labelle_event_poll(buf.ptr, buf.len);
    return buf[0..n];
}

fn spawnPrefab(name: []const u8, json: []const u8) u64 {
    return contract.labelle_prefab_spawn(name.ptr, name.len, json.ptr, json.len);
}

fn findEntity(name: []const u8) u64 {
    return contract.labelle_entity_find(name.ptr, name.len);
}

/// Parse a query result (`[3,7]`) and check it equals `expected` as a
/// SET — the mock backend iterates a hash map, so id order is
/// unspecified.
fn expectQueryIds(result: []const u8, expected: []const u64) !void {
    const parsed = try std.json.parseFromSlice([]u64, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(expected.len, parsed.value.len);
    for (expected) |want| {
        var found = false;
        for (parsed.value) |got| {
            if (got == want) found = true;
        }
        try testing.expect(found);
    }
}

// ── Version ─────────────────────────────────────────────────────────

test "labelle_contract_version: pure, works pre-bind, matches the decl" {
    contract.unbind();
    defer contract.unbind();

    try testing.expectEqual(@as(u32, 1), contract.labelle_contract_version());
    try testing.expectEqual(contract.CONTRACT_VERSION, contract.labelle_contract_version());
}

// ── Pre-bind no-op safety ───────────────────────────────────────────

test "pre-bind: every export is a safe no-op" {
    contract.unbind();
    defer contract.unbind();

    // Id-returning ops: 0 (never a valid entity id).
    try testing.expectEqual(@as(u64, 0), contract.labelle_entity_create());
    try testing.expectEqual(@as(u64, 0), spawnPrefab("turret", ""));
    try testing.expectEqual(@as(u64, 0), findEntity("player"));

    // Input reads: not-down, and the mouse writes the origin.
    try testing.expectEqual(@as(i32, 0), contract.labelle_input_key_down(32));
    try testing.expectEqual(@as(i32, 0), contract.labelle_input_key_pressed(32));
    var mx: f32 = 7;
    var my: f32 = 9;
    contract.labelle_input_mouse(&mx, &my);
    try testing.expectEqual(@as(f32, 0), mx);
    try testing.expectEqual(@as(f32, 0), my);

    // Void ops silently ignore.
    contract.labelle_entity_destroy(42);
    contract.labelle_log("hello", 5);
    contract.labelle_time_dt_stamp(0.033);
    subscribe("turret__fired");

    // rc ops report failure.
    try testing.expectEqual(@as(i32, -1), setComp(1, "Health", "{\"hp\":1}"));
    try testing.expectEqual(@as(i32, -1), removeComp(1, "Health"));
    try testing.expectEqual(@as(i32, -1), emitEvent("turret__fired", "{}"));
    try testing.expectEqual(@as(i32, -1), contract.labelle_scene_change("main", 4));

    // Boolean / out-writing ops: 0 bytes, 0 answer.
    try testing.expectEqual(@as(i32, 0), hasComp(1, "Health"));
    var buf: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), getComp(1, "Health", &buf).len);
    try testing.expectEqual(@as(usize, 0), query("[\"Health\"]", &buf).len);
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);

    // Time: no game, no dt.
    try testing.expectEqual(@as(f32, 0), contract.labelle_time_dt());
}

// ── Entities ────────────────────────────────────────────────────────

test "entity create/destroy: real ECS lifecycle through the vtable" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    try testing.expect(id != 0);
    const ent: u32 = @intCast(id);
    try testing.expect(game.ecs_backend.entityExists(ent));

    contract.labelle_entity_destroy(id);
    try testing.expect(!game.ecs_backend.entityExists(ent));

    // Stale/dead/overflowing ids are ignored, not crashes (debug builds
    // assert inside destroyEntity — the contract liveness-checks first).
    contract.labelle_entity_destroy(id);
    contract.labelle_entity_destroy(999_999);
    contract.labelle_entity_destroy(std.math.maxInt(u64));
}

// ── Components: set / get / has / remove ────────────────────────────

test "component set/get: JSON round-trip over the registry" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);

    // Set: parsed to the typed struct, applied via setComponent.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":42,\"regen\":1.5}"));
    const h = game.getComponent(ent, Health).?;
    try testing.expectEqual(@as(i32, 42), h.hp);
    try testing.expectEqual(@as(f32, 1.5), h.regen);

    // Absent fields take struct defaults (REPLACE, not merge): a second
    // set with only `hp` resets `regen` to its default.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":7}"));
    try testing.expectEqual(@as(f32, 0), game.getComponent(ent, Health).?.regen);

    // Unknown JSON keys are tolerated.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":9,\"bogus\":true}"));

    // Get: serialize back and parse to verify the round-trip.
    var buf: [256]u8 = undefined;
    const json = getComp(id, "Health", &buf);
    try testing.expect(json.len > 0);
    const parsed = try std.json.parseFromSlice(Health, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 9), parsed.value.hp);

    // Failure modes, all -1 with the entity untouched:
    try testing.expectEqual(@as(i32, -1), setComp(id, "Mana", "{\"points\":3}")); // unknown name
    try testing.expectEqual(@as(i32, -1), setComp(id, "Health", "{\"hp\":")); // parse error
    try testing.expectEqual(@as(i32, -1), setComp(999_999, "Health", "{\"hp\":1}")); // dead entity
    try testing.expectEqual(@as(i32, 9), game.getComponent(ent, Health).?.hp);

    // Get failure modes: 0 bytes.
    try testing.expectEqual(@as(usize, 0), getComp(id, "Mana", &buf).len); // unknown name
    try testing.expectEqual(@as(usize, 0), getComp(id, "Velocity", &buf).len); // absent component
    try testing.expectEqual(@as(usize, 0), getComp(999_999, "Health", &buf).len); // dead entity

    // Doesn't fit is NOT a failure mode anymore: an under-sized cap
    // returns the required size (> cap = the truncation signal) — the
    // dedicated sizing test below pins the all-or-nothing write.
    const health = "Health";
    var tiny: [2]u8 = undefined;
    try testing.expect(contract.labelle_component_get(id, health.ptr, health.len, &tiny, tiny.len) > tiny.len);
}

test "component_get: required-size sizing — probe, all-or-nothing write, exact cap" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const name = "Health";
    try testing.expectEqual(@as(i32, 0), setComp(id, name, "{\"hp\":1234,\"regen\":2.5}"));

    // NULL/cap-0 is the pure sizing probe: the required size of the
    // complete JSON, nothing written.
    const required = contract.labelle_component_get(id, name.ptr, name.len, null, 0);
    try testing.expect(required > 0);

    // A call at exactly `required` writes the FULL JSON, returns the
    // same size the probe promised, and never touches a byte past the
    // cap.
    var buf: [256]u8 = undefined;
    try testing.expect(required < buf.len);
    @memset(&buf, 0xAA);
    const n = contract.labelle_component_get(id, name.ptr, name.len, &buf, required);
    try testing.expectEqual(required, n);
    const parsed = try std.json.parseFromSlice(Health, testing.allocator, buf[0..n], .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 1234), parsed.value.hp);
    try testing.expectEqual(@as(u8, 0xAA), buf[required]);

    // EVERY under-sized cap (cap-1 included — the canary case): the
    // required size still returns, and NOTHING is written — a truncated
    // JSON object prefix is useless, so the write is all-or-nothing
    // (unlike the query's still-valid id-list prefix).
    var cap: usize = 0;
    while (cap < required) : (cap += 1) {
        @memset(&buf, 0xAA);
        try testing.expectEqual(
            required,
            contract.labelle_component_get(id, name.ptr, name.len, &buf, cap),
        );
        for (buf) |b| try testing.expectEqual(@as(u8, 0xAA), b); // canary intact
    }

    // Absent / unknown / dead keep the 0 sentinel — even as a probe.
    const velocity = "Velocity";
    const mana = "Mana";
    try testing.expectEqual(@as(usize, 0), contract.labelle_component_get(id, velocity.ptr, velocity.len, null, 0));
    try testing.expectEqual(@as(usize, 0), contract.labelle_component_get(id, mana.ptr, mana.len, null, 0));
    try testing.expectEqual(@as(usize, 0), contract.labelle_component_get(999_999, name.ptr, name.len, null, 0));

    // The built-in and filtered paths size the same way: probe ==
    // sized call, for Position and a scene built-in alike.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":12.5,\"y\":-3}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"hero\",\"z_index\":3}"));
    inline for (.{ "Position", "Sprite" }) |comp_name| {
        const probe = contract.labelle_component_get(id, comp_name.ptr, comp_name.len, null, 0);
        try testing.expect(probe > 0);
        var out: [512]u8 = undefined;
        try testing.expectEqual(
            probe,
            contract.labelle_component_get(id, comp_name.ptr, comp_name.len, &out, out.len),
        );
        // And an under-sized cap writes nothing on these paths too.
        @memset(&out, 0xAA);
        try testing.expectEqual(
            probe,
            contract.labelle_component_get(id, comp_name.ptr, comp_name.len, &out, probe - 1),
        );
        for (out) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    }
}

test "component set: string fields are COPIED out of the caller's buffer" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);

    // The C caller's json is only valid DURING the call — a native
    // plugin passes a stack or reused buffer. "hello world" needs no
    // unescaping, which is exactly the case where a default
    // (alloc_if_needed) parse BORROWS the input instead of copying
    // into the component arena; the contract must copy always.
    var jsonbuf: [64]u8 = undefined;
    const src = "{\"text\":\"hello world\"}";
    @memcpy(jsonbuf[0..src.len], src);
    const name = "Label";
    try testing.expectEqual(
        @as(i32, 0),
        contract.labelle_component_set(id, name.ptr, name.len, &jsonbuf, src.len),
    );
    @memset(&jsonbuf, 0xAA); // the buffer dies/reuses after the call

    const label = game.getComponent(ent, Label).?;
    try testing.expectEqualStrings("hello world", label.text);
    // Structural proof, not just value luck: the stored slice lives
    // OUTSIDE the caller's buffer (the arena copy).
    const lo = @intFromPtr(&jsonbuf);
    const hi = lo + jsonbuf.len;
    const p = @intFromPtr(label.text.ptr);
    try testing.expect(p < lo or p >= hi);
}

test "component set: trailing garbage after the JSON document refuses with -1" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);

    // Seed known-good values on both dispatch paths.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"hero\"}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":7}"));

    // Built-in path (the JSONC parser stops after ONE value): any
    // trailing garbage — a second document included — is malformed
    // JSON, refused BEFORE the apply, entity untouched.
    inline for (.{
        "{\"sprite_name\":\"evil\"}garbage",
        "{\"sprite_name\":\"evil\"}{}",
        "{\"sprite_name\":\"evil\"}]",
    }) |payload| {
        try testing.expectEqual(@as(i32, -1), setComp(id, "Sprite", payload));
    }
    try testing.expectEqualStrings("hero", game.getComponent(ent, ContractGame.SpriteComp).?.sprite_name);

    // Registry path: std.json's end-of-document check refuses the same
    // shapes by itself — pinned here so a parser swap can't quietly
    // open the hole the built-in path had.
    inline for (.{
        "{\"hp\":9}garbage",
        "{\"hp\":9}{\"hp\":10}",
        "{\"hp\":9}}",
    }) |payload| {
        try testing.expectEqual(@as(i32, -1), setComp(id, "Health", payload));
    }
    try testing.expectEqual(@as(i32, 7), game.getComponent(ent, Health).?.hp);

    // Whitespace-only tails stay legal on both paths — and the
    // built-in path, being JSONC, treats a trailing comment as trivia.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":8} \n"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"neo\"} // done\n"));
    try testing.expectEqual(@as(i32, 8), game.getComponent(ent, Health).?.hp);
    try testing.expectEqualStrings("neo", game.getComponent(ent, ContractGame.SpriteComp).?.sprite_name);
}

test "component set/get: the built-in Position routes through setPosition" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);

    try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":320,\"y\":240}"));
    const pos = game.getComponent(ent, core.Position).?;
    try testing.expectEqual(@as(f32, 320), pos.x);
    try testing.expectEqual(@as(f32, 240), pos.y);

    var buf: [128]u8 = undefined;
    const json = getComp(id, "Position", &buf);
    const parsed = try std.json.parseFromSlice(core.Position, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f32, 320), parsed.value.x);
    try testing.expectEqual(@as(f32, 240), parsed.value.y);

    try testing.expectEqual(@as(i32, 1), hasComp(id, "Position"));
}

// ── Components: scene built-ins (JSONC write-parity, #749) ──────────
//
// `Sprite`/`Shape`/`Tilemap`/`Camera`/`Image` dispatch through the
// scene loader's OWN apply fns (`jsonc/component_apply.zig`) with its
// registry-precedence gates — whatever a scene can author, a script
// can set/get/has/remove. The support matrix lives in
// `contract/labelle_script.h`.

test "built-ins: set routes through the scene apply machinery" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);

    // Sprite — lands as the renderer's component AND registers with
    // the renderer (addSprite entity-tracking), exactly like a scene.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"hero\",\"z_index\":3}"));
    const sp = game.getComponent(ent, ContractGame.SpriteComp).?;
    try testing.expectEqualStrings("hero", sp.sprite_name);
    try testing.expectEqual(@as(i16, 3), sp.z_index);
    try testing.expectEqual(@as(usize, 1), game.renderer.tracked_count);

    // Shape — addShape, tracked too.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Shape", "{\"shape\":{\"circle\":{\"radius\":7}},\"visible\":false}"));
    const sh = game.getComponent(ent, ContractGame.ShapeComp).?;
    try testing.expectEqual(@as(f32, 7), sh.shape.circle.radius);
    try testing.expect(!sh.visible);
    try testing.expectEqual(@as(usize, 2), game.renderer.tracked_count);

    // Tilemap — attaches the component (StubRender has no tilemap
    // seam, so no decode side-table — same as a scene on a stub).
    try testing.expectEqual(@as(i32, 0), setComp(id, "Tilemap", "{\"asset_name\":\"dungeon.tmx\"}"));
    try testing.expectEqualStrings("dungeon.tmx", game.getComponent(ent, ContractGame.TilemapComp).?.asset_name);

    // Camera — built-in here (no registry "Camera"): the authored tag
    // string routes through `setTagSlice` onto the inline `[16:0]u8`,
    // the scene branch's special case.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Camera", "{\"zoom\":2,\"tag\":\"minimap\"}"));
    const cam = game.getComponent(ent, ContractGame.CameraComp).?;
    try testing.expectEqual(@as(f32, 2), cam.zoom);
    try testing.expectEqualStrings("minimap", cam.tagSlice());

    // Image — plain engine POD; the enum pivot maps from its name.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Image", "{\"name\":\"logo.png\",\"pivot\":\"bottom_center\",\"z_index\":2}"));
    const img = game.getComponent(ent, ContractGame.ImageComp).?;
    try testing.expectEqualStrings("logo.png", img.name);
    try testing.expect(img.pivot == .bottom_center);
    try testing.expectEqual(@as(i16, 2), img.z_index);

    // Failure modes, -1 with the entity untouched: malformed JSON and
    // non-object payloads (the apply is all-or-nothing).
    try testing.expectEqual(@as(i32, -1), setComp(id, "Sprite", "{\"sprite_name\":"));
    try testing.expectEqual(@as(i32, -1), setComp(id, "Sprite", "5"));
    try testing.expectEqualStrings("hero", game.getComponent(ent, ContractGame.SpriteComp).?.sprite_name);

    // Dead entity → -1 (the same liveness gate as the registry path).
    try testing.expectEqual(@as(i32, -1), setComp(999_999, "Sprite", "{}"));
}

test "built-ins: get serializes what a scene could author, and feeds back through set" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const id2 = contract.labelle_entity_create();
    const ent2: u32 = @intCast(id2);
    var buf: [512]u8 = undefined;

    // Absent built-in: 0 bytes, per the get contract.
    try testing.expectEqual(@as(usize, 0), getComp(id, "Sprite", &buf).len);

    // Sprite round-trip: get's output applies cleanly to a fresh
    // entity and reproduces the component (StubRender's Sprite has no
    // handle fields; on gfx `texture` would be omitted and re-derived).
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"hero\",\"z_index\":3}"));
    const sprite_json = getComp(id, "Sprite", &buf);
    try testing.expect(sprite_json.len > 0);
    try testing.expectEqual(@as(i32, 0), setComp(id2, "Sprite", sprite_json));
    const sp2 = game.getComponent(ent2, ContractGame.SpriteComp).?;
    try testing.expectEqualStrings("hero", sp2.sprite_name);
    try testing.expectEqual(@as(i16, 3), sp2.z_index);

    // Shape round-trip (tagged union payload).
    try testing.expectEqual(@as(i32, 0), setComp(id, "Shape", "{\"shape\":{\"rectangle\":{\"width\":4,\"height\":5}}}"));
    const shape_json = getComp(id, "Shape", &buf);
    try testing.expectEqual(@as(i32, 0), setComp(id2, "Shape", shape_json));
    try testing.expectEqual(@as(f32, 4), game.getComponent(ent2, ContractGame.ShapeComp).?.shape.rectangle.width);

    // Camera: `tag` serializes as a STRING (the component stores an
    // inline `[16:0]u8`), and the whole shape feeds back through the
    // apply branch's `setTagSlice`.
    try testing.expectEqual(@as(i32, 0), setComp(
        id,
        "Camera",
        "{\"zoom\":2,\"tag\":\"minimap\",\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":180}}",
    ));
    var cam_buf: [512]u8 = undefined;
    const cam_json = getComp(id, "Camera", &cam_buf);
    const cam_parsed = try std.json.parseFromSlice(struct {
        zoom: f32,
        viewport: ?struct { x: i32, y: i32, width: i32, height: i32 },
        tag: []const u8,
    }, testing.allocator, cam_json, .{});
    defer cam_parsed.deinit();
    try testing.expectEqual(@as(f32, 2), cam_parsed.value.zoom);
    try testing.expectEqualStrings("minimap", cam_parsed.value.tag);
    try testing.expectEqual(@as(i32, 180), cam_parsed.value.viewport.?.height);
    try testing.expectEqual(@as(i32, 0), setComp(id2, "Camera", cam_json));
    const cam2 = game.getComponent(ent2, ContractGame.CameraComp).?;
    try testing.expectEqualStrings("minimap", cam2.tagSlice());
    try testing.expectEqual(@as(i32, 320), cam2.viewport.?.width);

    // Tilemap round-trips including layer bindings (slice of structs).
    try testing.expectEqual(@as(i32, 0), setComp(
        id,
        "Tilemap",
        "{\"asset_name\":\"a.tmx\",\"layer_bindings\":[{\"tmx_layer\":\"bg\",\"engine_layer\":\"world\"}]}",
    ));
    const tm_json = getComp(id, "Tilemap", &buf);
    try testing.expectEqual(@as(i32, 0), setComp(id2, "Tilemap", tm_json));
    const tm2 = game.getComponent(ent2, ContractGame.TilemapComp).?;
    try testing.expectEqualStrings("a.tmx", tm2.asset_name);
    try testing.expectEqualStrings("bg", tm2.layer_bindings.?[0].tmx_layer);
    try testing.expectEqualStrings("world", tm2.layer_bindings.?[0].engine_layer);

    // Image round-trip (string / enum / int / bool fields).
    try testing.expectEqual(@as(i32, 0), setComp(id, "Image", "{\"name\":\"logo.png\",\"pivot\":\"bottom_center\"}"));
    const img_json = getComp(id, "Image", &buf);
    try testing.expectEqual(@as(i32, 0), setComp(id2, "Image", img_json));
    const img2 = game.getComponent(ent2, ContractGame.ImageComp).?;
    try testing.expectEqualStrings("logo.png", img2.name);
    try testing.expect(img2.pivot == .bottom_center);
}

test "built-ins: has/remove — typed teardown channels with the idempotence guard" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();

    // Sprite: remove goes through removeSprite — the renderer is
    // untracked, not just the ECS row dropped.
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Sprite"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"hero\"}"));
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Sprite"));
    try testing.expectEqual(@as(usize, 1), game.renderer.tracked_count);
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Sprite"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Sprite"));
    try testing.expectEqual(@as(usize, 0), game.renderer.tracked_count);
    // Absent-but-known: idempotent 0, and NO second renderer untrack.
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Sprite"));
    try testing.expectEqual(@as(usize, 0), game.renderer.tracked_count);

    // Shape mirrors Sprite (removeShape).
    try testing.expectEqual(@as(i32, 0), setComp(id, "Shape", "{}"));
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Shape"));
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Shape"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Shape"));

    // Tilemap: removeTilemap — the full teardown channel (frees the
    // decoded side-table runtime where a renderer has the seam).
    try testing.expectEqual(@as(i32, 0), setComp(id, "Tilemap", "{\"asset_name\":\"a.tmx\"}"));
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Tilemap"));
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Tilemap"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Tilemap"));
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Tilemap")); // idempotent

    // Camera / Image: plain data components, generic remove.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Camera", "{}"));
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Camera"));
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Camera"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Camera"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Image", "{}"));
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Image"));
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Image"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Image"));

    // Dead entity: -1 (remove), 0 (has) — the liveness gates.
    try testing.expectEqual(@as(i32, -1), removeComp(999_999, "Sprite"));
    try testing.expectEqual(@as(i32, 0), hasComp(999_999, "Sprite"));
}

// A project that registers its OWN `Camera`: the built-in channel is
// compiled out (`camera_is_builtin == false`) and the name routes
// through the registry — the scene loader's exact precedence.
const RegisteredCamera = struct { fov: f32 = 90 };
const RegisteredCameraComponents = engine.ComponentRegistry(.{
    .Health = Health,
    .Camera = RegisteredCamera,
});
const RegisteredCameraGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    RegisteredCameraComponents,
    &.{},
    void,
);

test "built-ins: a project-registered Camera wins over the built-in (scene precedence)" {
    contract.unbind();
    defer contract.unbind();

    // The same comptime gate every built-in Camera channel keys on.
    try testing.expect(ContractGame.camera_is_builtin);
    try testing.expect(!RegisteredCameraGame.camera_is_builtin);

    var game = RegisteredCameraGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);

    // "Camera" resolves through the REGISTRY (setComponent): the
    // project's type lands, the engine built-in never materializes.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Camera", "{\"fov\":45}"));
    try testing.expectEqual(@as(f32, 45), game.getComponent(ent, RegisteredCamera).?.fov);
    try testing.expect(game.getComponent(ent, RegisteredCameraGame.CameraComp) == null);

    // get / has / remove route to the registry type too.
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Camera"));
    var buf: [128]u8 = undefined;
    const json = getComp(id, "Camera", &buf);
    const parsed = try std.json.parseFromSlice(RegisteredCamera, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f32, 45), parsed.value.fov);
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Camera"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Camera"));

    // Sprite/Shape stay built-in even here — they are unconditional in
    // the scene path too.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"x\"}"));
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Sprite"));
}

test "built-ins: query resolves them on both sides of the dispatch" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const e1 = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(e1, "Sprite", "{\"sprite_name\":\"a\"}"));
    try testing.expectEqual(@as(i32, 0), setComp(e1, "Health", "{}"));
    const e2 = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(e2, "Sprite", "{\"sprite_name\":\"b\"}"));

    var buf: [256]u8 = undefined;
    try expectQueryIds(query("[\"Sprite\"]", &buf), &.{ e1, e2 });
    try expectQueryIds(query("[\"Sprite\",\"Health\"]", &buf), &.{e1});
    try expectQueryIds(query("[\"Health\",\"Sprite\"]", &buf), &.{e1});
}

test "component has/remove: presence flips, unknown names refuse" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();

    try testing.expectEqual(@as(i32, 0), hasComp(id, "Velocity"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", "{\"dx\":1}"));
    try testing.expectEqual(@as(i32, 1), hasComp(id, "Velocity"));

    try testing.expectEqual(@as(i32, 0), removeComp(id, "Velocity"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Velocity"));
    // Removing an absent-but-known component is idempotent 0.
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Velocity"));

    // Unknown name / dead entity: -1 (remove), 0 (has).
    try testing.expectEqual(@as(i32, -1), removeComp(id, "Mana"));
    try testing.expectEqual(@as(i32, -1), removeComp(999_999, "Velocity"));
    try testing.expectEqual(@as(i32, 0), hasComp(999_999, "Velocity"));
}

test "component remove: an absent component never false-fires onRemove" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    doomed_on_remove_calls = 0;
    const id = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":5}"));

    // Absent-but-known: idempotent 0, and the hook must NOT fire —
    // `game.removeComponent` runs `T.onRemove` unconditionally, so the
    // contract has to gate on presence first.
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Doomed"));
    try testing.expectEqual(@as(u32, 0), doomed_on_remove_calls);
    // Sibling components are untouched by the no-op remove.
    try testing.expectEqual(@as(i32, 5), game.getComponent(@as(u32, @intCast(id)), Health).?.hp);

    // Present: the hook fires exactly once per real removal.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Doomed", "{}"));
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Doomed"));
    try testing.expectEqual(@as(u32, 1), doomed_on_remove_calls);

    // And the remove made it absent again: back to the silent path.
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Doomed"));
    try testing.expectEqual(@as(u32, 1), doomed_on_remove_calls);

    // The built-in Position takes the same guard (absent → 0, no-op).
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Position"));
    try testing.expectEqual(@as(i32, 5), game.getComponent(@as(u32, @intCast(id)), Health).?.hp);
}

// ── Stale-id liveness (reads must guard entityExists) ───────────────
//
// core's MockEcsBackend liveness-checks INSIDE getComponent /
// hasComponent, which would mask the very hazard the contract guards
// against: on a real sparse-set backend (zig_ecs) a component read is a
// raw index lookup, so a stale id held by a script past
// `labelle_entity_destroy` can still hit the dead entity's row — or a
// recycled one. LeakyReadEcs models that backend: the MockEcs surface,
// but component reads skip the alive gate and `destroyEntity` only
// drops the id from `alive`, leaving rows readable. With it, ONLY the
// contract-level `entityExists` guard keeps get/has at 0.

const LeakyReadEcs = struct {
    pub const Entity = u32;

    const CleanupFn = *const fn (*Self) void;

    next_id: u32 = 1,
    alive: std.AutoHashMap(u32, void),
    storages: std.AutoHashMap(usize, *anyopaque),
    cleanups: std.ArrayListUnmanaged(CleanupFn) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .alive = std.AutoHashMap(u32, void).init(allocator),
            .storages = std.AutoHashMap(usize, *anyopaque).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.cleanups.items) |cleanup| cleanup(self);
        self.cleanups.deinit(self.allocator);
        self.storages.deinit();
        self.alive.deinit();
    }

    pub fn createEntity(self: *Self) u32 {
        const id = self.next_id;
        self.next_id += 1;
        self.alive.put(id, {}) catch @panic("OOM");
        return id;
    }

    pub fn destroyEntity(self: *Self, entity: u32) void {
        // Deliberately NO storage scrub — stale rows stay readable.
        _ = self.alive.remove(entity);
    }

    pub fn entityExists(self: *Self, entity: u32) bool {
        return self.alive.contains(entity);
    }

    pub fn entityCount(self: *Self) usize {
        return self.alive.count();
    }

    pub fn addComponent(self: *Self, entity: u32, component: anytype) void {
        self.getOrCreateStorage(@TypeOf(component)).put(entity, component) catch @panic("OOM");
    }

    /// Raw lookup — no alive gate (the point of this fixture).
    pub fn getComponent(self: *Self, entity: u32, comptime T: type) ?*T {
        const storage = self.getStorage(T) orelse return null;
        return storage.getPtr(entity);
    }

    /// Raw lookup — no alive gate (the point of this fixture).
    pub fn hasComponent(self: *Self, entity: u32, comptime T: type) bool {
        const storage = self.getStorage(T) orelse return false;
        return storage.contains(entity);
    }

    pub fn removeComponent(self: *Self, entity: u32, comptime T: type) void {
        const storage = self.getStorage(T) orelse return;
        _ = storage.remove(entity);
    }

    // The iteration shape is liveness-agnostic — reuse MockEcs's View
    // type; only entities in `alive` are collected, like any backend.
    pub fn View(comptime includes: anytype, comptime excludes: anytype) type {
        return MockEcs.View(includes, excludes);
    }

    pub fn view(self: *Self, comptime includes: anytype, comptime excludes: anytype) View(includes, excludes) {
        var result: std.ArrayListUnmanaged(u32) = .empty;
        var it = self.alive.keyIterator();
        while (it.next()) |key_ptr| {
            const entity = key_ptr.*;
            const matches = blk: {
                inline for (includes) |T| {
                    if (!self.hasComponent(entity, T)) break :blk false;
                }
                inline for (excludes) |T| {
                    if (self.hasComponent(entity, T)) break :blk false;
                }
                break :blk true;
            };
            if (matches) result.append(self.allocator, entity) catch @panic("OOM");
        }
        return .{
            .entities = result.toOwnedSlice(self.allocator) catch @panic("OOM"),
            .allocator = self.allocator,
        };
    }

    fn getOrCreateStorage(self: *Self, comptime T: type) *std.AutoHashMap(u32, T) {
        const tid = typeId(T);
        if (self.storages.get(tid)) |raw| return @ptrCast(@alignCast(raw));
        const storage = self.allocator.create(std.AutoHashMap(u32, T)) catch @panic("OOM");
        storage.* = std.AutoHashMap(u32, T).init(self.allocator);
        self.storages.put(tid, @ptrCast(storage)) catch @panic("OOM");
        self.cleanups.append(self.allocator, &struct {
            fn cleanup(s: *Self) void {
                if (s.storages.get(typeId(T))) |raw| {
                    const typed: *std.AutoHashMap(u32, T) = @ptrCast(@alignCast(raw));
                    typed.deinit();
                    s.allocator.destroy(typed);
                }
            }
        }.cleanup) catch @panic("OOM");
        return storage;
    }

    fn getStorage(self: *Self, comptime T: type) ?*std.AutoHashMap(u32, T) {
        const raw = self.storages.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    fn typeId(comptime T: type) usize {
        return @intFromPtr(&struct {
            comptime {
                _ = T;
            }
            var x: u8 = 0;
        }.x);
    }
};

const LeakyGame = engine.GameConfig(
    core.StubRender(u32),
    LeakyReadEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    void, // no events — the fixture pins component reads only
);

test "component get/has: a stale id after entity_destroy reads as absent (liveness guard)" {
    contract.unbind();
    defer contract.unbind();

    var game = LeakyGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":31}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":1,\"y\":2}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"husk\"}"));
    var buf: [256]u8 = undefined;
    try testing.expect(getComp(id, "Health", &buf).len > 0);

    contract.labelle_entity_destroy(id);

    // The backend itself still serves the dead rows — proving the
    // assertions below pin the CONTRACT's guard, not backend charity.
    const ent: u32 = @intCast(id);
    try testing.expect(game.ecs_backend.getComponent(ent, Health) != null);
    try testing.expect(game.ecs_backend.hasComponent(ent, Health));

    // Through the exports the stale id reads as ABSENT: registry name,
    // built-in Position, and scene built-in alike (get 0 bytes, has 0).
    try testing.expectEqual(@as(usize, 0), getComp(id, "Health", &buf).len);
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Health"));
    try testing.expectEqual(@as(usize, 0), getComp(id, "Position", &buf).len);
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Position"));
    try testing.expectEqual(@as(usize, 0), getComp(id, "Sprite", &buf).len);
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Sprite"));
}

// ── Query ───────────────────────────────────────────────────────────

test "query: view on the first name, filter on the rest" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // e1: Health+Velocity; e2: Health; e3: Velocity.
    const e1 = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(e1, "Health", "{}"));
    try testing.expectEqual(@as(i32, 0), setComp(e1, "Velocity", "{}"));
    const e2 = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(e2, "Health", "{}"));
    const e3 = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(e3, "Velocity", "{}"));

    var buf: [256]u8 = undefined;

    // Single name: every Health carrier.
    try expectQueryIds(query("[\"Health\"]", &buf), &.{ e1, e2 });

    // Two names: the filter narrows to the intersection.
    try expectQueryIds(query("[\"Health\",\"Velocity\"]", &buf), &.{e1});
    try expectQueryIds(query("[\"Velocity\",\"Health\"]", &buf), &.{e1});

    // Built-in Position participates on both sides of the dispatch.
    try testing.expectEqual(@as(i32, 0), setComp(e2, "Position", "{\"x\":1,\"y\":2}"));
    try expectQueryIds(query("[\"Position\"]", &buf), &.{e2});
    try expectQueryIds(query("[\"Health\",\"Position\"]", &buf), &.{e2});

    // Unknown names — first or filter — yield the valid empty result.
    try testing.expectEqualStrings("[]", query("[\"Mana\"]", &buf));
    try testing.expectEqualStrings("[]", query("[\"Health\",\"Mana\"]", &buf));
    try testing.expectEqualStrings("[]", query("[]", &buf));

    // Malformed names JSON: 0 bytes (an error, not an empty result).
    try testing.expectEqual(@as(usize, 0), query("[\"Health\"", &buf).len);
    try testing.expectEqual(@as(usize, 0), query("{\"not\":\"array\"}", &buf).len);
}

test "query: snprintf sizing — truncation detectable, writes stay valid JSON, retry yields all" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        _ = setComp(contract.labelle_entity_create(), "Health", "{}");
    }

    const names = "[\"Health\"]";

    // NULL/cap-0 is the pure sizing probe: required size back, nothing
    // written.
    const required = contract.labelle_query(names.ptr, names.len, null, 0);
    try testing.expect(required > 2);

    // A retry at exactly `required` holds the COMPLETE result: the
    // return equals the cap and every id parses out.
    var big: [1024]u8 = undefined;
    try testing.expect(required <= big.len);
    const n_full = contract.labelle_query(names.ptr, names.len, &big, required);
    try testing.expectEqual(required, n_full);
    var parsed = try std.json.parseFromSlice([]u64, testing.allocator, big[0..n_full], .{});
    const total = parsed.value.len;
    parsed.deinit();
    try testing.expectEqual(@as(usize, 50), total);

    // Every under-sized cap: the return is STILL the full required size
    // — exceeding the cap, which is exactly how a caller detects the
    // silent truncation the old written-bytes return hid — while the
    // written prefix truncates at the last whole id and parses as valid
    // JSON. Bytes past the cap are never touched.
    var cap: usize = 2;
    while (cap < required) : (cap += 3) {
        @memset(&big, 0xAA);
        const ret = contract.labelle_query(names.ptr, names.len, &big, cap);
        try testing.expectEqual(required, ret);
        try testing.expect(ret > cap);
        // Ids carry no `]`, so the first `]` ends the written region.
        const end = std.mem.indexOfScalar(u8, big[0..cap], ']') orelse
            return error.TestUnexpectedResult;
        var p = try std.json.parseFromSlice([]u64, testing.allocator, big[0 .. end + 1], .{});
        try testing.expect(p.value.len < total);
        p.deinit();
        try testing.expectEqual(@as(u8, 0xAA), big[cap]);
    }
}

// ── Events: emit by name ────────────────────────────────────────────

test "event emit: named union variant parsed from JSON into the game buffer" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    try testing.expectEqual(@as(i32, 0), emitEvent("turret__fired", "{\"turret\":7,\"heat\":0.5}"));
    try testing.expectEqual(@as(usize, 1), game.event_buffer.items.len);
    switch (game.event_buffer.items[0]) {
        .turret__fired => |p| {
            try testing.expectEqual(@as(u32, 7), p.turret);
            try testing.expectApproxEqAbs(@as(f32, 0.5), p.heat, 0.0001);
        },
        else => return error.TestUnexpectedResult,
    }

    // Empty payload = all-default fields.
    try testing.expectEqual(@as(i32, 0), emitEvent("wave__started", ""));
    switch (game.event_buffer.items[1]) {
        .wave__started => |p| try testing.expectEqual(@as(u32, 0), p.index),
        else => return error.TestUnexpectedResult,
    }

    // Unknown event name / malformed payload: -1, nothing buffered.
    try testing.expectEqual(@as(i32, -1), emitEvent("nope__event", "{}"));
    try testing.expectEqual(@as(i32, -1), emitEvent("turret__fired", "{\"turret\":"));
    try testing.expectEqual(@as(usize, 2), game.event_buffer.items.len);
}

test "event emit: void payloads accept exactly empty, {} and null" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // A void variant has no payload struct for std.json to validate
    // against, so the accept set is pinned explicitly (module doc +
    // header): anything outside it — malformed bytes included — is the
    // contract's parse failure, -1 with nothing buffered.
    try testing.expectEqual(@as(i32, -1), emitEvent("game__paused", "{"));
    try testing.expectEqual(@as(i32, -1), emitEvent("game__paused", "{\"x\":1}"));
    try testing.expectEqual(@as(i32, -1), emitEvent("game__paused", "garbage"));
    try testing.expectEqual(@as(i32, -1), emitEvent("game__paused", " {} ")); // exact bytes only
    try testing.expectEqual(@as(usize, 0), game.event_buffer.items.len);

    // The accept set: empty (len 0), NULL (a C caller's natural "no
    // payload"), the exact "{}", and the exact "null".
    try testing.expectEqual(@as(i32, 0), emitEvent("game__paused", ""));
    const name = "game__paused";
    try testing.expectEqual(@as(i32, 0), contract.labelle_event_emit(name.ptr, name.len, null, 0));
    try testing.expectEqual(@as(i32, 0), emitEvent("game__paused", "{}"));
    try testing.expectEqual(@as(i32, 0), emitEvent("game__paused", "null"));
    try testing.expectEqual(@as(usize, 4), game.event_buffer.items.len);
    for (game.event_buffer.items) |ev| {
        try testing.expect(ev == .game__paused);
    }

    // Struct-payload variants keep std.json's whole-document check:
    // trailing garbage after the JSON is a parse failure there too.
    try testing.expectEqual(@as(i32, -1), emitEvent("turret__fired", "{\"turret\":1}garbage"));
    try testing.expectEqual(@as(usize, 4), game.event_buffer.items.len);
}

test "event emit: a game without a GameEvents union refuses with -1" {
    contract.unbind();
    defer contract.unbind();

    // engine.Game is the GameWith(void) shape: `GameEvents = void`, and
    // its EmptyComponents registry has no getType — binding it also
    // proves the registry loops fold away safely on the minimal shape.
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    try testing.expectEqual(@as(i32, -1), emitEvent("turret__fired", "{}"));
    // The tap is a comptime no-op — must compile and do nothing.
    contract.drainEvents(&game);

    // Registry ops on the registry-less game: only Position resolves.
    const id = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":5,\"y\":6}"));
    try testing.expectEqual(@as(i32, -1), setComp(id, "Health", "{\"hp\":1}"));
}

// ── Events: subscribe / drain / poll FIFO ───────────────────────────

test "subscribe/poll: name-filtered FIFO in emission order; the tap does not consume the buffer" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    subscribe("turret__fired");
    subscribe("turret__fired"); // deduped (while still pending) — no double delivery
    // A subscription activates at the END of a drain (effective-next-
    // drain, no same-tick replay) — run the subscribe tick's drain
    // before emitting so the next frame's events match.
    contract.drainEvents(&game);

    // Mixed emitters, one frame: contract-side and Zig-side (game.emit)
    // both flow through the buffered path the tap walks.
    try testing.expectEqual(@as(i32, 0), emitEvent("turret__fired", "{\"turret\":1,\"heat\":0.25}"));
    game.emit(.{ .wave__started = .{ .index = 3 } }); // not subscribed
    game.emit(.{ .turret__fired = .{ .turret = 2, .heat = 0.75 } });

    contract.drainEvents(&game);

    // The tap COPIES; dispatch still sees all three events.
    try testing.expectEqual(@as(usize, 3), game.event_buffer.items.len);
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 0), game.event_buffer.items.len);

    // FIFO: subscribed events in emission order, `<name> <json>` shape.
    var buf: [256]u8 = undefined;
    const first = poll(&buf);
    try testing.expect(std.mem.startsWith(u8, first, "turret__fired "));
    {
        const payload = first["turret__fired ".len..];
        const p = try std.json.parseFromSlice(
            @FieldType(TestEvents, "turret__fired"),
            testing.allocator,
            payload,
            .{},
        );
        defer p.deinit();
        try testing.expectEqual(@as(u32, 1), p.value.turret);
    }
    const second = poll(&buf);
    try testing.expect(std.mem.startsWith(u8, second, "turret__fired "));
    {
        const payload = second["turret__fired ".len..];
        const p = try std.json.parseFromSlice(
            @FieldType(TestEvents, "turret__fired"),
            testing.allocator,
            payload,
            .{},
        );
        defer p.deinit();
        try testing.expectEqual(@as(u32, 2), p.value.turret);
    }

    // wave__started was filtered out; the inbox is now empty.
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);

    // A fresh frame with no subscribed events queues nothing.
    game.emit(.{ .wave__started = .{ .index = 4 } });
    contract.drainEvents(&game);
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);
}

test "subscribe mid-tick: effective-next-drain — no same-tick replay, next tick delivers" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // Tick N, the engine__tick shape: an event is buffered BEFORE the
    // script subscribes (engine emits precede script execution), and
    // another lands after the subscribe, still in the same tick.
    game.emit(.{ .turret__fired = .{ .turret = 1 } });
    subscribe("turret__fired");
    game.emit(.{ .turret__fired = .{ .turret = 2 } });
    contract.drainEvents(&game); // the same tick's drain
    game.dispatchEvents();

    // Neither event is delivered: the subscription was PENDING for the
    // whole of tick N's drain — a mid-tick subscribe must not replay a
    // past it never subscribed to (and activation is a drain boundary,
    // not a mid-buffer split).
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);

    // Tick N+1: the subscription is active now — delivery starts here,
    // and it is the NEW emit, not a replay of tick N's.
    game.emit(.{ .turret__fired = .{ .turret = 3 } });
    contract.drainEvents(&game);
    game.dispatchEvents();
    const entry = poll(&buf);
    try testing.expect(std.mem.startsWith(u8, entry, "turret__fired "));
    const p = try std.json.parseFromSlice(
        @FieldType(TestEvents, "turret__fired"),
        testing.allocator,
        entry["turret__fired ".len..],
        .{},
    );
    defer p.deinit();
    try testing.expectEqual(@as(u32, 3), p.value.turret);
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);
}

test "subscribe/poll: slice-bearing payload survives emit → drain → dispatch (two-arena lifetime)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    subscribe("state__renamed");
    contract.drainEvents(&game); // activate the subscription (next-drain semantics)

    // Frame 1: emit with a string payload FROM A TRANSIENT BUFFER —
    // the plugin's json is only valid during the call — and poison it
    // the moment the call returns. The parsed slice must be a COPY in
    // the ACTIVE emit arena, never a borrow of the caller's bytes
    // ("combat" needs no unescaping, the exact case alloc_if_needed
    // would alias).
    var jsonbuf: [32]u8 = undefined;
    const src = "{\"name\":\"combat\"}";
    @memcpy(jsonbuf[0..src.len], src);
    const ev_name = "state__renamed";
    try testing.expectEqual(
        @as(i32, 0),
        contract.labelle_event_emit(ev_name.ptr, ev_name.len, &jsonbuf, src.len),
    );
    @memset(&jsonbuf, 0xAA); // the buffer dies/reuses after the call
    contract.drainEvents(&game); // flips arenas — must NOT recycle this frame's payload
    switch (game.event_buffer.items[0]) {
        .state__renamed => |p| try testing.expectEqualStrings("combat", p.name),
        else => return error.TestUnexpectedResult,
    }
    game.dispatchEvents();

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("state__renamed {\"name\":\"combat\"}", poll(&buf));

    // Frames 2 + 3: both arenas recycle; nothing dangles, nothing polls.
    contract.drainEvents(&game);
    game.dispatchEvents();
    contract.drainEvents(&game);
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);
}

test "subscribe pre-bind is a no-op; unpolled inbox entries free on unbind" {
    contract.unbind();
    defer contract.unbind();

    // Pre-bind subscribe records nothing (the generated main always
    // binds before plugin setup).
    subscribe("turret__fired");

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    game.emit(.{ .turret__fired = .{} });
    contract.drainEvents(&game);
    game.dispatchEvents();
    var buf: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), poll(&buf).len); // pre-bind sub didn't stick

    // Now a real subscription (activated by a drain — next-drain
    // semantics); leave an entry UNPOLLED at unbind — the testing
    // allocator flags it if unbind doesn't free.
    subscribe("turret__fired");
    contract.drainEvents(&game);
    game.emit(.{ .turret__fired = .{ .turret = 9 } });
    game.emit(.{ .turret__fired = .{ .turret = 10 } });
    contract.drainEvents(&game);
    game.dispatchEvents();
    _ = poll(&buf); // consume one, leave one pending
}

test "poll: budgeted polling (a backlog always left pending) keeps the inbox storage bounded" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    subscribe("turret__fired");
    contract.drainEvents(&game); // activate the subscription (next-drain semantics)

    // Frame 0 polls one FEWER than arrived; every later frame polls at
    // matched throughput — so the inbox carries a standing backlog and
    // never runs empty. The compact-only-when-empty scheme never fired
    // here: `inbox_head` advanced forever while appends landed at
    // `items.len`, growing the backing array every frame even though
    // the pending count stayed at ~1. The threshold compaction slides
    // the pending tail back to index 0 instead.
    var buf: [128]u8 = undefined;
    var settled: usize = 0;
    var frame: usize = 0;
    while (frame < 100) : (frame += 1) {
        game.emit(.{ .turret__fired = .{ .turret = 1 } });
        game.emit(.{ .turret__fired = .{ .turret = 2 } });
        contract.drainEvents(&game);
        game.dispatchEvents();
        try testing.expect(poll(&buf).len > 0);
        if (frame > 0) try testing.expect(poll(&buf).len > 0);
        // A few frames in the capacity must have settled for good:
        // pending stays at one carried entry + the frame's traffic.
        if (frame == 10) settled = contract.inboxCapacity();
        if (frame > 10) try testing.expect(contract.inboxCapacity() <= settled);
    }
    // The standing backlog entry is still pending here; the deferred
    // unbind frees it (proven leak-free by the test above).
}

// ── Scene change ────────────────────────────────────────────────────

test "scene_change: 0 on a known scene, -1 leaves the running scene alone" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const loader = struct {
        fn load(g: *ContractGame) anyerror!void {
            const e = g.createEntity();
            g.setPosition(e, .{ .x = 0, .y = 0 });
            g.trackSceneEntity(e);
        }
    }.load;
    game.registerSceneSimple("arena", loader);

    try testing.expectEqual(@as(i32, 0), contract.labelle_scene_change("arena", 5));
    try testing.expectEqualStrings("arena", game.getCurrentSceneName().?);
    try testing.expectEqual(@as(usize, 1), game.entityCount());

    // Unknown scene: refused up front — nothing torn down.
    try testing.expectEqual(@as(i32, -1), contract.labelle_scene_change("nope", 4));
    try testing.expectEqualStrings("arena", game.getCurrentSceneName().?);
    try testing.expectEqual(@as(usize, 1), game.entityCount());
}

// ── Prefab spawn ────────────────────────────────────────────────────

const PrefabBridge = engine.JsoncSceneBridge(ContractGame, TestComponents);

const TURRET_PREFAB =
    \\{ "components": { "Health": { "hp": 55 } } }
;

/// Boot the assembler's wasm sequence: embedded prefab registration,
/// then a scene load (which attaches the prefab cache to the game and
/// enables `spawnPrefab`) — the editor_api_test bootPrefabGame shape.
fn bootPrefabGame(game: *ContractGame) !void {
    try PrefabBridge.addEmbeddedPrefab(game, "turret", TURRET_PREFAB, "prefabs");
    try PrefabBridge.loadSceneFromSource(game,
        \\{ "root": { "children": [] } }
    , "prefabs");
}

test "prefab_spawn: positions from params JSON; empty params spawn at origin" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    try bootPrefabGame(&game);
    contract.bind(&game);

    // Positioned spawn.
    const id = spawnPrefab("turret", "{\"x\":30,\"y\":40}");
    try testing.expect(id != 0);
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 55), game.getComponent(ent, Health).?.hp);
    const pos = game.getComponent(ent, core.Position).?;
    try testing.expectEqual(@as(f32, 30), pos.x);
    try testing.expectEqual(@as(f32, 40), pos.y);

    // Empty params: origin. Unknown params keys: ignored.
    const id2 = spawnPrefab("turret", "");
    try testing.expect(id2 != 0);
    const pos2 = game.getComponent(@as(u32, @intCast(id2)), core.Position).?;
    try testing.expectEqual(@as(f32, 0), pos2.x);
    const id3 = spawnPrefab("turret", "{\"x\":1,\"facing\":\"left\"}");
    try testing.expect(id3 != 0);

    // Failure modes: unknown prefab / malformed params → 0.
    try testing.expectEqual(@as(u64, 0), spawnPrefab("ghost", ""));
    try testing.expectEqual(@as(u64, 0), spawnPrefab("turret", "{\"x\":"));
}

test "prefab_spawn: 0 before any JSONC scene attached the prefab cache" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    try testing.expectEqual(@as(u64, 0), spawnPrefab("turret", ""));
}

// ── NULL-pointer ABI shapes ─────────────────────────────────────────

test "NULL C-ABI shapes: NULL/len-0 payloads take defaults; NULL out buffers probe safely" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    try bootPrefabGame(&game);
    contract.bind(&game);

    // prefab_spawn with params_json = NULL/0 — the header's documented
    // origin-spawn shape (a C caller's natural "no params").
    const name = "turret";
    const id = contract.labelle_prefab_spawn(name.ptr, name.len, null, 0);
    try testing.expect(id != 0);
    const pos = game.getComponent(@as(u32, @intCast(id)), core.Position).?;
    try testing.expectEqual(@as(f32, 0), pos.x);
    try testing.expectEqual(@as(f32, 0), pos.y);

    // component_set with NULL json = "{}": the whole struct resets to
    // its declared defaults (hp 100, not the prefab's 55).
    const health = "Health";
    try testing.expectEqual(
        @as(i32, 0),
        contract.labelle_component_set(id, health.ptr, health.len, null, 0),
    );
    try testing.expectEqual(@as(i32, 100), game.getComponent(@as(u32, @intCast(id)), Health).?.hp);

    // event_emit with NULL json = "{}" (all-default payload). Subscribe
    // FIRST and run a drain so the subscription is active when the
    // NULL-emitted event is tapped below (next-drain semantics — a
    // subscribe after the emit would see nothing this tick).
    subscribe("wave__started");
    contract.drainEvents(&game);
    const wave = "wave__started";
    try testing.expectEqual(
        @as(i32, 0),
        contract.labelle_event_emit(wave.ptr, wave.len, null, 0),
    );
    switch (game.event_buffer.items[game.event_buffer.items.len - 1]) {
        .wave__started => |p| try testing.expectEqual(@as(u32, 0), p.index),
        else => return error.TestUnexpectedResult,
    }

    // NULL out buffers are pure SIZING PROBES: component_get returns
    // the required size of the complete JSON (nothing written) and a
    // right-sized call returns the same…
    const get_required = contract.labelle_component_get(id, health.ptr, health.len, null, 0);
    try testing.expect(get_required > 0);
    var gbuf: [128]u8 = undefined;
    try testing.expectEqual(
        get_required,
        contract.labelle_component_get(id, health.ptr, health.len, &gbuf, gbuf.len),
    );
    // …query probes identically (the shared snprintf-style sizing)…
    const names = "[\"Health\"]";
    const probe = contract.labelle_query(names.ptr, names.len, null, 0);
    try testing.expect(probe > 2);
    var qbuf: [64]u8 = undefined;
    try testing.expectEqual(
        probe,
        contract.labelle_query(names.ptr, names.len, &qbuf, qbuf.len),
    );

    // …and poll's NULL probe reports the NEXT entry's size while
    // consuming NOTHING: the entry survives — repeatedly — until the
    // real poll reads it, after which the probe is back to 0 (empty).
    contract.drainEvents(&game); // taps the NULL-emitted wave event above
    game.dispatchEvents();
    const entry = "wave__started {\"index\":0}";
    try testing.expectEqual(entry.len, contract.labelle_event_poll(null, 0));
    try testing.expectEqual(entry.len, contract.labelle_event_poll(null, 0));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(entry, poll(&buf));
    try testing.expectEqual(@as(usize, 0), contract.labelle_event_poll(null, 0));
}

// ── Time / log ──────────────────────────────────────────────────────

test "time_dt: last tick's scaled dt; 0 while paused and before the first tick" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // No tick yet.
    try testing.expectEqual(@as(f32, 0), contract.labelle_time_dt());

    game.tick(0.016);
    try testing.expectApproxEqAbs(@as(f32, 0.016), contract.labelle_time_dt(), 0.0001);

    // Scripts observe the GAMEPLAY dt: real dt × time_scale.
    game.setTimeScale(0.5);
    game.tick(0.016);
    try testing.expectApproxEqAbs(@as(f32, 0.008), contract.labelle_time_dt(), 0.0001);
    game.setTimeScale(1.0);

    // Paused: scripts don't advance, dt reads 0; resume restores.
    game.setPaused(true);
    try testing.expectEqual(@as(f32, 0), contract.labelle_time_dt());
    game.setPaused(false);
    game.tick(0.020);
    try testing.expectApproxEqAbs(@as(f32, 0.020), contract.labelle_time_dt(), 0.0001);
}

test "time_dt: the plugin's stamped dt wins over the profiler reconstruction" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // Unstamped session: the profiler fallback (the pre-plugin path).
    game.tick(0.016);
    try testing.expectApproxEqAbs(@as(f32, 0.016), contract.labelle_time_dt(), 0.0001);

    // The plugin stamps the scaled dt it was handed; a script then
    // changes time_scale MID-TICK. Scripts must still observe the dt
    // this frame's Zig scripts got — the profiler reconstruction would
    // report last-real-dt × the NEW scale instead.
    contract.labelle_time_dt_stamp(0.016);
    game.setTimeScale(0.25);
    try testing.expectEqual(@as(f32, 0.016), contract.labelle_time_dt());
    game.setTimeScale(1.0);

    // Exactness: the stamp is returned verbatim, not recomputed.
    contract.labelle_time_dt_stamp(0.125);
    try testing.expectEqual(@as(f32, 0.125), contract.labelle_time_dt());

    // Rebind = a fresh plugin session: the stamp resets, the fallback
    // takes over again.
    contract.bind(&game);
    try testing.expectApproxEqAbs(@as(f32, 0.016), contract.labelle_time_dt(), 0.0001);
    game.tick(0.020);
    try testing.expectApproxEqAbs(@as(f32, 0.020), contract.labelle_time_dt(), 0.0001);
}

test "time_dt_stamp: pre-bind stamps are ignored and never leak into a session" {
    contract.unbind();
    defer contract.unbind();

    contract.labelle_time_dt_stamp(0.5);
    try testing.expectEqual(@as(f32, 0), contract.labelle_time_dt());

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // No tick yet and no session stamp: the fallback's 0, not 0.5.
    try testing.expectEqual(@as(f32, 0), contract.labelle_time_dt());
}

test "log: routes through the game log sink without crashing" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    contract.labelle_log("hello from a script", 19);
    contract.labelle_log("x", 0); // empty: ignored
}

// ── Rebind ──────────────────────────────────────────────────────────

test "bind twice: the second bind starts a fresh session (no leaks, no stale subscriptions)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    subscribe("turret__fired");
    contract.drainEvents(&game); // activate (next-drain semantics)
    game.emit(.{ .turret__fired = .{} });
    contract.drainEvents(&game); // tap: one inbox entry now pending
    // A second, NOT-yet-activated subscription: rebind must free the
    // pending-subscription set too, not just the active one.
    subscribe("wave__started");

    // Re-bind (e.g. a restarted plugin session): pending entries and
    // subscriptions (active AND pending) from the first session are
    // torn down.
    contract.bind(&game);
    var buf: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);

    // The first session's subscription is gone too: fresh emits don't
    // queue until this session subscribes again.
    game.emit(.{ .turret__fired = .{} });
    contract.drainEvents(&game);
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);
}

// ── entity_find + input: a game with a Name component and a ────────────
//    controllable input backend
//
// `entity_find` resolves through a registry component named `Name`/`Tag`
// carrying a string field, so the feature game registers a `Name`. The
// input backend dispatches to *type* decls (static fns, process-global
// state — the real backends' shape), reset between tests.

const Name = struct { name: []const u8 = "" };

/// Controllable input stub: reports one down key, one press-edge key, and
/// a settable mouse position. Only `isKeyDown`/`isKeyPressed` are required
/// by `InputInterface`; `getMouseX`/`getMouseY` are the optional mouse seam.
const KeyInput = struct {
    var down_key: ?u32 = null;
    var pressed_key: ?u32 = null;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;

    fn reset() void {
        down_key = null;
        pressed_key = null;
        mouse_x = 0;
        mouse_y = 0;
    }

    pub fn isKeyDown(key: u32) bool {
        return down_key != null and down_key.? == key;
    }
    pub fn isKeyPressed(key: u32) bool {
        return pressed_key != null and pressed_key.? == key;
    }
    pub fn getMouseX() f32 {
        return mouse_x;
    }
    pub fn getMouseY() f32 {
        return mouse_y;
    }
};

const FeatureComponents = engine.ComponentRegistry(.{
    .Name = Name,
    .Health = Health,
});

const FeatureGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    KeyInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    FeatureComponents,
    &.{},
    TestEvents,
);

test "entity_find: resolves an entity by its Name component; first live match" {
    contract.unbind();
    defer contract.unbind();

    var game = FeatureGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const a = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(a, "Name", "{\"name\":\"player\"}"));
    const b = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(b, "Name", "{\"name\":\"enemy\"}"));

    try testing.expectEqual(a, findEntity("player"));
    try testing.expectEqual(b, findEntity("enemy"));

    // No match / empty name → 0.
    try testing.expectEqual(@as(u64, 0), findEntity("nobody"));
    try testing.expectEqual(@as(u64, 0), findEntity(""));

    // After the named entity is destroyed the name no longer resolves.
    contract.labelle_entity_destroy(a);
    try testing.expectEqual(@as(u64, 0), findEntity("player"));
    try testing.expectEqual(b, findEntity("enemy"));
}

test "entity_find: comptime-gated out for a game with no Name/Tag component" {
    contract.unbind();
    defer contract.unbind();

    // ContractGame's registry has Health/Velocity/Doomed/Label — no
    // Name/Tag — so the lookup folds away at comptime: always 0, never a
    // crash, even after a real entity with a component exists.
    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const e = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(e, "Label", "{\"text\":\"player\"}"));
    try testing.expectEqual(@as(u64, 0), findEntity("player"));
}

test "input_key_down / input_key_pressed: reflect the backend, unknown codes read up" {
    contract.unbind();
    defer contract.unbind();
    KeyInput.reset();
    defer KeyInput.reset();

    var game = FeatureGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const space: u32 = @intFromEnum(engine.KeyboardKey.space);
    const enter: u32 = @intFromEnum(engine.KeyboardKey.enter);

    KeyInput.down_key = space;
    KeyInput.pressed_key = enter;

    try testing.expectEqual(@as(i32, 1), contract.labelle_input_key_down(space));
    try testing.expectEqual(@as(i32, 0), contract.labelle_input_key_down(enter));
    try testing.expectEqual(@as(i32, 1), contract.labelle_input_key_pressed(enter));
    try testing.expectEqual(@as(i32, 0), contract.labelle_input_key_pressed(space));

    // A code nothing reports is simply not down.
    try testing.expectEqual(@as(i32, 0), contract.labelle_input_key_down(9999));
}

test "input_mouse: writes the reported position; NULL out-pointers are skipped" {
    contract.unbind();
    defer contract.unbind();
    KeyInput.reset();
    defer KeyInput.reset();

    var game = FeatureGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    KeyInput.mouse_x = 320.5;
    KeyInput.mouse_y = 240.0;

    var x: f32 = -1;
    var y: f32 = -1;
    contract.labelle_input_mouse(&x, &y);
    try testing.expectEqual(@as(f32, 320.5), x);
    try testing.expectEqual(@as(f32, 240.0), y);

    // Either out-pointer may be NULL — the other axis still lands, no crash.
    var only_y: f32 = -1;
    contract.labelle_input_mouse(null, &only_y);
    try testing.expectEqual(@as(f32, 240.0), only_y);
    contract.labelle_input_mouse(&x, null); // both-write path already checked
}
