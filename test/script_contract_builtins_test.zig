//! Script contract × `scene.builtins.Builtin` (#886).
//!
//! The contract's built-in dispatch used to be a hand-maintained list
//! that forgot `Emitter`: `labelle_component_set("Emitter", …)` fell
//! through to the registry loop and returned -1 while every other
//! authoring channel accepted it. The list is now derived from the
//! enum; these tests pin that EVERY built-in is reachable from a
//! script (so the lists cannot drift apart again), the Emitter channel
//! itself (scene apply fn + particle side table), and the unchanged
//! shadowing rule.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const contract = engine.script_contract;
const builtins = engine.scene_mod.builtins;

const Health = struct { hp: i32 = 100 };

const MockEcs = core.MockEcsBackend(u32);

fn GameWith(comptime Components: type) type {
    return engine.GameConfig(
        core.StubRender(MockEcs.Entity),
        MockEcs,
        engine.StubInput,
        engine.StubAudio,
        engine.StubVideo,
        engine.StubGui,
        void,
        core.StubLogSink,
        Components,
        &.{},
        void,
    );
}

const PlainGame = GameWith(engine.ComponentRegistry(.{ .Health = Health }));

fn setComp(id: u64, name: []const u8, json: []const u8) i32 {
    return contract.labelle_component_set(id, name.ptr, name.len, json.ptr, json.len);
}

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

// ── Drift guard: every Builtin tag is script-addressable ────────────

test "every scene built-in is set/get/has/remove-able from a script" {
    contract.unbind();
    defer contract.unbind();

    var game = PlainGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    // Iterates the ENUM, not a list kept here: a built-in added to
    // `scene.builtins.Builtin` is covered automatically, and fails here
    // if the contract cannot address it.
    inline for (comptime builtins.names) |name| {
        const b = comptime builtins.lookup(name).?;
        const T = comptime b.Type(PlainGame);
        const id = contract.labelle_entity_create();
        const ent: u32 = @intCast(id);

        if (setComp(id, name, "{}") != 0) {
            std.debug.print("built-in '{s}' refused by labelle_component_set\n", .{name});
            return error.BuiltinNotScriptable;
        }
        // Landed as the ENGINE built-in type (the built-in channel ran,
        // not some registry type of the same name).
        try testing.expect(game.getComponent(ent, T) != null);
        try testing.expectEqual(@as(i32, 1), hasComp(id, name));
        var buf: [4096]u8 = undefined;
        try testing.expect(getComp(id, name, &buf).len > 0);
        try testing.expectEqual(@as(i32, 0), removeComp(id, name));
        try testing.expectEqual(@as(i32, 0), hasComp(id, name));
        try testing.expect(game.getComponent(ent, T) == null);
    }
}

// ── Emitter (#886) ──────────────────────────────────────────────────

test "Emitter: set goes through the scene's applyEmitter and round-trips via get" {
    contract.unbind();
    defer contract.unbind();

    var game = PlainGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    try testing.expect(PlainGame.emitter_is_builtin);
    try testing.expect(!game.drive_particles);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Emitter", "{\"config\":{\"rate\":42,\"max_particles\":64}}"));

    // `drive_particles` is flipped ONLY by `applyEmitter` — the proof
    // that the scene loader's own apply fn handled the write.
    try testing.expect(game.drive_particles);
    const em = game.getComponent(ent, PlainGame.EmitterComp).?;
    try testing.expectEqual(@as(f32, 42), em.config.rate);
    try testing.expectEqual(@as(u32, 64), em.config.max_particles);

    // get → set on another entity reproduces the component.
    var buf: [4096]u8 = undefined;
    const json = getComp(id, "Emitter", &buf);
    const id2 = contract.labelle_entity_create();
    try testing.expectEqual(@as(i32, 0), setComp(id2, "Emitter", json));
    const em2 = game.getComponent(@intCast(id2), PlainGame.EmitterComp).?;
    try testing.expect(std.meta.eql(em.*, em2.*));

    // Presets map from their enum name, as in a scene.
    try testing.expectEqual(@as(i32, 0), setComp(id2, "Emitter", "{\"preset\":\"sparks\"}"));
    try testing.expectEqual(engine.EmitterPreset.sparks, game.getComponent(@intCast(id2), PlainGame.EmitterComp).?.preset);

    // Malformed payload: refused, entity untouched.
    try testing.expectEqual(@as(i32, -1), setComp(id, "Emitter", "{\"config\":"));
    try testing.expectEqual(@as(f32, 42), game.getComponent(ent, PlainGame.EmitterComp).?.config.rate);
}

test "Emitter: re-set and remove resync the live particle system" {
    contract.unbind();
    defer contract.unbind();

    var game = PlainGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Emitter", "{\"config\":{\"rate\":10,\"max_particles\":64}}"));
    // The tick snapshots the config into a side-table ParticleSystem.
    game.tick(0.1);
    const before = game.particleSystem(ent) orelse return error.NoParticleSystem;
    try testing.expectEqual(@as(f32, 10), before.config.rate);

    // A script re-set with a new config drops the stale snapshot at SET
    // time (asserted before any tick), so the next tick rebuilds it.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Emitter", "{\"config\":{\"rate\":99,\"max_particles\":64}}"));
    try testing.expect(game.particleSystem(ent) == null);
    game.tick(0.1);
    try testing.expectEqual(@as(f32, 99), (game.particleSystem(ent) orelse return error.NoParticleSystem).config.rate);

    // Remove releases the pool immediately — even hard-paused, where
    // the tick's ghost reaper does not run.
    game.setTimeScale(0);
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Emitter"));
    try testing.expectEqual(@as(i32, 0), hasComp(id, "Emitter"));
    try testing.expect(game.particleSystem(ent) == null);
    try testing.expectEqual(@as(usize, 0), game.particle_systems.count());
}

// ── Shadowing is unchanged ──────────────────────────────────────────

const RegisteredEmitter = struct { rate: f32 = 1 };
const ShadowGame = GameWith(engine.ComponentRegistry(.{
    .Health = Health,
    .Emitter = RegisteredEmitter,
}));

test "a project-registered Emitter wins over the built-in" {
    contract.unbind();
    defer contract.unbind();

    try testing.expect(!ShadowGame.emitter_is_builtin);

    var game = ShadowGame.init(testing.allocator);
    defer game.deinit();
    contract.bind(&game);

    const id = contract.labelle_entity_create();
    const ent: u32 = @intCast(id);
    try testing.expectEqual(@as(i32, 0), setComp(id, "Emitter", "{\"rate\":5}"));
    // Registry path (setComponent) ran: the project's type landed, the
    // engine built-in never materialized and applyEmitter never ran.
    try testing.expectEqual(@as(f32, 5), game.getComponent(ent, RegisteredEmitter).?.rate);
    try testing.expect(game.getComponent(ent, ShadowGame.EmitterComp) == null);
    try testing.expect(!game.drive_particles);

    var buf: [128]u8 = undefined;
    const parsed = try std.json.parseFromSlice(RegisteredEmitter, testing.allocator, getComp(id, "Emitter", &buf), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f32, 5), parsed.value.rate);
    try testing.expectEqual(@as(i32, 0), removeComp(id, "Emitter"));
    try testing.expect(game.getComponent(ent, RegisteredEmitter) == null);

    // Unshadowable built-ins stay built-in alongside it.
    try testing.expectEqual(@as(i32, 0), setComp(id, "Sprite", "{\"sprite_name\":\"x\"}"));
    try testing.expect(game.getComponent(ent, ShadowGame.SpriteComp) != null);
}
