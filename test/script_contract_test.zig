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

/// One field of each packed-codec scalar kind (f32/i64/bool/u64) — the
/// v1.3 packed round-trip component. Declaration order IS the wire
/// order, so the tests below hand-build the expected record.
const Stats = struct {
    power: f32 = 0,
    score: i64 = 0,
    alive: bool = false,
    seed: u64 = 0,
};

/// Narrow int fields — the packed SET's out-of-range refusal targets
/// (a script i64/f32 that doesn't fit must refuse -1, never panic).
const Tiny = struct { b: u8 = 7, w: i32 = -7 };

/// bool + f32 — the batch stream's non-float scalar (bool rides as 0/1;
/// a NaN stream float lands as true, since NaN != 0).
const Flag = struct { on: bool = false, weight: f32 = 0 };

/// Non-scalar field beside batch-eligible scalars — the batch
/// read-modify-write test component (the string must SURVIVE a batch
/// write that only carries x/on).
const Mixed = struct { text: []const u8 = "", x: f32 = 0, on: bool = false };

/// All-scalar but NO field defaults — RMW needs no `.{}` construction,
/// so this batches on both sides (the packed SET still refuses it:
/// REPLACE-from-defaults can't exist without defaults).
const Bare = struct { x: f32, y: f32 };

/// An f64 field — packable-looking but the packed wire only has an f32
/// tag, so it must comptime-classify as NOT packable (0xFF/JSON keeps
/// the precision).
const Precise = struct { d: f64 = 0 };

/// ZERO-WIDTH batch component (#782): string-only, so it contributes 0
/// stream bytes — a pure query FILTER. The onSet counter pins that
/// batch_set does NOT RMW-re-apply it (no hook/dirty churn for no
/// data); the plain per-entity set path still fires it (the sanity leg).
var marker_on_set_calls: u32 = 0;
const Marker = struct {
    note: []const u8 = "",

    pub fn onSet(payload: engine.ComponentPayload) void {
        _ = payload;
        marker_on_set_calls += 1;
    }
};

/// Hook-driven mid-apply mutation (#783 hole 2): applying a Reaper row
/// DESTROYS the pair's other entity from inside onSet — through the
/// contract's own export, exactly as a script-visible hook effect
/// would. The id-tagged batch set must downgrade the destroyed
/// entity's later row to a skip, never a partial-commit failure.
var reaper_pair: [2]u64 = .{ 0, 0 };
const Reaper = struct {
    hp: f32 = 0,

    pub fn onSet(payload: engine.ComponentPayload) void {
        const other = if (payload.entity_id == reaper_pair[0]) reaper_pair[1] else reaper_pair[0];
        contract.labelle_entity_destroy(other);
    }
};

/// Intra-row partial-commit guard (#788 review): `Trigger.onSet` removes
/// a SIBLING component (`Payload`) on the SAME entity mid-apply. When a
/// batch id-row names [Trigger, Payload, Keep], applying Trigger must not
/// leave the row half-written — Payload's now-absent slot is skipped, but
/// the still-present Keep still lands. `trigger_arm` gates the hook so it
/// only fires during the dedicated test (Trigger updates in other tests
/// stay inert).
var trigger_arm: bool = false;
const Trigger = struct {
    v: f32 = 0,

    pub fn onSet(payload: engine.ComponentPayload) void {
        if (!trigger_arm) return;
        _ = contract.labelle_component_remove(payload.entity_id, "Payload", 7);
    }
};
/// Data-bearing sibling the `Trigger` hook removes mid-row.
const Payload = struct { p: f32 = 0 };
/// Bystander sibling that must STILL apply after `Payload` is skipped —
/// proves the fix doesn't drop the row's remaining live components.
const Keep = struct { k: f32 = 0 };

/// Intra-row entity DESTRUCTION guard (#788 review, round 2): `SelfDestruct`'s
/// onSet destroys its OWN entity mid-row (not just a sibling component).
/// A later component's apply on the now-dead entity must be skipped via a
/// LIVENESS recheck (`entityExists`), never a use-after-destroy. Gated to
/// `self_destruct_target` so a bystander entity in the same batch still
/// applies its whole row (proving rows stay independent).
var self_destruct_target: u64 = 0;
const SelfDestruct = struct {
    v: f32 = 0,

    pub fn onSet(payload: engine.ComponentPayload) void {
        if (payload.entity_id == self_destruct_target) {
            contract.labelle_entity_destroy(payload.entity_id);
        }
    }
};

/// 300 f32 fields — over the packed wire's u8 field_count limit (0xFF
/// reserved as the sentinel), so it must comptime-classify as NOT
/// packable (get → 0xFF, set → -1) instead of panicking the `@intCast`
/// on packInto's count byte.
const Wide300 = blk: {
    @setEvalBranchQuota(1_000_000);
    var names: [300][:0]const u8 = undefined;
    var attrs: [300]std.builtin.Type.StructField.Attributes = undefined;
    for (&names, &attrs, 0..) |*n, *a, i| {
        n.* = std.fmt.comptimePrint("f{d}", .{i});
        a.* = .{ .default_value_ptr = &@as(f32, 0) };
    }
    const cn = names;
    const ca = attrs;
    break :blk @Struct(.auto, null, &cn, &@splat(f32), &ca);
};

/// One field whose NAME is over the wire's u8 name_len limit — same
/// comptime not-packable classification as Wide300.
const LongName = @Struct(
    .auto,
    null,
    &[_][:0]const u8{"x" ** 300},
    &[_]type{f32},
    &[_]std.builtin.Type.StructField.Attributes{.{ .default_value_ptr = &@as(f32, 0) }},
);

const TestComponents = engine.ComponentRegistry(.{
    .Health = Health,
    .Velocity = Velocity,
    .Doomed = Doomed,
    .Label = Label,
    .Stats = Stats,
    .Tiny = Tiny,
    .Flag = Flag,
    .Mixed = Mixed,
    .Bare = Bare,
    .Precise = Precise,
    .Wide300 = Wide300,
    .LongName = LongName,
    .Marker = Marker,
    .Reaper = Reaper,
    .Trigger = Trigger,
    .Payload = Payload,
    .Keep = Keep,
    .SelfDestruct = SelfDestruct,
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

/// Call plugin_call in the exact v1.1 shape (NULL/0 out) — the shape
/// the v1.1-compat fold pins to the v1.1 rc contract: 0 for EVERY
/// dispatched call (a handler response is published for fetch, never
/// returned as N here), sentinel for unroutable. The response tests
/// drive `labelle_plugin_call` with a real out buffer (`pluginCallOut`).
fn pluginCall(plugin: []const u8, command: []const u8, params: []const u8) usize {
    return contract.labelle_plugin_call(
        plugin.ptr,
        plugin.len,
        command.ptr,
        command.len,
        params.ptr,
        params.len,
        null,
        0,
    );
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
    // plugin_call carries its rc in a usize: pre-bind is unroutable.
    try testing.expectEqual(
        contract.plugin_call_unroutable,
        pluginCall("pathfinder", "navigate", "{}"),
    );

    // Boolean / out-writing ops: 0 bytes, 0 answer.
    try testing.expectEqual(@as(i32, 0), hasComp(1, "Health"));
    var buf: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), getComp(1, "Health", &buf).len);
    try testing.expectEqual(@as(usize, 0), query("[\"Health\"]", &buf).len);
    try testing.expectEqual(@as(usize, 0), poll(&buf).len);
    // No plugin_call ever ran → nothing stored to fetch (v1.2).
    try testing.expectEqual(@as(usize, 0), contract.labelle_plugin_response_fetch(&buf, buf.len));

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

// ── labelle_plugin_call: cross-language plugin commands (v1.1, #744) ──
//
// The export routes through the SAME handler channel labelle-studio's
// panels use — the game's `editorPluginCommand` mixin
// (`game/editor_command_mixin.zig`): a synchronous `emitSync` of
// `engine__editor_plugin_command` to the handler a plugin registered by
// subscribing to that engine event, so one registration is dual-use
// (studio + every language). Dispatch is fire-and-forward; the usize
// return is an rc — 0 = dispatched, `plugin_call_unroutable` = empty
// name / no handler in this build / not bound. These tests register a
// recorder through the REAL registration path (a hooks subscriber to
// the engine event — the editor_api_test shape) and pin both legs plus
// the reserved out-buffer.

const PluginCallEvents = union(enum) {
    engine__editor_plugin_command: engine.Events.editor_plugin_command,
};

const PluginCallRecorder = struct {
    count: usize = 0,
    last_plugin_buf: [64]u8 = undefined,
    last_plugin_len: usize = 0,
    last_command_buf: [64]u8 = undefined,
    last_command_len: usize = 0,
    last_params_buf: [128]u8 = undefined,
    last_params_len: usize = 0,

    // Dispatch is SYNCHRONOUS, so the borrowed script-owned slices are
    // valid here; copy them out because the assertions read after the
    // call returns.
    pub fn engine__editor_plugin_command(self: *PluginCallRecorder, info: anytype) void {
        self.count += 1;
        @memcpy(self.last_plugin_buf[0..info.plugin.len], info.plugin);
        self.last_plugin_len = info.plugin.len;
        @memcpy(self.last_command_buf[0..info.command.len], info.command);
        self.last_command_len = info.command.len;
        @memcpy(self.last_params_buf[0..info.params.len], info.params);
        self.last_params_len = info.params.len;
    }
    fn lastPlugin(self: *const PluginCallRecorder) []const u8 {
        return self.last_plugin_buf[0..self.last_plugin_len];
    }
    fn lastCommand(self: *const PluginCallRecorder) []const u8 {
        return self.last_command_buf[0..self.last_command_len];
    }
    fn lastParams(self: *const PluginCallRecorder) []const u8 {
        return self.last_params_buf[0..self.last_params_len];
    }
};

/// A project whose merged `GameEvents` carries the plugin-command
/// channel (a plugin consumed `engine__editor_plugin_command`) — the
/// wired-up path.
const PluginCallGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *PluginCallRecorder,
    core.StubLogSink,
    TestComponents,
    &.{},
    PluginCallEvents,
);

test "plugin_call: routes through the editorPluginCommand mixin to the registered handler" {
    contract.unbind();
    defer contract.unbind();

    var recorder = PluginCallRecorder{};
    var game = PluginCallGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // One call, the handler fired synchronously (before the return),
    // {plugin, command, params} verbatim.
    try testing.expectEqual(
        @as(usize, 0),
        pluginCall("pathfinder", "navigate", "{\"entity\":7,\"to\":{\"x\":3,\"y\":4}}"),
    );
    try testing.expectEqual(@as(usize, 1), recorder.count);
    try testing.expectEqualStrings("pathfinder", recorder.lastPlugin());
    try testing.expectEqualStrings("navigate", recorder.lastCommand());
    try testing.expectEqualStrings("{\"entity\":7,\"to\":{\"x\":3,\"y\":4}}", recorder.lastParams());

    // The channel is a BROADCAST handlers name-filter themselves: a
    // plugin/command no handler claims still dispatches as 0 wherever a
    // handler exists — dispatched-and-ignored is indistinguishable from
    // handled (the documented encoding; acks travel back as events).
    try testing.expectEqual(@as(usize, 0), pluginCall("nonexistent_plugin", "whatever", "{}"));
    try testing.expectEqual(@as(usize, 2), recorder.count);
    try testing.expectEqualStrings("nonexistent_plugin", recorder.lastPlugin());

    // A dispatched call whose handlers never respond leaves out/out_cap
    // untouched (canary intact) and returns the rc 0 — under v1.2 this
    // is exactly the v1.1 reserved behavior, byte for byte.
    var out: [32]u8 = undefined;
    @memset(&out, 0xAA);
    const plugin = "pathfinder";
    const command = "navigate";
    const params = "{}";
    try testing.expectEqual(@as(usize, 0), contract.labelle_plugin_call(
        plugin.ptr,
        plugin.len,
        command.ptr,
        command.len,
        params.ptr,
        params.len,
        &out,
        out.len,
    ));
    for (out) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    try testing.expectEqual(@as(usize, 3), recorder.count);
}

test "plugin_call: NULL/len-0 params dispatch as {} (the optionalJson convention)" {
    contract.unbind();
    defer contract.unbind();

    var recorder = PluginCallRecorder{};
    var game = PluginCallGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // NULL params — a C caller's natural "no arguments".
    const plugin = "pathfinder";
    const command = "cancel";
    try testing.expectEqual(@as(usize, 0), contract.labelle_plugin_call(
        plugin.ptr,
        plugin.len,
        command.ptr,
        command.len,
        null,
        0,
        null,
        0,
    ));
    try testing.expectEqual(@as(usize, 1), recorder.count);
    try testing.expectEqualStrings("{}", recorder.lastParams());

    // Non-NULL empty params take the same default.
    try testing.expectEqual(@as(usize, 0), pluginCall("pathfinder", "cancel", ""));
    try testing.expectEqual(@as(usize, 2), recorder.count);
    try testing.expectEqualStrings("{}", recorder.lastParams());
}

test "plugin_call: unroutable sentinel — pre-bind, no handler channel, empty names" {
    contract.unbind();
    defer contract.unbind();

    // The sentinel is the rc convention's -1 as a usize — the header's
    // ((size_t)-1) — pinned so the C define and the Zig const can't
    // drift apart.
    try testing.expectEqual(std.math.maxInt(usize), contract.plugin_call_unroutable);

    // Pre-bind: the documented no-op — unroutable, nothing dispatched.
    try testing.expectEqual(
        contract.plugin_call_unroutable,
        pluginCall("pathfinder", "navigate", "{}"),
    );

    // Bound to a game whose GameEvents never consumed
    // `engine__editor_plugin_command` (ContractGame's TestEvents): no
    // handler registered in this build, so the mixin's comptime gate
    // folds to the graceful degrade. This is what "unknown plugin"
    // looks like at the engine level — nobody subscribed, unroutable.
    {
        var game = ContractGame.init(testing.allocator);
        defer game.deinit();
        contract.bind(&game);
        try testing.expectEqual(
            contract.plugin_call_unroutable,
            pluginCall("pathfinder", "navigate", "{}"),
        );
    }
    contract.unbind();

    // Bound WITH a handler channel but an empty plugin/command: refused
    // before dispatch — the handler never fires.
    var recorder = PluginCallRecorder{};
    var game = PluginCallGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);
    try testing.expectEqual(contract.plugin_call_unroutable, pluginCall("", "navigate", "{}"));
    try testing.expectEqual(contract.plugin_call_unroutable, pluginCall("pathfinder", "", "{}"));
    try testing.expectEqual(@as(usize, 0), recorder.count);
}

test "plugin_call: the minimal engine.Game shape compiles and degrades to unroutable" {
    contract.unbind();
    defer contract.unbind();

    // engine.Game is the GameWith(void) shape (EmptyComponents,
    // `GameEvents = void`): the mixin decl exists but its handler
    // channel comptime-folds away — the call must compile and return
    // the degrade sentinel, never crash (the event-emit refusal test's
    // pattern).
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    try testing.expectEqual(
        contract.plugin_call_unroutable,
        pluginCall("pathfinder", "navigate", "{}"),
    );
}

// ── plugin-call responses (contract v1.2, #758) ─────────────────────
//
// A handler may RESPOND to the command it is handling by calling
// `engine.plugin_command.respond`/`respondFmt` inside the synchronous
// dispatch window; the caller receives it through the activated
// `out`/`out_cap` (required-size, all-or-nothing — the semantics v1.1
// reserved) and, side-effect-free, through the paired
// `labelle_plugin_response_fetch`. One response per command,
// first-writer-wins across the broadcast. These tests register
// responders through the REAL registration path (hooks subscribers to
// the engine event) and pin every leg, including the load-bearing
// negative: a response READ never re-executes the handler.

/// `labelle_plugin_call` with a real out buffer (the v1.2 shape).
fn pluginCallOut(plugin: []const u8, command: []const u8, params: []const u8, out: []u8) usize {
    return contract.labelle_plugin_call(
        plugin.ptr,
        plugin.len,
        command.ptr,
        command.len,
        params.ptr,
        params.len,
        out.ptr,
        out.len,
    );
}

/// Responding handler — command-selected behaviors so one recorder
/// covers every respond flavor. `count` is the double-execution canary;
/// `respond_accepted` records what the (last) respond call returned.
const RespondingRecorder = struct {
    count: usize = 0,
    respond_accepted: ?bool = null,

    pub fn engine__editor_plugin_command(self: *RespondingRecorder, info: anytype) void {
        self.count += 1;
        if (std.mem.eql(u8, info.command, "silent")) return; // fire-and-forward leg
        if (std.mem.eql(u8, info.command, "empty")) {
            self.respond_accepted = engine.plugin_command.respond("");
            return;
        }
        if (std.mem.eql(u8, info.command, "huge")) {
            var big: [engine.plugin_command.max_response_len + 100]u8 = undefined;
            @memset(&big, 'x');
            self.respond_accepted = engine.plugin_command.respond(&big);
            return;
        }
        if (std.mem.eql(u8, info.command, "fmt")) {
            self.respond_accepted = engine.plugin_command.respondFmt(
                "{{\"echo\":{s}}}",
                .{info.params},
            );
            return;
        }
        if (std.mem.eql(u8, info.command, "double")) {
            _ = engine.plugin_command.respond("first");
            self.respond_accepted = engine.plugin_command.respond("second");
            return;
        }
        // Default ("ping" etc.): a fixed 13-byte JSON response.
        self.respond_accepted = engine.plugin_command.respond("{\"pong\":true}");
    }
};

const RespondGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *RespondingRecorder,
    core.StubLogSink,
    TestComponents,
    &.{},
    PluginCallEvents,
);

test "plugin_call responses: respond returns required size + all-or-nothing write" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // Fits: required size returned, response written, tail canary intact.
    var out: [32]u8 = undefined;
    @memset(&out, 0xAA);
    const n = pluginCallOut("pathfinder", "ping", "{}", &out);
    try testing.expectEqual(@as(usize, 13), n);
    try testing.expectEqualStrings("{\"pong\":true}", out[0..13]);
    for (out[13..]) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    try testing.expectEqual(@as(?bool, true), recorder.respond_accepted);

    // respondFmt formats straight into the channel.
    var out2: [64]u8 = undefined;
    const n2 = pluginCallOut("pathfinder", "fmt", "{\"x\":1}", &out2);
    try testing.expectEqualStrings("{\"echo\":{\"x\":1}}", out2[0..n2]);
}

test "plugin_call responses: over-cap out is untouched; fetch retries without re-executing" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // The 13-byte response doesn't fit a 4-byte buffer: required size
    // still returned, buffer untouched (all-or-nothing).
    var small: [4]u8 = undefined;
    @memset(&small, 0xAA);
    try testing.expectEqual(@as(usize, 13), pluginCallOut("pathfinder", "ping", "{}", &small));
    for (small) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    try testing.expectEqual(@as(usize, 1), recorder.count);

    // ── The double-execution negative-verify (#758) ──
    // Every read of the stored response leaves the handler UN-re-run:
    // the probe, the right-sized fetch, and a repeat fetch all leave
    // `count` at the single dispatch above.
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_response_fetch(null, 0));
    try testing.expectEqual(@as(usize, 1), recorder.count);

    var right: [13]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_response_fetch(&right, right.len));
    try testing.expectEqualStrings("{\"pong\":true}", &right);
    try testing.expectEqual(@as(usize, 1), recorder.count);

    // Non-consuming: a second fetch reads the same response.
    var again: [32]u8 = undefined;
    const n = contract.labelle_plugin_response_fetch(&again, again.len);
    try testing.expectEqualStrings("{\"pong\":true}", again[0..n]);
    try testing.expectEqual(@as(usize, 1), recorder.count);

    // Fetch's own all-or-nothing: an under-sized fetch sizes but writes
    // nothing.
    var tiny: [2]u8 = undefined;
    @memset(&tiny, 0xAA);
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_response_fetch(&tiny, tiny.len));
    for (tiny) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    try testing.expectEqual(@as(usize, 1), recorder.count);
}

test "plugin_call responses: fetch reads the most recently COMPLETED call — cleared by response-less and failed calls" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // Responded call stores at completion (the NULL/0 v1.1 shape folds
    // its rc to 0 — the fetch is where the response shows up)…
    try testing.expectEqual(@as(usize, 0), pluginCall("pathfinder", "ping", "{}"));
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_response_fetch(null, 0));

    // …a fire-and-forward call clears (0 = dispatched-no-response, and
    // the previous response must not linger for a stale fetch).
    try testing.expectEqual(@as(usize, 0), pluginCall("pathfinder", "silent", "{}"));
    try testing.expectEqual(@as(usize, 0), contract.labelle_plugin_response_fetch(null, 0));

    // …and so does a failed (unroutable) call: store again, then an
    // empty command name.
    try testing.expectEqual(@as(usize, 0), pluginCall("pathfinder", "ping", "{}"));
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_response_fetch(null, 0));
    try testing.expectEqual(contract.plugin_call_unroutable, pluginCall("pathfinder", "", "{}"));
    try testing.expectEqual(@as(usize, 0), contract.labelle_plugin_response_fetch(null, 0));
}

// ── Nested plugin calls (PR #760 review finding) ────────────────────
//
// A handler may itself issue a labelle_plugin_call mid-dispatch. Two
// in-flight dispatches must not share response storage: with a shared
// dispatch buffer the inner response scribbles over the outer one's
// bytes while the outer window still reports its original length —
// the outer caller reads a corrupted splice. The fix dispatches each
// call into per-call stack storage and publishes the fetch store only
// at completion (inner first, outer last), which this recorder pins
// end to end.

const NestedRecorder = struct {
    outer_count: usize = 0,
    inner_count: usize = 0,
    /// What the NESTED labelle_plugin_call returned to the handler…
    inner_rc: usize = 0,
    /// …and what it wrote into the handler's own out buffer.
    inner_buf: [64]u8 = undefined,

    pub fn engine__editor_plugin_command(self: *NestedRecorder, info: anytype) void {
        if (std.mem.eql(u8, info.command, "outer")) {
            self.outer_count += 1;
            // The corruption ordering: respond FIRST (the outer window
            // now holds bytes), THEN issue the nested call.
            _ = engine.plugin_command.respond("OUTER-RESPONSE");
            self.inner_rc = pluginCallOut("nested", "inner", "{}", &self.inner_buf);
        } else if (std.mem.eql(u8, info.command, "outer_silent")) {
            self.outer_count += 1;
            // No respond on the outer window — only the nested call.
            self.inner_rc = pluginCallOut("nested", "inner", "{}", &self.inner_buf);
        } else if (std.mem.eql(u8, info.command, "inner")) {
            self.inner_count += 1;
            _ = engine.plugin_command.respond("inner!!");
        }
    }
};

const NestedGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *NestedRecorder,
    core.StubLogSink,
    TestComponents,
    &.{},
    PluginCallEvents,
);

test "plugin_call responses: a nested call cannot corrupt the outer response; fetch reads the outermost outcome" {
    contract.unbind();
    defer contract.unbind();

    var recorder = NestedRecorder{};
    var game = NestedGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // Outer call: handler responds "OUTER-RESPONSE" (14 bytes), then
    // nests a call whose handler responds "inner!!" (7 bytes — shorter
    // ON PURPOSE, so a shared dispatch buffer would splice the two).
    var out: [64]u8 = undefined;
    const n = pluginCallOut("nested", "outer", "{}", &out);
    try testing.expectEqual(@as(usize, 1), recorder.outer_count);
    try testing.expectEqual(@as(usize, 1), recorder.inner_count);

    // (a) The outer caller's bytes are the OUTER response, uncorrupted.
    try testing.expectEqual(@as(usize, 14), n);
    try testing.expectEqualStrings("OUTER-RESPONSE", out[0..14]);

    // (c) The handler (the inner caller) received the INNER response in
    // ITS out buffer — the two responses never shared storage.
    try testing.expectEqual(@as(usize, 7), recorder.inner_rc);
    try testing.expectEqualStrings("inner!!", recorder.inner_buf[0..7]);

    // (b) Fetch after the stack unwound: the most recently COMPLETED
    // call is the OUTER one (it completes last), so its response is
    // what's stored — not the inner one.
    var fetched: [64]u8 = undefined;
    const fn_ = contract.labelle_plugin_response_fetch(&fetched, fetched.len);
    try testing.expectEqualStrings("OUTER-RESPONSE", fetched[0..fn_]);

    // (d) Response-less outer around a RESPONDING inner: the outer call
    // completes last and clears — a later fetch must not resurrect the
    // stale inner bytes (the inner response was already delivered to
    // the handler's own out buffer above).
    recorder.inner_rc = 0;
    try testing.expectEqual(@as(usize, 0), pluginCallOut("nested", "outer_silent", "{}", &out));
    try testing.expectEqual(@as(usize, 2), recorder.outer_count);
    try testing.expectEqual(@as(usize, 2), recorder.inner_count);
    try testing.expectEqual(@as(usize, 7), recorder.inner_rc); // inner still served
    try testing.expectEqualStrings("inner!!", recorder.inner_buf[0..7]);
    try testing.expectEqual(@as(usize, 0), contract.labelle_plugin_response_fetch(null, 0));
}

test "plugin_call responses: empty respond claims the channel but reads as no-response" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // respond("") is ACCEPTED (it claims first-writer-wins)…
    var out: [8]u8 = undefined;
    @memset(&out, 0xAA);
    try testing.expectEqual(@as(usize, 0), pluginCallOut("pathfinder", "empty", "{}", &out));
    try testing.expectEqual(@as(?bool, true), recorder.respond_accepted);
    // …but the sized returns fold it to dispatched-no-response: 0,
    // nothing written, nothing stored.
    for (out) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    try testing.expectEqual(@as(usize, 0), contract.labelle_plugin_response_fetch(null, 0));
}

test "plugin_call responses: payloads truncate at the channel cap" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // The handler writes cap+100 bytes; the channel truncates at the
    // cap — required size reports the STORED (truncated) length, so a
    // right-sized fetch reads exactly what exists. Driven with a real
    // (under-sized) out buffer so the return carries the size: the
    // NULL/0 shape would fold it to the v1.1 rc 0.
    const cap = engine.plugin_command.max_response_len;
    var small: [8]u8 = undefined;
    try testing.expectEqual(cap, pluginCallOut("pathfinder", "huge", "{}", &small));
    try testing.expectEqual(@as(?bool, true), recorder.respond_accepted);
    try testing.expectEqual(cap, contract.labelle_plugin_response_fetch(null, 0));
}

test "plugin_call v1.1 compat: the NULL/0 shape folds a responding dispatch to rc 0 (response still fetchable)" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    // A binding built against v1.1 passes NULL/0 (the only shape that
    // header sanctioned) and checks rc == 0 for a dispatched call.
    // With a RESPONDING handler the fold keeps that contract: rc 0,
    // never the response size.
    try testing.expectEqual(@as(usize, 0), pluginCall("pathfinder", "ping", "{}"));
    try testing.expectEqual(@as(usize, 1), recorder.count);
    try testing.expectEqual(@as(?bool, true), recorder.respond_accepted);

    // The fold discards nothing: the response was published, so a v1.2
    // caller without a buffer sizes via the fetch probe and reads it —
    // no re-execution (count pinned).
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_response_fetch(null, 0));
    var buf: [32]u8 = undefined;
    const n = contract.labelle_plugin_response_fetch(&buf, buf.len);
    try testing.expectEqualStrings("{\"pong\":true}", buf[0..n]);
    try testing.expectEqual(@as(usize, 1), recorder.count);

    // Unroutable in the same NULL/0 shape keeps the v1.1 sentinel.
    try testing.expectEqual(contract.plugin_call_unroutable, pluginCall("", "ping", "{}"));

    // The fold's boundary is EXACTLY the promised shape. A real pointer
    // with cap 0 is the v1.2 sizing leg: size returned, nothing written…
    const plugin = "pathfinder";
    const command = "ping";
    const params = "{}";
    var canary: [4]u8 = undefined;
    @memset(&canary, 0xAA);
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_call(
        plugin.ptr,
        plugin.len,
        command.ptr,
        command.len,
        params.ptr,
        params.len,
        &canary,
        0,
    ));
    for (canary) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    // …and NULL with a nonzero cap (illegal per the conventions block,
    // tolerated like component_get's NULL) sizes too — no fold.
    try testing.expectEqual(@as(usize, 13), contract.labelle_plugin_call(
        plugin.ptr,
        plugin.len,
        command.ptr,
        command.len,
        params.ptr,
        params.len,
        null,
        16,
    ));
}

test "plugin_call responses: second respond within one handler is refused (first-writer-wins)" {
    contract.unbind();
    defer contract.unbind();
    // The refusal deliberately warns; keep the intentional trigger out
    // of the test runner's stderr (asserted via the return value below).
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    contract.bind(&game);

    var out: [16]u8 = undefined;
    const n = pluginCallOut("pathfinder", "double", "{}", &out);
    try testing.expectEqualStrings("first", out[0..n]);
    // The recorder stored the SECOND respond's return: refused.
    try testing.expectEqual(@as(?bool, false), recorder.respond_accepted);
}

// Two-receiver broadcast: both handlers run (the v1.7 fan-out is
// preserved), the FIRST responder's payload returns, the second's
// respond is refused. Receivers are merged through core.MergeHooks —
// the assembler-generated multi-plugin shape.
const RespondAlpha = struct {
    count: usize = 0,
    accepted: ?bool = null,
    pub fn engine__editor_plugin_command(self: *RespondAlpha, _: anytype) void {
        self.count += 1;
        self.accepted = engine.plugin_command.respond("alpha");
    }
};
const RespondBeta = struct {
    count: usize = 0,
    accepted: ?bool = null,
    pub fn engine__editor_plugin_command(self: *RespondBeta, _: anytype) void {
        self.count += 1;
        self.accepted = engine.plugin_command.respond("beta");
    }
};

// The game's own merged payload shape, precomputed exactly as
// `GameConfig` derives it (MergeHookPayloads over the engine payload +
// the events union) so the MergeHooks instance type-checks against
// `Game.PayloadExport` — the generated-main wiring order.
const TwoRespPayload = core.MergeHookPayloads(.{ engine.HookPayload(u32), PluginCallEvents });
const TwoRespHooks = core.MergeHooks(TwoRespPayload, .{ *RespondAlpha, *RespondBeta });

const TwoResponderGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *TwoRespHooks,
    core.StubLogSink,
    TestComponents,
    &.{},
    PluginCallEvents,
);

test "plugin_call responses: broadcast preserved — first responder wins, second refused" {
    contract.unbind();
    defer contract.unbind();
    // Beta's refusal warns by design; silence the intentional trigger.
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    var alpha = RespondAlpha{};
    var beta = RespondBeta{};
    var merged = TwoRespHooks{ .receivers = .{ &alpha, &beta } };
    var game = TwoResponderGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&merged);
    contract.bind(&game);

    var out: [16]u8 = undefined;
    const n = pluginCallOut("anyplugin", "anycmd", "{}", &out);
    try testing.expectEqualStrings("alpha", out[0..n]);
    // BOTH handlers ran — a response does not consume the broadcast…
    try testing.expectEqual(@as(usize, 1), alpha.count);
    try testing.expectEqual(@as(usize, 1), beta.count);
    // …but only the first respond was accepted (the second warns).
    try testing.expectEqual(@as(?bool, true), alpha.accepted);
    try testing.expectEqual(@as(?bool, false), beta.accepted);
}

test "plugin_command.respond outside a dispatch window is refused" {
    // No game, no dispatch — the module seam refuses (and warns)
    // instead of scribbling anywhere. Silence the intentional warns.
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    try testing.expect(!engine.plugin_command.respond("stray"));
    try testing.expect(!engine.plugin_command.respondFmt("stray {d}", .{7}));
}

test "editorPluginCommandOut: responded bytes alias the caller's buffer; truncated flag on overflow" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    // Mixin-level (no C surface): the Result's bytes are a slice OF the
    // caller's out buffer, truncated at its length when the response
    // overflows it.
    var small: [8]u8 = undefined;
    switch (game.editorPluginCommandOut("pathfinder", "ping", "{}", &small)) {
        .responded => |r| {
            try testing.expectEqual(@as([*]u8, &small), r.bytes.ptr);
            try testing.expectEqualStrings("{\"pong\":", r.bytes);
            try testing.expect(r.truncated);
        },
        else => return error.TestUnexpectedResult,
    }

    var fits: [64]u8 = undefined;
    switch (game.editorPluginCommandOut("pathfinder", "ping", "{}", &fits)) {
        .responded => |r| {
            try testing.expectEqualStrings("{\"pong\":true}", r.bytes);
            try testing.expect(!r.truncated);
        },
        else => return error.TestUnexpectedResult,
    }

    // respondFmt's overflow leg: formatting that outgrows the window is
    // cut at the window's length and flagged, keeping the written
    // prefix (the fixed-writer catch path).
    var fmt_small: [10]u8 = undefined;
    switch (game.editorPluginCommandOut("pathfinder", "fmt", "{\"long\":\"xxxxxxxxxxxxxxxx\"}", &fmt_small)) {
        .responded => |r| {
            try testing.expectEqualStrings("{\"echo\":{\"", r.bytes);
            try testing.expect(r.truncated);
        },
        else => return error.TestUnexpectedResult,
    }

    // Fire-and-forward and unroutable legs of the mixin Result.
    var buf: [8]u8 = undefined;
    switch (game.editorPluginCommandOut("pathfinder", "silent", "{}", &buf)) {
        .dispatched => {},
        else => return error.TestUnexpectedResult,
    }
    switch (game.editorPluginCommandOut("", "ping", "{}", &buf)) {
        .unroutable => {},
        else => return error.TestUnexpectedResult,
    }
}

test "editorPluginCommand (v1.7 rc): the dispatch window exists — a response is accepted and discarded" {
    contract.unbind();
    defer contract.unbind();

    var recorder = RespondingRecorder{};
    var game = RespondGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    // The legacy rc path dispatches with a zero-length window: the
    // handler's respond is ACCEPTED (no spurious outside-window warn on
    // v1.7 callers), the payload is discarded, and the rc stays 0.
    try testing.expectEqual(@as(i32, 0), game.editorPluginCommand("pathfinder", "ping", "{}"));
    try testing.expectEqual(@as(usize, 1), recorder.count);
    try testing.expectEqual(@as(?bool, true), recorder.respond_accepted);
}

// ── Bulk component access (v1.3, labelle-scripting#41) ──────────────
//
// The packed per-component codec (binary twin of get/set, 0xFF
// sentinel → JSON fallback) and the batched whole-query f32 stream
// (int-field refusal + the positional-coupling guard).

fn getPacked(id: u64, name: []const u8, buf: []u8) usize {
    return contract.labelle_component_get_packed(id, name.ptr, name.len, buf.ptr, buf.len);
}

fn setPacked(id: u64, name: []const u8, buf: []const u8) i32 {
    return contract.labelle_component_set_packed(id, name.ptr, name.len, buf.ptr, buf.len);
}

fn batchGet(names_json: []const u8, buf: []u8) usize {
    return contract.labelle_component_batch_get(names_json.ptr, names_json.len, buf.ptr, buf.len);
}

fn batchSet(names_json: []const u8, buf: []const u8) i32 {
    return contract.labelle_component_batch_set(names_json.ptr, names_json.len, buf.ptr, buf.len);
}

/// Hand-builds packed records field by field — both the EXPECTED bytes
/// for a get (declaration order, host-chosen tags) and the record a
/// binding would send to a set (tags chosen by the script value's
/// runtime type).
const PackedRecord = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn init(field_count: u8) PackedRecord {
        var r = PackedRecord{};
        r.buf[0] = field_count;
        r.len = 1;
        return r;
    }

    fn name(self: *PackedRecord, n: []const u8) void {
        self.buf[self.len] = @intCast(n.len);
        self.len += 1;
        @memcpy(self.buf[self.len..][0..n.len], n);
        self.len += n.len;
    }

    fn f32Field(self: *PackedRecord, n: []const u8, v: f32) void {
        self.name(n);
        self.buf[self.len] = 0;
        std.mem.writeInt(u32, self.buf[self.len + 1 ..][0..4], @bitCast(v), .little);
        self.len += 5;
    }

    fn i64Field(self: *PackedRecord, n: []const u8, v: i64) void {
        self.name(n);
        self.buf[self.len] = 1;
        std.mem.writeInt(i64, self.buf[self.len + 1 ..][0..8], v, .little);
        self.len += 9;
    }

    fn boolField(self: *PackedRecord, n: []const u8, v: bool) void {
        self.name(n);
        self.buf[self.len] = 2;
        self.buf[self.len + 1] = @intFromBool(v);
        self.len += 2;
    }

    fn u64Field(self: *PackedRecord, n: []const u8, v: u64) void {
        self.name(n);
        self.buf[self.len] = 3;
        std.mem.writeInt(u64, self.buf[self.len + 1 ..][0..8], v, .little);
        self.len += 9;
    }

    /// The SET-side f64 tag (4, since v1.3): a binding writes it for a
    /// float that would lose precision through f32's mantissa.
    fn f64Field(self: *PackedRecord, n: []const u8, v: f64) void {
        self.name(n);
        self.buf[self.len] = 4;
        std.mem.writeInt(u64, self.buf[self.len + 1 ..][0..8], @bitCast(v), .little);
        self.len += 9;
    }

    fn bytes(self: *const PackedRecord) []const u8 {
        return self.buf[0..self.len];
    }
};

test "packed get/set: binary record round-trip over f32/i64/bool/u64 fields" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(
        id,
        "Stats",
        "{\"power\":1.5,\"score\":-42,\"alive\":true,\"seed\":9000000000000000000}",
    ));

    // GET — the host writes declaration order with the field's own tag
    // (f32→0, i64→1, bool→2, u64→3).
    var expected = PackedRecord.init(4);
    expected.f32Field("power", 1.5);
    expected.i64Field("score", -42);
    expected.boolField("alive", true);
    expected.u64Field("seed", 9_000_000_000_000_000_000);

    // NULL/cap-0 sizing probe, then all-or-nothing: an under-sized cap
    // writes nothing and still returns the required size.
    const nm = "Stats";
    const required = contract.labelle_component_get_packed(id, nm, nm.len, null, 0);
    try testing.expectEqual(expected.len, required);
    var buf: [128]u8 = @splat(0xAA);
    try testing.expectEqual(required, getPacked(id, "Stats", buf[0 .. required - 1]));
    try testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try testing.expectEqual(required, getPacked(id, "Stats", &buf));
    try testing.expectEqualSlices(u8, expected.bytes(), buf[0..required]);

    // SET — tags as a binding chooses them from the SCRIPT value's
    // runtime type: an Integer travels as i64 even into a u64 field
    // (the host coerces into the field's real type).
    var record = PackedRecord.init(4);
    record.f32Field("power", 2.5);
    record.i64Field("score", 7);
    record.boolField("alive", false);
    record.i64Field("seed", 123);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Stats", record.bytes()));
    const stats = game.getComponent(ent, Stats).?;
    try testing.expectEqual(@as(f32, 2.5), stats.power);
    try testing.expectEqual(@as(i64, 7), stats.score);
    try testing.expectEqual(false, stats.alive);
    try testing.expectEqual(@as(u64, 123), stats.seed);

    // REPLACE semantics: a partial record resets absent fields to the
    // struct defaults, exactly like the JSON set.
    var partial = PackedRecord.init(1);
    partial.i64Field("score", 9);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Stats", partial.bytes()));
    const reset = game.getComponent(ent, Stats).?;
    try testing.expectEqual(@as(i64, 9), reset.score);
    try testing.expectEqual(@as(f32, 0), reset.power);
    try testing.expectEqual(@as(u64, 0), reset.seed);

    // Int-carrying components are PACKABLE here (unlike the batch
    // stream): Health's i32 rides the i64 tag losslessly.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":250,\"regen\":0.5}"));
    const hn = contract.labelle_component_get_packed(id, "Health", 6, null, 0);
    try testing.expect(hn > 1); // a real record, not the sentinel
}

test "packed get: a non-scalar component writes the 0xFF sentinel (JSON-fallback signal)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id, "Label", "{\"text\":\"hi\"}"));

    var buf: [64]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 1), getPacked(id, "Label", &buf));
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);

    // Absent / unknown / dead keep component_get's 0 sentinel.
    try testing.expectEqual(@as(usize, 0), getPacked(id, "Velocity", &buf));
    try testing.expectEqual(@as(usize, 0), getPacked(id, "NoSuch", &buf));
    contract.labelle_entity_destroy(id);
    try testing.expectEqual(@as(usize, 0), getPacked(id, "Label", &buf));
}

test "packed set: non-scalar targets, built-ins and malformed records refuse with -1" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();

    // Non-scalar target (Label carries a string) → JSON fallback.
    var record = PackedRecord.init(0);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Label", record.bytes()));

    // Scene built-ins apply through the scene-loader JSON machinery
    // only — the packed path refuses them.
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Sprite", record.bytes()));

    // A buffer led by the 0xFF sentinel is never applicable.
    const sentinel = [_]u8{0xFF};
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Stats", &sentinel));

    // Truncated record (claims one field, carries none).
    const truncated = [_]u8{1};
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Stats", &truncated));

    // Unknown component / dead entity.
    try testing.expectEqual(@as(i32, -1), setPacked(id, "NoSuch", record.bytes()));
    contract.labelle_entity_destroy(id);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Stats", record.bytes()));
}

/// Read the f32 at byte offset `off` of a batch buffer (unaligned-safe).
fn batchFloat(buf: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
}

/// Overwrite the f32 at byte offset `off` of a batch buffer.
fn batchFloatSet(buf: []u8, off: usize, v: f32) void {
    std.mem.writeInt(u32, buf[off..][0..4], @bitCast(v), .little);
}

test "batch get/set: whole-query f32 stream round-trip" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const names = "[\"Position\",\"Velocity\"]";

    // Zero matching entities: the count-0 header alone — 4 bytes,
    // distinct from the 0 malformed/not-bound sentinel.
    var buf: [256]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 4), batchGet(names, &buf));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[0..4], .little));
    // ...and an empty stream applies cleanly (0 entities × anything = 0 bytes).
    try testing.expectEqual(@as(i32, 0), batchSet(names, buf[4..4]));

    // Three full entities + one Position-only (filtered out of the set).
    const ids = [3]u64{
        contract.labelle_entity_create(),
        contract.labelle_entity_create(),
        contract.labelle_entity_create(),
    };
    for (ids, 0..) |id, i| {
        var jbuf: [128]u8 = undefined;
        const fi: f32 = @floatFromInt(i);
        const pj = try std.fmt.bufPrint(&jbuf, "{{\"x\":{d},\"y\":{d}}}", .{ fi + 1, fi + 2 });
        try testing.expectEqual(@as(i32, 0), setComp(id, "Position", pj));
        var jbuf2: [128]u8 = undefined;
        const vj = try std.fmt.bufPrint(&jbuf2, "{{\"dx\":{d},\"dy\":{d}}}", .{ (fi + 1) * 10, (fi + 1) * -10 });
        try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", vj));
    }
    const lone = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(lone, "Position", "{\"x\":7,\"y\":8}"));

    // Sizing probe: [u32 count][3 entities × 4 fields × 4B].
    const required = contract.labelle_component_batch_get(names, names.len, null, 0);
    try testing.expectEqual(@as(usize, 4 + 3 * 4 * 4), required);
    // Under-sized cap: same required-size return (snprintf-style retry).
    try testing.expectEqual(required, batchGet(names, buf[0 .. required - 3]));

    try testing.expectEqual(required, batchGet(names, &buf));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[0..4], .little));

    // The hot loop, host-free: +1.0 to every float in the stream.
    var off: usize = 4;
    while (off < required) : (off += 4) {
        batchFloatSet(&buf, off, batchFloat(&buf, off) + 1.0);
    }
    try testing.expectEqual(@as(i32, 0), batchSet(names, buf[4..required]));

    // Every matched entity moved by exactly +1 on all four fields
    // (order-independent — the mock backend's view order is unspecified,
    // but get and set walked it identically).
    for (ids, 0..) |id, i| {
        const ent: u32 = @intCast(id);
        const fi: f32 = @floatFromInt(i);
        const pos = game.getComponent(ent, core.Position).?;
        try testing.expectEqual(fi + 2, pos.x);
        try testing.expectEqual(fi + 3, pos.y);
        const vel = game.getComponent(ent, Velocity).?;
        try testing.expectEqual((fi + 1) * 10 + 1, vel.dx);
        try testing.expectEqual((fi + 1) * -10 + 1, vel.dy);
    }
    // The filtered-out entity is untouched.
    const lp = game.getComponent(@as(u32, @intCast(lone)), core.Position).?;
    try testing.expectEqual(@as(f32, 7), lp.x);
    try testing.expectEqual(@as(f32, 8), lp.y);
}

test "batch: an int-carrying component is refused (get sentinel, set -2)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":50,\"regen\":1}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", "{\"dx\":1,\"dy\":2}"));

    // Health.hp is i32 → i64/u64-class corruption through f32; the
    // whole batch is refused, alone or anywhere in the name list.
    var buf: [128]u8 = @splat(0);
    const health = "[\"Health\"]";
    try testing.expectEqual(contract.batch_int_refused, batchGet(health, &buf));
    const mixed = "[\"Velocity\",\"Health\"]";
    try testing.expectEqual(contract.batch_int_refused, batchGet(mixed, &buf));
    try testing.expectEqual(@as(i32, -2), batchSet(health, buf[0..8]));
    try testing.expectEqual(@as(i32, -2), batchSet(mixed, buf[0..16]));

    // The refusal is the component's, not the entity's: the float-only
    // Velocity still batches.
    const vel = "[\"Velocity\"]";
    try testing.expectEqual(@as(usize, 4 + 2 * 4), batchGet(vel, &buf));
}

test "batch set: entity-count mismatch refuses -1 (positional-coupling guard)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const names = "[\"Position\",\"Velocity\"]";
    const a = contract.labelle_entity_create();
    const b = contract.labelle_entity_create();
    for ([_]u64{ a, b }) |id| {
        try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":1,\"y\":1}"));
        try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", "{\"dx\":1,\"dy\":1}"));
    }

    var buf: [256]u8 = @splat(0);
    const required = batchGet(names, &buf);
    try testing.expectEqual(@as(usize, 4 + 2 * 4 * 4), required);
    const stream = buf[4..required];

    // Same set → the stream applies.
    try testing.expectEqual(@as(i32, 0), batchSet(names, stream));

    // An entity DESTROYED since the get: the re-queried set needs fewer
    // bytes than the stream carries → the PREFLIGHT refuses with NO
    // writes — poison every float first and verify the survivor is
    // untouched (a refused batch_set must never commit a prefix, or the
    // documented "re-get and recompute" retry would double-apply).
    contract.labelle_entity_destroy(b);
    var off: usize = 0;
    while (off < stream.len) : (off += 4) batchFloatSet(stream, off, 99);
    try testing.expectEqual(@as(i32, -1), batchSet(names, stream));
    const surv = game.getComponent(@as(u32, @intCast(a)), core.Position).?;
    try testing.expectEqual(@as(f32, 1), surv.x);
    try testing.expectEqual(@as(f32, 1), surv.y);
    const surv_vel = game.getComponent(@as(u32, @intCast(a)), Velocity).?;
    try testing.expectEqual(@as(f32, 1), surv_vel.dx);
    try testing.expectEqual(@as(f32, 1), surv_vel.dy);

    // Entities SPAWNED since the get: the re-queried set needs MORE
    // bytes → same preflight refusal, still nothing written.
    for (0..2) |_| {
        const id = contract.labelle_entity_create();
        try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":2,\"y\":2}"));
        try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", "{\"dx\":2,\"dy\":2}"));
    }
    try testing.expectEqual(@as(i32, -1), batchSet(names, stream));
    const still = game.getComponent(@as(u32, @intCast(a)), core.Position).?;
    try testing.expectEqual(@as(f32, 1), still.x);
}

test "bulk access pre-bind: safe no-ops in each op's failure convention" {
    contract.unbind();
    defer contract.unbind();

    var buf: [32]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 0), getPacked(1, "Stats", &buf));
    try testing.expectEqual(@as(i32, -1), setPacked(1, "Stats", buf[0..1]));
    try testing.expectEqual(@as(usize, 0), batchGet("[\"Position\"]", &buf));
    try testing.expectEqual(@as(i32, -1), batchSet("[\"Position\"]", buf[0..0]));
    // The v1.4 id-tagged twins follow the same conventions.
    try testing.expectEqual(@as(usize, 0), batchGetIds("[\"Position\"]", &buf));
    try testing.expectEqual(@as(i32, -1), batchSetIds("[\"Position\"]", buf[0..0]));
}

test "packed set: out-of-range / non-finite script values refuse -1, never panic" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Tiny", "{\"b\":7,\"w\":-7}"));

    // i64 tag that overflows the u8 target — refuse, entity untouched
    // (the refusal happens before setComponent; JSON fallback owns it).
    var over = PackedRecord.init(1);
    over.i64Field("b", 300);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Tiny", over.bytes()));
    // Negative into a NARROW unsigned — refuse (the 64-bit bitcast pair
    // below is exactly 64-bit-to-64-bit, never a narrowing escape hatch).
    var neg = PackedRecord.init(1);
    neg.i64Field("b", -1);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Tiny", neg.bytes()));
    // u64 tag past the range of a NARROW signed target — refuse.
    var big = PackedRecord.init(1);
    big.u64Field("w", std.math.maxInt(u64));
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Tiny", big.bytes()));
    // f32 tag into an int field: NaN / Inf / out-of-range all refuse…
    inline for ([_]f32{
        std.math.nan(f32),
        std.math.inf(f32),
        -std.math.inf(f32),
        1e30,
        -1e30,
    }) |bad| {
        var rec = PackedRecord.init(1);
        rec.f32Field("w", bad);
        try testing.expectEqual(@as(i32, -1), setPacked(id, "Tiny", rec.bytes()));
    }
    const untouched = game.getComponent(ent, Tiny).?;
    try testing.expectEqual(@as(u8, 7), untouched.b);
    try testing.expectEqual(@as(i32, -7), untouched.w);

    // …while an in-range f32 truncates into the int field (the packed
    // coercion's documented float→int semantics).
    var ok = PackedRecord.init(2);
    ok.i64Field("b", 200);
    ok.f32Field("w", 42.9);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Tiny", ok.bytes()));
    const applied = game.getComponent(ent, Tiny).?;
    try testing.expectEqual(@as(u8, 200), applied.b);
    try testing.expectEqual(@as(i32, 42), applied.w);
}

test "packed set: the SET-side f64 tag (v1.3) reaches int fields past f32 precision, exactly" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Tiny", "{\"b\":0,\"w\":0}"));

    // 16_777_217 (2^24 + 1) is the first integer f32 cannot hold: the
    // f32 tag rounds it to 16_777_216 BEFORE the host sees it. The f64
    // tag carries it whole, and coercePacked lands it in the i32 field
    // EXACTLY — the precision fix's whole point (#45).
    var exact = PackedRecord.init(2);
    exact.i64Field("b", 1);
    exact.f64Field("w", 16_777_217.0);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Tiny", exact.bytes()));
    const applied = game.getComponent(ent, Tiny).?;
    try testing.expectEqual(@as(i32, 16_777_217), applied.w);

    // The old f32 tag would have rounded to 16_777_216 — prove the wire
    // difference is real (this is what the binding avoids by sending 4).
    var lossy = PackedRecord.init(1);
    lossy.f32Field("w", 16_777_217.0);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Tiny", lossy.bytes()));
    try testing.expectEqual(@as(i32, 16_777_216), game.getComponent(ent, Tiny).?.w);

    // f64 tag keeps the SAME refusal discipline as f32: NaN / Inf /
    // out-of-range refuse (-1, entity untouched), never clamp or panic.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Tiny", "{\"b\":5,\"w\":5}"));
    inline for ([_]f64{
        std.math.nan(f64),
        std.math.inf(f64),
        1e100, // finite but far past i32 range
        -1e100,
    }) |bad| {
        var rec = PackedRecord.init(1);
        rec.f64Field("w", bad);
        try testing.expectEqual(@as(i32, -1), setPacked(id, "Tiny", rec.bytes()));
    }
    const untouched = game.getComponent(ent, Tiny).?;
    try testing.expectEqual(@as(i32, 5), untouched.w);

    // A finite f64 into an f32 FIELD narrows the field's width (defined,
    // like the JSON parse-then-narrow route). Velocity.dx is f32.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", "{\"dx\":0,\"dy\":0}"));
    var flt = PackedRecord.init(1);
    flt.f64Field("dx", 0.1); // f32 cannot hold 0.1 exactly — nearest f32 lands
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Velocity", flt.bytes()));
    try testing.expectEqual(@as(f32, 0.1), game.getComponent(ent, Velocity).?.dx);
}

test "packed set: a bool field accepts ONLY the bool tag; every numeric tag refuses" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    // Flag = { on: bool, weight: f32 }. Seed a known state.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Flag", "{\"on\":true,\"weight\":9}"));

    // The bool tag (2) is the ONLY tag a bool field accepts — true and
    // false both round-trip.
    var t = PackedRecord.init(1);
    t.boolField("on", false);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Flag", t.bytes()));
    try testing.expect(!game.getComponent(ent, Flag).?.on);
    var t2 = PackedRecord.init(1);
    t2.boolField("on", true);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Flag", t2.bytes()));
    try testing.expect(game.getComponent(ent, Flag).?.on);

    // Every NUMERIC tag targeting the bool `on` field REFUSES (-1) —
    // type confusion (`alive = 1` / `= 16_777_217.0`) is surfaced, not
    // silently collapsed to true. Reset to a known `on:true` before each
    // so a wrongly-accepted coercion would be visible AND the field is
    // left untouched by the refusal.
    const NumberTag = union(enum) { i64: i64, u64: u64, f32: f32, f64: f64 };
    inline for ([_]NumberTag{
        .{ .i64 = 1 }, // a truthy int — the old silent 1→true path
        .{ .i64 = 0 }, // a falsy int — would have flipped it to false
        .{ .u64 = 1 },
        .{ .f32 = 1.0 },
        .{ .f64 = 16_777_217.0 }, // codex's type-confusion example
    }) |nt| {
        try testing.expectEqual(@as(i32, 0), setComp(id, "Flag", "{\"on\":true,\"weight\":9}"));
        var rec = PackedRecord.init(1);
        switch (nt) {
            .i64 => |v| rec.i64Field("on", v),
            .u64 => |v| rec.u64Field("on", v),
            .f32 => |v| rec.f32Field("on", v),
            .f64 => |v| rec.f64Field("on", v),
        }
        try testing.expectEqual(@as(i32, -1), setPacked(id, "Flag", rec.bytes()));
        // Refused → entity untouched (the JSON fallback owns the value).
        try testing.expect(game.getComponent(ent, Flag).?.on);
    }

    // The REVERSE stays allowed: a bool tag WIDENS into a number field
    // (true/false → 1/0) — the documented, lossless, unambiguous mirror.
    var w = PackedRecord.init(1);
    w.boolField("weight", true);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Flag", w.bytes()));
    try testing.expectEqual(@as(f32, 1), game.getComponent(ent, Flag).?.weight);
    var w0 = PackedRecord.init(1);
    w0.boolField("weight", false);
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Flag", w0.bytes()));
    try testing.expectEqual(@as(f32, 0), game.getComponent(ent, Flag).?.weight);
}

test "batch set: NaN in the stream is defined behavior (float lands, bool reads true), no panic" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", "{\"dx\":1,\"dy\":2}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Flag", "{\"on\":false,\"weight\":3}"));

    const names = "[\"Velocity\",\"Flag\"]";
    // Stream layout: dx, dy, on, weight — poison all four with NaN.
    var stream: [16]u8 = undefined;
    const nan: f32 = std.math.nan(f32);
    for (0..4) |i| {
        std.mem.writeInt(u32, stream[i * 4 ..][0..4], @bitCast(nan), .little);
    }
    try testing.expectEqual(@as(i32, 0), batchSet(names, &stream));
    const vel = game.getComponent(ent, Velocity).?;
    try testing.expect(std.math.isNan(vel.dx));
    try testing.expect(std.math.isNan(vel.dy));
    const flag = game.getComponent(ent, Flag).?;
    try testing.expect(flag.on); // NaN != 0 → true
    try testing.expect(std.math.isNan(flag.weight));

    // Sanity: the bool round-trips as 0/1 through the whole batch cycle.
    var buf: [64]u8 = @splat(0);
    const required = batchGet("[\"Flag\"]", &buf);
    try testing.expectEqual(@as(usize, 4 + 2 * 4), required);
    try testing.expectEqual(@as(f32, 1), batchFloat(&buf, 4)); // on == true → 1.0
}

test "packed get/set: over-the-wire-limit structs comptime-classify as not packable" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    game.setComponent(ent, Wide300{});
    game.setComponent(ent, LongName{});

    // 300 fields > the u8 field_count wire limit (0xFF is the sentinel):
    // the 0xFF/JSON path, decided at comptime — no runtime @intCast trap.
    var buf: [64]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 1), getPacked(id, "Wide300", &buf));
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);
    var rec = PackedRecord.init(0);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Wide300", rec.bytes()));

    // A 300-byte field name > the u8 name_len wire limit — same path.
    try testing.expectEqual(@as(usize, 1), getPacked(id, "LongName", &buf));
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "LongName", rec.bytes()));
}

test "batch set: read-modify-write — mixed components keep non-scalar fields, no defaults needed" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    // Mixed: a string beside batch-eligible scalars.
    try testing.expectEqual(
        @as(i32, 0),
        setComp(id, "Mixed", "{\"text\":\"keep\",\"x\":1,\"on\":false}"),
    );
    // Bare: all-scalar, NO field defaults — set through the typed path
    // (the JSON REPLACE path would demand every field anyway).
    game.setComponent(ent, Bare{ .x = 10, .y = 20 });

    const names = "[\"Mixed\",\"Bare\"]";
    var buf: [64]u8 = @splat(0);
    // Stream: Mixed.x, Mixed.on, Bare.x, Bare.y — 4 floats.
    const required = batchGet(names, &buf);
    try testing.expectEqual(@as(usize, 4 + 4 * 4), required);
    try testing.expectEqual(@as(f32, 1), batchFloat(&buf, 4));
    try testing.expectEqual(@as(f32, 0), batchFloat(&buf, 8)); // on=false
    try testing.expectEqual(@as(f32, 10), batchFloat(&buf, 12));
    try testing.expectEqual(@as(f32, 20), batchFloat(&buf, 16));

    // Mutate every scalar, flip the bool, write back.
    batchFloatSet(&buf, 4, 2);
    batchFloatSet(&buf, 8, 1); // on=true
    batchFloatSet(&buf, 12, 11);
    batchFloatSet(&buf, 16, 21);
    try testing.expectEqual(@as(i32, 0), batchSet(names, buf[4..required]));

    const mixed = game.getComponent(ent, Mixed).?;
    try testing.expectEqual(@as(f32, 2), mixed.x);
    try testing.expectEqual(true, mixed.on);
    // The RMW promise: the non-scalar field SURVIVED the batch write.
    try testing.expectEqualStrings("keep", mixed.text);
    const bare = game.getComponent(ent, Bare).?;
    try testing.expectEqual(@as(f32, 11), bare.x);
    try testing.expectEqual(@as(f32, 21), bare.y);
}

test "batch set: a built-in Camera zoom round-trips through the scene apply path" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    try testing.expectEqual(
        @as(i32, 0),
        setComp(id, "Camera", "{\"zoom\":2,\"tag\":\"main\"}"),
    );

    // Camera's only batch-eligible scalar is zoom (viewport is optional,
    // tag is a string) — stride 1.
    const names = "[\"Camera\"]";
    var buf: [16]u8 = @splat(0);
    const required = batchGet(names, &buf);
    try testing.expectEqual(@as(usize, 4 + 4), required);
    try testing.expectEqual(@as(f32, 2), batchFloat(&buf, 4));

    batchFloatSet(&buf, 4, 3.5);
    try testing.expectEqual(@as(i32, 0), batchSet(names, buf[4..required]));

    // Applied — and through the same scene apply machinery as the JSON
    // set, preserving the non-scalar tag.
    var jbuf: [256]u8 = undefined;
    const json = getComp(id, "Camera", &jbuf);
    try testing.expect(std.mem.indexOf(u8, json, "\"zoom\":3.5") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tag\":\"main\"") != null);
}

test "packed: an f64 field comptime-classifies as not packable (precision over speed)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    // A value an f32 cannot hold exactly.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Precise", "{\"d\":1.0000000116860974}"));

    var buf: [64]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 1), getPacked(id, "Precise", &buf));
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);
    var rec = PackedRecord.init(0);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Precise", rec.bytes()));
    // …and the JSON path the sentinel redirects to carries the f64
    // faithfully.
    var jbuf: [128]u8 = undefined;
    const json = getComp(id, "Precise", &jbuf);
    try testing.expect(std.mem.indexOf(u8, json, "1.0000000116860974") != null);
}

test "packed set: trailing bytes after the declared fields refuse -1" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id, "Tiny", "{\"b\":7,\"w\":-7}"));

    // A well-formed record with appended garbage — malformed as a whole.
    var rec = PackedRecord.init(1);
    rec.i64Field("b", 5);
    var padded: [64]u8 = undefined;
    @memcpy(padded[0..rec.len], rec.bytes());
    padded[rec.len] = 0xAB;
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Tiny", padded[0 .. rec.len + 1]));
    // A zero-field header ahead of data is the same refusal.
    const zero_then_junk = [_]u8{ 0, 1, 2, 3 };
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Tiny", &zero_then_junk));
    // The entity kept its values through both.
    const t = game.getComponent(@as(u32, @intCast(id)), Tiny).?;
    try testing.expectEqual(@as(u8, 7), t.b);
}

test "packed: the 64-bit bitcast pair round-trips a bit-63 u64 losslessly" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    const hi: u64 = 0x8000_0000_0000_0001; // bit 63 set
    var jset: [128]u8 = undefined;
    const set_json = try std.fmt.bufPrint(&jset, "{{\"seed\":{d}}}", .{hi});
    try testing.expectEqual(@as(i32, 0), setComp(id, "Stats", set_json));

    // GET emits the u64 as tag 3…
    var buf: [128]u8 = @splat(0);
    const n = getPacked(id, "Stats", &buf);
    try testing.expect(n > 1);
    // …a signed-only binding (mruby) bitcasts it into its Integer and
    // re-emits tag 1 on SET; the host bitcasts back — bit-exact.
    var rec = PackedRecord.init(1);
    rec.i64Field("seed", @bitCast(hi));
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Stats", rec.bytes()));
    try testing.expectEqual(hi, game.getComponent(ent, Stats).?.seed);

    // The reverse pair: a u64 tag lands in an i64 field the same way.
    var rec2 = PackedRecord.init(1);
    rec2.u64Field("score", @bitCast(@as(i64, -42)));
    try testing.expectEqual(@as(i32, 0), setPacked(id, "Stats", rec2.bytes()));
    try testing.expectEqual(@as(i64, -42), game.getComponent(ent, Stats).?.score);
}

// ── v1.3 polish (#782) + the id-tagged batch variant (v1.4, #783) ───

/// StubRender clone whose Shape is SCALAR-ONLY — the #782 GET/SET
/// symmetry case: `packInto` alone would emit a real record for it,
/// but the packed SET refuses ALL built-ins (they apply through the
/// scene loader's JSON machinery), so the packed GET must emit the
/// 0xFF sentinel for built-ins unconditionally or the two directions
/// disagree.
fn ScalarShapeRender(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
        };

        pub const Shape = struct { width: f32 = 10, height: f32 = 10, visible: bool = true };

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(_: *Self, _: Entity) void {}
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
    };
}

const ScalarBuiltinGame = engine.GameConfig(
    ScalarShapeRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    TestEvents,
);

test "packed built-ins: a scalar-only built-in still gets the 0xFF sentinel — GET/SET agree (#782)" {
    contract.unbind();
    defer contract.unbind();

    var game = ScalarBuiltinGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Shape", "{\"width\":3,\"height\":4}"));

    // GET: the sentinel, never a record — the built-in POLICY, not a
    // shape accident (this Shape would pack fine as a registry type).
    var buf: [64]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 1), getPacked(id, "Shape", &buf));
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);

    // …and the direction it must agree with: the packed SET refuses,
    // so a binding lands on JSON for BOTH directions.
    var rec = PackedRecord.init(1);
    rec.f32Field("width", 9);
    try testing.expectEqual(@as(i32, -1), setPacked(id, "Shape", rec.bytes()));
    const shape = game.getComponent(ent, ScalarBuiltinGame.ShapeComp).?;
    try testing.expectEqual(@as(f32, 3), shape.width);
    try testing.expectEqual(@as(f32, 4), shape.height);

    // Absent component keeps the 0 sentinel (never 0xFF for a
    // component the entity doesn't carry).
    const bare = contract.labelle_entity_create();
    try testing.expectEqual(@as(usize, 0), getPacked(bare, "Shape", &buf));
}

test "batch set: zero-width (filter) components are skipped — no onSet churn (#782)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":1,\"y\":2}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Marker", "{\"note\":\"keep\"}"));

    // Sanity: the counter wires up — a per-entity UPDATE set fires onSet.
    marker_on_set_calls = 0;
    try testing.expectEqual(@as(i32, 0), setComp(id, "Marker", "{\"note\":\"keep\"}"));
    try testing.expectEqual(@as(u32, 1), marker_on_set_calls);

    // Marker contributes 0 stream bytes: the stream is Position alone.
    const names = "[\"Position\",\"Marker\"]";
    var buf: [64]u8 = @splat(0);
    const required = batchGet(names, &buf);
    try testing.expectEqual(@as(usize, 4 + 2 * 4), required);

    batchFloatSet(&buf, 4, 10);
    batchFloatSet(&buf, 8, 20);
    marker_on_set_calls = 0;
    try testing.expectEqual(@as(i32, 0), batchSet(names, buf[4..required]));
    // The filter was NOT re-applied…
    try testing.expectEqual(@as(u32, 0), marker_on_set_calls);
    // …while the data-bearing component landed, and the filter's value
    // survives untouched.
    const pos = game.getComponent(ent, core.Position).?;
    try testing.expectEqual(@as(f32, 10), pos.x);
    try testing.expectEqual(@as(f32, 20), pos.y);
    try testing.expectEqualStrings("keep", game.getComponent(ent, Marker).?.note);

    // The id-tagged variant applies the identical skip.
    const required_ids = batchGetIds(names, &buf);
    try testing.expectEqual(@as(usize, 4 + (8 + 2 * 4)), required_ids);
    marker_on_set_calls = 0;
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required_ids]));
    try testing.expectEqual(@as(u32, 0), marker_on_set_calls);
}

fn batchGetIds(names_json: []const u8, buf: []u8) usize {
    return contract.labelle_component_batch_get_ids(names_json.ptr, names_json.len, buf.ptr, buf.len);
}

fn batchSetIds(names_json: []const u8, buf: []const u8) i32 {
    return contract.labelle_component_batch_set_ids(names_json.ptr, names_json.len, buf.ptr, buf.len);
}

/// Read a row's u64 entity id at byte offset `off` (unaligned-safe).
fn rowId(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

test "batch ids: id-tagged round-trip — rows carry ids, set matches BY ID, not position" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // The wire's row prefix is pinned (and doubles as the v1.4
    // comptime capability marker).
    try testing.expectEqual(@as(usize, 8), contract.batch_id_row_prefix);

    const names = "[\"Position\",\"Velocity\"]";
    var buf: [256]u8 = @splat(0);

    // Zero matches: the count-0 header alone, and an empty row buffer
    // applies cleanly.
    try testing.expectEqual(@as(usize, 4), batchGetIds(names, &buf));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..4]));

    const ids = [3]u64{
        contract.labelle_entity_create(),
        contract.labelle_entity_create(),
        contract.labelle_entity_create(),
    };
    for (ids) |id| {
        try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":1,\"y\":1}"));
        try testing.expectEqual(@as(i32, 0), setComp(id, "Velocity", "{\"dx\":1,\"dy\":1}"));
    }

    // Sizing: [u32 count][3 rows × (u64 id + 4 fields × 4B)].
    const row = 8 + 4 * 4;
    const required = contract.labelle_component_batch_get_ids(names, names.len, null, 0);
    try testing.expectEqual(@as(usize, 4 + 3 * row), required);
    // Under-sized cap: required-size return, snprintf-style.
    try testing.expectEqual(required, batchGetIds(names, buf[0 .. required - 3]));
    try testing.expectEqual(required, batchGetIds(names, &buf));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[0..4], .little));

    // Every row's id is one of ours; write each row's floats as a
    // FUNCTION OF ITS OWN ID — the only way these land right is
    // match-by-id.
    var off: usize = 4;
    while (off < required) : (off += row) {
        const id = rowId(&buf, off);
        var known = false;
        for (ids) |want| {
            if (want == id) known = true;
        }
        try testing.expect(known);
        const base: f32 = @floatFromInt(id * 100);
        for (0..4) |i| batchFloatSet(&buf, off + 8 + i * 4, base + @as(f32, @floatFromInt(i)));
    }
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required]));
    for (ids) |id| {
        const ent: u32 = @intCast(id);
        const base: f32 = @floatFromInt(id * 100);
        const pos = game.getComponent(ent, core.Position).?;
        try testing.expectEqual(base + 0, pos.x);
        try testing.expectEqual(base + 1, pos.y);
        const vel = game.getComponent(ent, Velocity).?;
        try testing.expectEqual(base + 2, vel.dx);
        try testing.expectEqual(base + 3, vel.dy);
    }
}

test "batch set ids: same-count destroy+spawn — vanished row skipped, spawned entity untouched (#783)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const names = "[\"Position\"]";
    const a = contract.labelle_entity_create();
    const b = contract.labelle_entity_create();
    for ([_]u64{ a, b }) |id| {
        try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":1,\"y\":1}"));
    }

    var buf: [128]u8 = @splat(0);
    const row = 8 + 2 * 4;
    const required = batchGetIds(names, &buf);
    try testing.expectEqual(@as(usize, 4 + 2 * row), required);

    // The positional guard's blind spot: destroy + spawn keeps the
    // COUNT identical while changing membership.
    contract.labelle_entity_destroy(b);
    const c = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(c, "Position", "{\"x\":50,\"y\":60}"));

    var off: usize = 4;
    while (off < required) : (off += row) {
        const id = rowId(&buf, off);
        const base: f32 = @floatFromInt(id * 10);
        batchFloatSet(&buf, off + 8, base + 1);
        batchFloatSet(&buf, off + 12, base + 2);
    }
    // BY ID: a's row lands on a, b's row is skipped (vanished), and the
    // newcomer c — absent from the buffer — is untouched. No refusal,
    // no cross-entity smear.
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required]));
    const ap = game.getComponent(@as(u32, @intCast(a)), core.Position).?;
    try testing.expectEqual(@as(f32, @floatFromInt(a * 10)) + 1, ap.x);
    try testing.expectEqual(@as(f32, @floatFromInt(a * 10)) + 2, ap.y);
    const cp = game.getComponent(@as(u32, @intCast(c)), core.Position).?;
    try testing.expectEqual(@as(f32, 50), cp.x);
    try testing.expectEqual(@as(f32, 60), cp.y);

    // A live entity that merely LEFT the query since the get is the
    // same skip: remove a's Position and re-apply the old rows.
    try testing.expectEqual(@as(i32, 0), removeComp(a, "Position"));
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required]));
    try testing.expect(game.getComponent(@as(u32, @intCast(a)), core.Position) == null);
}

test "batch set ids: an onSet hook destroying a queried entity mid-apply skips its row, never fails (#783)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const a = contract.labelle_entity_create();
    const b = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(a, "Reaper", "{\"hp\":1}"));
    try testing.expectEqual(@as(i32, 0), setComp(b, "Reaper", "{\"hp\":2}"));
    reaper_pair = .{ a, b };

    const names = "[\"Reaper\"]";
    var buf: [64]u8 = @splat(0);
    const row = 8 + 4;
    const required = batchGetIds(names, &buf);
    try testing.expectEqual(@as(usize, 4 + 2 * row), required);
    var off: usize = 4;
    while (off < required) : (off += row) {
        const id = rowId(&buf, off);
        batchFloatSet(&buf, off + 8, @as(f32, @floatFromInt(id)) + 0.5);
    }

    // Applying the FIRST row fires Reaper.onSet, which destroys the
    // pair's other entity — the id-tagged set downgrades that entity's
    // row to a skip (the positional preflight could never see this
    // future) and completes cleanly.
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required]));
    const a_alive = game.ecs_backend.entityExists(@as(u32, @intCast(a)));
    const b_alive = game.ecs_backend.entityExists(@as(u32, @intCast(b)));
    try testing.expect(a_alive != b_alive); // exactly one survivor
    const surv: u64 = if (a_alive) a else b;
    const hp = game.getComponent(@as(u32, @intCast(surv)), Reaper).?.hp;
    try testing.expectEqual(@as(f32, @floatFromInt(surv)) + 0.5, hp);
}

test "batch ids: refusals and shapes — misaligned rows, int fields, unknown names, unknown ids" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id, "Position", "{\"x\":1,\"y\":2}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Health", "{\"hp\":50,\"regen\":1}"));

    var buf: [128]u8 = @splat(0);

    // Int-carrying components: the identical refusal as the positional
    // pair — sentinel from get, -2 from set.
    try testing.expectEqual(contract.batch_int_refused, batchGetIds("[\"Health\"]", &buf));
    try testing.expectEqual(@as(i32, -2), batchSetIds("[\"Health\"]", buf[0..12]));

    // A buffer that is not a whole number of rows refuses -1 with no
    // writes (row size for ["Position"] is 8 + 8 = 16).
    try testing.expectEqual(@as(i32, -1), batchSetIds("[\"Position\"]", buf[0..15]));
    const p = game.getComponent(@as(u32, @intCast(id)), core.Position).?;
    try testing.expectEqual(@as(f32, 1), p.x);

    // Unknown names: get → the count-0 header (a valid empty result);
    // set → -1 (nothing to resolve the rows against).
    try testing.expectEqual(@as(usize, 4), batchGetIds("[\"NoSuch\"]", &buf));
    try testing.expectEqual(@as(i32, -1), batchSetIds("[\"NoSuch\"]", buf[0..8]));

    // Malformed names JSON: get 0, set -1 (the export conventions).
    try testing.expectEqual(@as(usize, 0), batchGetIds("not json", &buf));
    try testing.expectEqual(@as(i32, -1), batchSetIds("not json", buf[0..16]));

    // A row naming an id that never existed is a SKIP, not an error.
    var row: [16]u8 = @splat(0);
    std.mem.writeInt(u64, row[0..8], 999_999, .little);
    batchFloatSet(&row, 8, 42);
    batchFloatSet(&row, 12, 43);
    try testing.expectEqual(@as(i32, 0), batchSetIds("[\"Position\"]", &row));
    try testing.expectEqual(@as(f32, 1), p.x);
}

test "batch set ids: intra-row partial commit — a sibling-removing onSet hook doesn't half-write the row (#788)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    // Row layout: Trigger.v, Payload.p, Keep.k — three data-bearing
    // scalars. Trigger's onSet (armed below) removes Payload mid-row.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Trigger", "{\"v\":1}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Payload", "{\"p\":2}"));
    try testing.expectEqual(@as(i32, 0), setComp(id, "Keep", "{\"k\":3}"));

    const names = "[\"Trigger\",\"Payload\",\"Keep\"]";
    var buf: [64]u8 = @splat(0);
    const required = batchGetIds(names, &buf);
    try testing.expectEqual(@as(usize, 4 + (8 + 3 * 4)), required);

    // New values for all three: floats at row offset 8 (after the id).
    batchFloatSet(&buf, 4 + 8 + 0, 10); // Trigger.v
    batchFloatSet(&buf, 4 + 8 + 4, 20); // Payload.p (its entity slot vanishes mid-apply)
    batchFloatSet(&buf, 4 + 8 + 8, 30); // Keep.k

    trigger_arm = true;
    defer trigger_arm = false;
    // Applying Trigger fires onSet → removes Payload. The set must not
    // half-write: Payload's slot is skipped (removed by the hook), while
    // Trigger AND the later Keep both land. No -1, no partial component.
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required]));

    try testing.expectEqual(@as(f32, 10), game.getComponent(ent, Trigger).?.v);
    // Payload was removed by the hook and NOT re-added by the set.
    try testing.expect(game.getComponent(ent, Payload) == null);
    // The bystander sibling AFTER the removed one still applied — the fix
    // doesn't drop a row's remaining live components on a mid-row removal.
    try testing.expectEqual(@as(f32, 30), game.getComponent(ent, Keep).?.k);
}

test "batch set ids: an onSet hook destroying its own entity mid-row skips the rest cleanly, no use-after-destroy (#788)" {
    contract.unbind();
    defer contract.unbind();

    var game = ContractGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // Two entities carrying [SelfDestruct, Keep]. `a`'s SelfDestruct
    // onSet DESTROYS `a` mid-row; `b`'s does not (gated on the target).
    const a = contract.labelle_entity_create();
    const b = contract.labelle_entity_create();
    for ([_]u64{ a, b }) |id| {
        try testing.expectEqual(@as(i32, 0), setComp(id, "SelfDestruct", "{\"v\":1}"));
        try testing.expectEqual(@as(i32, 0), setComp(id, "Keep", "{\"k\":1}"));
    }

    const names = "[\"SelfDestruct\",\"Keep\"]";
    var buf: [128]u8 = @splat(0);
    const required = batchGetIds(names, &buf);
    const row = 8 + 2 * 4;
    try testing.expectEqual(@as(usize, 4 + 2 * row), required);

    // Set each row's floats as a function of its id so we can tell which
    // entity a landed write belongs to.
    var off: usize = 4;
    while (off < required) : (off += row) {
        const id = rowId(&buf, off);
        const base: f32 = @floatFromInt(id * 10);
        batchFloatSet(&buf, off + 8, base + 1); // SelfDestruct.v
        batchFloatSet(&buf, off + 12, base + 2); // Keep.k
    }

    self_destruct_target = a;
    defer self_destruct_target = 0;
    // Applying a's SelfDestruct fires onSet → destroys a. The later Keep
    // on a must be skipped via the liveness recheck (no use-after-destroy),
    // while b's row applies in full — rows stay independent, call is ok.
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required]));

    // a is gone; its would-be Keep write never touched a dead slot.
    try testing.expect(!game.ecs_backend.entityExists(@as(u32, @intCast(a))));
    try testing.expect(game.getComponent(@as(u32, @intCast(a)), Keep) == null);
    // b (never targeted) applied its whole row.
    const bbase: f32 = @floatFromInt(b * 10);
    try testing.expectEqual(bbase + 1, game.getComponent(@as(u32, @intCast(b)), SelfDestruct).?.v);
    try testing.expectEqual(bbase + 2, game.getComponent(@as(u32, @intCast(b)), Keep).?.k);
}

// ── Recycling ECS backend — a MockEcs twin whose freed slots are reused
// with a bumped generation (the packed index+gen handle models the
// production zig-ecs adapter: `Entity = u32`, `entityExists == valid()`).
// It exists only to reproduce #788's recycled-id case, which the
// monotonic MockEcs cannot. Everything but id allocation mirrors MockEcs.

fn RecyclingEcs(comptime EntityType: type) type {
    return struct {
        pub const Entity = EntityType;
        const CleanupFn = *const fn (*Self) void;
        const Self = @This();

        // Handle = (gen << 24) | index; index starts at 1 (0 is the
        // engine's null sentinel). Freed indices recycle with gen+1, so a
        // recycled slot ALWAYS yields a different full handle.
        next_index: u32 = 1,
        free: std.ArrayListUnmanaged(u32) = .empty,
        gen_of: std.AutoHashMap(u32, u8),
        alive: std.AutoHashMap(EntityType, void),
        storages: std.AutoHashMap(usize, *anyopaque),
        cleanups: std.ArrayListUnmanaged(CleanupFn) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .gen_of = std.AutoHashMap(u32, u8).init(allocator),
                .alive = std.AutoHashMap(EntityType, void).init(allocator),
                .storages = std.AutoHashMap(usize, *anyopaque).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.cleanups.items) |cleanup| cleanup(self);
            self.cleanups.deinit(self.allocator);
            self.storages.deinit();
            self.alive.deinit();
            self.gen_of.deinit();
            self.free.deinit(self.allocator);
        }

        fn pack(gen: u8, index: u32) EntityType {
            return @intCast((@as(u32, gen) << 24) | index);
        }
        fn indexOf(handle: EntityType) u32 {
            return @as(u32, @intCast(handle)) & 0x00FF_FFFF;
        }

        pub fn createEntity(self: *Self) EntityType {
            const index = self.free.pop() orelse blk: {
                const i = self.next_index;
                self.next_index += 1;
                break :blk i;
            };
            const gen = self.gen_of.get(index) orelse 0;
            const handle = pack(gen, index);
            self.alive.put(handle, {}) catch @panic("OOM");
            return handle;
        }

        pub fn destroyEntity(self: *Self, entity: EntityType) void {
            if (!self.alive.contains(entity)) return;
            _ = self.alive.remove(entity);
            const index = indexOf(entity);
            const gen = self.gen_of.get(index) orelse 0;
            self.gen_of.put(index, gen +% 1) catch @panic("OOM");
            self.free.append(self.allocator, index) catch @panic("OOM");
        }

        pub fn entityExists(self: *Self, entity: EntityType) bool {
            return self.alive.contains(entity);
        }

        pub fn entityCount(self: *Self) usize {
            return self.alive.count();
        }

        pub fn addComponent(self: *Self, entity: EntityType, component: anytype) void {
            self.getOrCreateStorage(@TypeOf(component)).put(entity, component) catch @panic("OOM");
        }

        pub fn getComponent(self: *Self, entity: EntityType, comptime T: type) ?*T {
            if (!self.alive.contains(entity)) return null;
            const storage = self.getStorage(T) orelse return null;
            return storage.getPtr(entity);
        }

        pub fn hasComponent(self: *Self, entity: EntityType, comptime T: type) bool {
            if (!self.alive.contains(entity)) return false;
            const storage = self.getStorage(T) orelse return false;
            return storage.contains(entity);
        }

        pub fn removeComponent(self: *Self, entity: EntityType, comptime T: type) void {
            const storage = self.getStorage(T) orelse return;
            _ = storage.remove(entity);
        }

        pub fn View(comptime _includes: anytype, comptime _excludes: anytype) type {
            return struct {
                entities: []const EntityType,
                index: usize = 0,
                allocator: std.mem.Allocator,
                const ViewSelf = @This();
                const includes = _includes;
                const excludes = _excludes;
                pub fn next(self: *ViewSelf) ?EntityType {
                    if (self.index < self.entities.len) {
                        const e = self.entities[self.index];
                        self.index += 1;
                        return e;
                    }
                    return null;
                }
                pub fn deinit(self: *ViewSelf) void {
                    self.allocator.free(self.entities);
                }
            };
        }

        pub fn view(self: *Self, comptime includes: anytype, comptime excludes: anytype) View(includes, excludes) {
            var result: std.ArrayListUnmanaged(EntityType) = .empty;
            var it = self.alive.keyIterator();
            while (it.next()) |key_ptr| {
                if (self.matchesAll(key_ptr.*, includes, excludes)) {
                    result.append(self.allocator, key_ptr.*) catch @panic("OOM");
                }
            }
            return .{
                .entities = result.toOwnedSlice(self.allocator) catch @panic("OOM"),
                .allocator = self.allocator,
            };
        }

        fn matchesAll(self: *Self, entity: EntityType, comptime includes: anytype, comptime excludes: anytype) bool {
            inline for (includes) |T| {
                if (!self.hasComponent(entity, T)) return false;
            }
            inline for (excludes) |T| {
                if (self.hasComponent(entity, T)) return false;
            }
            return true;
        }

        pub fn QueryIterator(comptime components: anytype) type {
            return core.GenericQueryIterator(*Self, EntityType, components);
        }

        pub fn query(self: *Self, comptime components: anytype) QueryIterator(components) {
            var entities: std.ArrayListUnmanaged(EntityType) = .empty;
            var it = self.alive.keyIterator();
            while (it.next()) |key| entities.append(self.allocator, key.*) catch @panic("OOM");
            return .{ .backend = self, .entities = entities, .index = 0, .allocator = self.allocator };
        }

        fn getOrCreateStorage(self: *Self, comptime T: type) *std.AutoHashMap(EntityType, T) {
            const tid = typeId(T);
            if (self.storages.get(tid)) |raw| return @ptrCast(@alignCast(raw));
            const storage = self.allocator.create(std.AutoHashMap(EntityType, T)) catch @panic("OOM");
            storage.* = std.AutoHashMap(EntityType, T).init(self.allocator);
            self.storages.put(tid, @ptrCast(storage)) catch @panic("OOM");
            self.cleanups.append(self.allocator, &struct {
                fn cleanup(s: *Self) void {
                    if (s.storages.get(typeId(T))) |raw| {
                        const typed: *std.AutoHashMap(EntityType, T) = @ptrCast(@alignCast(raw));
                        typed.deinit();
                        s.allocator.destroy(typed);
                    }
                }
            }.cleanup) catch @panic("OOM");
            return storage;
        }

        fn getStorage(self: *Self, comptime T: type) ?*std.AutoHashMap(EntityType, T) {
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
}

const RecyclingBackend = RecyclingEcs(u32);
const RecyclingGame = engine.GameConfig(
    core.StubRender(RecyclingBackend.Entity),
    RecyclingBackend,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    TestEvents,
);

test "batch set ids: a recycled entity handle — the stale row does NOT write the new occupant (#788)" {
    contract.unbind();
    defer contract.unbind();

    var game = RecyclingGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const names = "[\"Position\"]";
    const a = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(a, "Position", "{\"x\":1,\"y\":2}"));

    var buf: [64]u8 = @splat(0);
    const required = batchGetIds(names, &buf);
    try testing.expectEqual(@as(usize, 4 + (8 + 2 * 4)), required);
    try testing.expectEqual(a, rowId(&buf, 4)); // the row carries a's full handle

    // Destroy a and spawn b — the backend RECYCLES a's index with a
    // bumped generation, so b shares a's index but is a DIFFERENT full
    // handle (the recycled-id hazard #788 flags).
    contract.labelle_entity_destroy(a);
    const b = contract.labelle_entity_create();
    try testing.expect(b != a); // different full handle…
    try testing.expectEqual(a & 0x00FF_FFFF, b & 0x00FF_FFFF); // …SAME index (genuinely recycled)
    try testing.expectEqual(@as(i32, 0), setComp(b, "Position", "{\"x\":50,\"y\":60}"));

    // Apply the STALE row (id == a). a is dead; b occupies a's slot.
    batchFloatSet(&buf, 4 + 8 + 0, 99);
    batchFloatSet(&buf, 4 + 8 + 4, 99);
    try testing.expectEqual(@as(i32, 0), batchSetIds(names, buf[4..required]));

    // The generational entityExists gate rejected the stale handle: b —
    // the new occupant of a's index — is UNTOUCHED, no cross-entity write.
    const bp = game.getComponent(@as(u32, @intCast(b)), core.Position).?;
    try testing.expectEqual(@as(f32, 50), bp.x);
    try testing.expectEqual(@as(f32, 60), bp.y);
    // a itself is gone.
    try testing.expect(game.getComponent(@as(u32, @intCast(a)), core.Position) == null);
}
