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

const TestComponents = engine.ComponentRegistry(.{
    .Health = Health,
    .Velocity = Velocity,
    .Doomed = Doomed,
});

const TestEvents = union(enum) {
    turret__fired: struct { turret: u32 = 0, heat: f32 = 0 },
    wave__started: struct { index: u32 = 0 },
    // Slice-bearing payload — pins the emit-arena lifetime contract
    // (parsed name must survive from emit through dispatch).
    state__renamed: struct { name: []const u8 = "" },
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

fn getComp(id: u64, name: []const u8, buf: []u8) []const u8 {
    const n = contract.labelle_component_get(id, name.ptr, name.len, buf.ptr, buf.len);
    return buf[0..n];
}

fn hasComp(id: u64, name: []const u8) i32 {
    return contract.labelle_component_has(id, name.ptr, name.len);
}

fn removeComp(id: u64, name: []const u8) i32 {
    return contract.labelle_component_remove(id, name.ptr, name.len);
}

fn query(names_json: []const u8, buf: []u8) []const u8 {
    const n = contract.labelle_query(names_json.ptr, names_json.len, buf.ptr, buf.len);
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
    var tiny: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), getComp(id, "Health", &tiny).len); // doesn't fit
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

test "query: id list truncates at the last whole id and stays valid JSON" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        _ = setComp(contract.labelle_entity_create(), "Health", "{}");
    }

    // Full result parses.
    var big: [1024]u8 = undefined;
    const full = query("[\"Health\"]", &big);
    var parsed = try std.json.parseFromSlice([]u64, testing.allocator, full, .{});
    const total = parsed.value.len;
    parsed.deinit();
    try testing.expectEqual(@as(usize, 50), total);

    // Every cap must yield valid JSON — truncated, never torn.
    var cap: usize = 2;
    while (cap <= 64) : (cap += 3) {
        const out = query("[\"Health\"]", big[0..cap]);
        var p = try std.json.parseFromSlice([]u64, testing.allocator, out, .{});
        try testing.expect(p.value.len <= total);
        p.deinit();
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
    subscribe("turret__fired"); // deduped — no double delivery

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

test "subscribe/poll: slice-bearing payload survives emit → drain → dispatch (two-arena lifetime)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    subscribe("state__renamed");

    // Frame 1: emit with a string payload. The parsed slice lives in
    // the ACTIVE emit arena.
    try testing.expectEqual(@as(i32, 0), emitEvent("state__renamed", "{\"name\":\"combat\"}"));
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

    // Now a real subscription; leave an entry UNPOLLED at unbind — the
    // testing allocator flags it if unbind doesn't free.
    subscribe("turret__fired");
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
        \\{ "entities": [] }
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

    // event_emit with NULL json = "{}" (all-default payload).
    const wave = "wave__started";
    try testing.expectEqual(
        @as(i32, 0),
        contract.labelle_event_emit(wave.ptr, wave.len, null, 0),
    );
    switch (game.event_buffer.items[game.event_buffer.items.len - 1]) {
        .wave__started => |p| try testing.expectEqual(@as(u32, 0), p.index),
        else => return error.TestUnexpectedResult,
    }

    // NULL out buffers: 0 bytes, nothing written.
    try testing.expectEqual(
        @as(usize, 0),
        contract.labelle_component_get(id, health.ptr, health.len, null, 0),
    );
    const names = "[\"Health\"]";
    try testing.expectEqual(@as(usize, 0), contract.labelle_query(names.ptr, names.len, null, 0));

    // poll with a NULL out reads NOTHING and consumes NOTHING: the
    // pending entry survives for the next real poll.
    subscribe("wave__started");
    contract.drainEvents(&game); // taps the NULL-emitted wave event above
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 0), contract.labelle_event_poll(null, 0));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("wave__started {\"index\":0}", poll(&buf));
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
    game.emit(.{ .turret__fired = .{} });
    contract.drainEvents(&game);

    // Re-bind (e.g. a restarted plugin session): pending entries and
    // subscriptions from the first session are torn down.
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
