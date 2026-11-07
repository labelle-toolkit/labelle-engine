//! RFC #794 evidence probe (not production code; not wired into `zig build test`).
//! Question: in the refresh POC, do "336 pending crossings" vs "304/268 cues
//! delivered" reflect valid accounting or lost cues? This probe measures the
//! shipped engine at be0991e only. It does not reimplement the POC's parked
//! refresh; "drain-then-apply" scenarios emulate its outcome by applying the
//! push only after the cursor has drained.
const std = @import("std");
const engine = @import("engine");
const core = @import("labelle-core");

const Components = engine.ComponentRegistry(.{ .SpriteAnimation = engine.SpriteAnimation });
const Ecs = core.MockEcsBackend(u32);
const Events = union(enum) {
    engine__anim_marker: engine.Events.anim_marker,
    engine__anim_complete: engine.Events.anim_complete,
    engine__anim_loop: engine.Events.anim_loop,
};

const Receiver = struct {
    ctx: engine.HookContext = .{},
    markers: usize = 0,
    loops: usize = 0,
    old_playback: u64 = 0,
    old_markers: usize = 0,
    new_markers: usize = 0,
    pub fn engine__anim_marker(self: *@This(), e: engine.Events.anim_marker) void {
        self.markers += 1;
        if (e.playback_id == self.old_playback) self.old_markers += 1 else self.new_markers += 1;
    }
    pub fn engine__anim_loop(self: *@This(), _: engine.Events.anim_loop) void {
        self.loops += 1;
    }
};
const Payload = core.MergeHookPayloads(.{ engine.HookPayload(u32), Events });
const Hooks = core.MergeHooks(Payload, .{*Receiver});
const G = engine.GameConfig(core.StubRender(Ecs.Entity), Ecs, engine.StubInput, engine.StubAudio, engine.StubVideo, engine.StubGui, *Hooks, core.StubLogSink, Components, &.{}, Events);
const B = engine.JsoncSceneBridge(G, Components);

// Same clip as the shipped "prefab refresh preserves pending crossings" test.
const source = "{\"version\":1,\"clips\":{\"walk\":{\"frames\":[\"a\",\"b\",\"c\"],\"markers\":[{\"name\":\"start\",\"frame\":0},{\"name\":\"footstep\",\"frame\":1}]}}}";
const prefab =
    \\{"components":{"Sprite":{"sprite_name":"a"},"SpriteAnimation":{"definition":"prop","clip":"walk","fps":4}}}
;

const Kind = enum { baseline_drain, today_remove, today_replace, drain_then_remove, drain_then_replace };

const tiny: f32 = 0.00001;

fn run(kind: Kind) !void {
    var game = G.init(std.testing.allocator);
    defer game.deinit();
    var r: Receiver = .{};
    var hooks = Hooks{ .receivers = .{&r} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", source);
    try B.addEmbeddedPrefab(&game, "propeller", prefab, "prefabs");
    try B.loadSceneFromSource(&game, "{\"children\":[]}", "prefabs");
    const e = game.spawnPrefab("propeller", .{ .x = 0, .y = 0 }).?;
    r.old_playback = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?.marker_playback_id;

    // Spawn-frame sync emits the initial frame-0 "start" marker.
    engine.spriteAnimationTick(&game, 0);
    game.dispatchEvents();
    const after_spawn = r.markers;

    // 100 s at 4 fps = 400 entered frames in one offered batch.
    engine.spriteAnimationTick(&game, 100);
    const anim = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    const queued_after_big = game.event_buffer.items.len;
    const steps_after_big = anim.marker_cursor.steps;

    var updates: usize = 0;
    const loops_before_mutation = r.loops;
    const markers_before_mutation = r.markers;
    switch (kind) {
        .baseline_drain => {},
        .today_remove => game.removeComponent(e, engine.SpriteAnimation),
        .today_replace => try game.reloadPrefabSource("propeller", prefab),
        .drain_then_remove, .drain_then_replace => {},
    }
    // Drain loop: dispatch then a near-zero tick, as the shipped test does.
    while (updates < 64) : (updates += 1) {
        game.dispatchEvents();
        const a = game.ecs_backend.getComponent(e, engine.SpriteAnimation) orelse break;
        if (!a.marker_cursor.pending() and game.event_buffer.items.len == 0) break;
        engine.spriteAnimationTick(&game, tiny);
    }
    const drained_updates = updates;
    const loops_after_mutation = r.loops - loops_before_mutation;
    const markers_after_mutation = r.markers - markers_before_mutation;
    switch (kind) {
        .drain_then_remove => game.removeComponent(e, engine.SpriteAnimation),
        .drain_then_replace => try game.reloadPrefabSource("propeller", prefab),
        else => {},
    }
    // Fixed tail window so replacements can produce new-playback cues.
    var tail: usize = 0;
    const tail_len: usize = if (kind == .today_replace or kind == .drain_then_replace) 10 else 0;
    while (tail < tail_len) : (tail += 1) {
        game.dispatchEvents();
        if (game.ecs_backend.getComponent(e, engine.SpriteAnimation) == null) continue;
        engine.spriteAnimationTick(&game, 0.25);
    }
    game.dispatchEvents();
    std.debug.print(
        "PROBE {s}: spawn_markers={d} queued_after_tick100={d} cursor_steps_after_tick100={d} drain_updates={d} markers_total={d} old_playback_markers={d} new_playback_markers={d} loops_total={d} markers_after_mutation={d} loops_after_mutation={d}\n",
        .{ @tagName(kind), after_spawn, queued_after_big, steps_after_big, drained_updates, r.markers, r.old_markers, r.new_markers, r.loops, markers_after_mutation, loops_after_mutation },
    );
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), after_spawn);
    try t.expectEqual(@as(usize, 64), queued_after_big);
    switch (kind) {
        // 400 entered frames = 267 markers + 133 loops; 64 handed off, 336 retained.
        .baseline_drain, .drain_then_remove => {
            try t.expectEqual(@as(usize, 268), r.old_markers);
            try t.expectEqual(@as(usize, 133), r.loops);
            try t.expectEqual(@as(usize, 336), (r.old_markers - 1) + r.loops - queued_after_big);
            try t.expectEqual(@as(usize, 0), r.new_markers);
        },
        // Queued markers are dropped by the liveness filter, retained ones vanish
        // with the component, but already-queued loop events still reach hooks.
        .today_remove => {
            try t.expectEqual(@as(usize, 0), markers_after_mutation);
            try t.expect(loops_after_mutation > 0);
        },
        // Today the blocked refresh is never applied: no new playback exists.
        .today_replace => try t.expectEqual(@as(usize, 0), r.new_markers),
        .drain_then_replace => {
            try t.expectEqual(@as(usize, 268), r.old_markers);
            try t.expect(r.new_markers > 0);
        },
    }
}

test "rfc794 refresh accounting probe" {
    inline for (std.meta.tags(Kind)) |k| try run(k);
}

// Persistence gap probe: the POC's sibling lost the cursor's retained steps,
// sequence counter and frame-zero entry state. MarkerCursor has no slices, so
// core serde can carry it; it does not carry events already handed off to
// game.event_buffer (those live outside the component).
fn noSkip(_: type, _: []const u8) bool {
    return false;
}

test "rfc794 MarkerCursor round-trips through core serde mid-backlog" {
    var game = G.init(std.testing.allocator);
    defer game.deinit();
    var r: Receiver = .{};
    var hooks = Hooks{ .receivers = .{&r} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", source);
    try B.addEmbeddedPrefab(&game, "propeller", prefab, "prefabs");
    try B.loadSceneFromSource(&game, "{\"children\":[]}", "prefabs");
    const e = game.spawnPrefab("propeller", .{ .x = 0, .y = 0 }).?;
    engine.spriteAnimationTick(&game, 0);
    game.dispatchEvents();
    engine.spriteAnimationTick(&game, 100);
    const cur = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?.marker_cursor;

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try core.serde.writeComponent(@TypeOf(cur), &cur, &buf.writer, noSkip);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    const back = try core.serde.readComponent(@TypeOf(cur), parsed.value, noSkip);
    std.debug.print("PROBE cursor_json={s}\n", .{buf.written()});
    try std.testing.expectEqual(cur.steps, back.steps);
    try std.testing.expectEqual(cur.sequence, back.sequence);
    try std.testing.expectEqual(cur.entering, back.entering);
    try std.testing.expectEqual(cur.loop_pending, back.loop_pending);
    try std.testing.expectEqual(cur.repetition, back.repetition);
    try std.testing.expectEqual(cur.marker_index, back.marker_index);
    try std.testing.expectApproxEqAbs(cur.remainder_seconds, back.remainder_seconds, 1e-6);
    // 64 occurrences are already in event_buffer and are NOT part of the cursor.
    try std.testing.expectEqual(@as(usize, 64), game.event_buffer.items.len);
}
