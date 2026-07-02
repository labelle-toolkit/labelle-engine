//! `Game.entitiesWith(includes)` — the Packs roster primitive (#653).
//!
//! A dirty-tracked, cached collection: `entitiesWith` hands back a
//! slice **borrowed from an engine-owned cache**, valid only until the
//! next structural mutation. A monotonic generation counter is bumped
//! on component add/remove and entity create/destroy; reads lazily
//! re-query only when the cached slot is stale for that tag-set.
//!
//! These tests cover: the roster returns the right entities, the cache
//! invalidates on add/remove, and the returned slice reflects the
//! latest set after a refresh.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const game_mod = engine.game_mod;

const TestGame = game_mod.Game;

const Health = struct {
    current: f32 = 0,
    max: f32 = 100,
};

const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

fn contains(slice: []const TestGame.EntityType, e: TestGame.EntityType) bool {
    for (slice) |x| if (x == e) return true;
    return false;
}

test "entitiesWith: empty world yields an empty roster" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const roster = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 0), roster.len);
}

test "entitiesWith: returns exactly the entities holding the tag" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    const e3 = game.createEntity();
    game.addComponent(e1, Health{ .current = 50 });
    game.addComponent(e2, Health{ .current = 75 });
    // e3 has only Velocity — must be excluded.
    game.addComponent(e3, Velocity{ .x = 1 });

    const roster = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 2), roster.len);
    try testing.expect(contains(roster, e1));
    try testing.expect(contains(roster, e2));
    try testing.expect(!contains(roster, e3));
}

test "entitiesWith: multi-component tag-set intersects the includes" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e1, Velocity{});
    game.addComponent(e2, Health{}); // no Velocity

    const roster = game.entitiesWith(.{ Health, Velocity });
    try testing.expectEqual(@as(usize, 1), roster.len);
    try testing.expect(contains(roster, e1));
}

test "entitiesWith: repeated reads in a mutation-free window return the same cached slice" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    game.addComponent(e1, Health{});

    const first = game.entitiesWith(.{Health});
    const second = game.entitiesWith(.{Health});
    // Borrowed from the same engine-owned slot — identical pointer and length.
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(first.len, second.len);
}

test "entitiesWith: cache invalidates when a component is added" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    game.addComponent(e1, Health{});

    try testing.expectEqual(@as(usize, 1), game.entitiesWith(.{Health}).len);

    // Structural mutation: a new Health-bearing entity must show up on
    // the next read without the caller doing anything special.
    const e2 = game.createEntity();
    game.addComponent(e2, Health{});

    const refreshed = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 2), refreshed.len);
    try testing.expect(contains(refreshed, e1));
    try testing.expect(contains(refreshed, e2));
}

test "entitiesWith: cache invalidates when a component is removed" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e2, Health{});

    try testing.expectEqual(@as(usize, 2), game.entitiesWith(.{Health}).len);

    game.removeComponent(e1, Health);

    const refreshed = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 1), refreshed.len);
    try testing.expect(!contains(refreshed, e1));
    try testing.expect(contains(refreshed, e2));
}

test "entitiesWith: roster reflects the latest set after a destroy + refresh" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e2, Health{});
    try testing.expectEqual(@as(usize, 2), game.entitiesWith(.{Health}).len);

    game.destroyEntity(e2);

    const refreshed = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 1), refreshed.len);
    try testing.expect(contains(refreshed, e1));
    try testing.expect(!contains(refreshed, e2));
}

test "entitiesWith: distinct tag-sets cache independently" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e2, Velocity{});

    const health_roster = game.entitiesWith(.{Health});
    const velocity_roster = game.entitiesWith(.{Velocity});

    try testing.expectEqual(@as(usize, 1), health_roster.len);
    try testing.expectEqual(@as(usize, 1), velocity_roster.len);
    try testing.expect(contains(health_roster, e1));
    try testing.expect(contains(velocity_roster, e2));
    // Separate slots → separate backing storage.
    try testing.expect(health_roster.ptr != velocity_roster.ptr);
}

test "entitiesWith: tag-set order does not matter — same slot for .{A,B} and .{B,A}" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e1, Velocity{});

    // The cache key sorts component type names before hashing, so both
    // orderings resolve to the SAME slot and share backing storage —
    // no duplicate slot, no thrash between two orderings of one query.
    const ab = game.entitiesWith(.{ Health, Velocity });
    const ba = game.entitiesWith(.{ Velocity, Health });

    try testing.expectEqual(@as(usize, 1), ab.len);
    try testing.expectEqual(@as(usize, 1), ba.len);
    // Same engine-owned slot → identical backing pointer.
    try testing.expectEqual(ab.ptr, ba.ptr);
    try testing.expect(contains(ba, e1));
}

// ── #657 lifetime-contract regression coverage ────────────────────────
//
// Ten distinct marker tag-sets so we can drive more than the OLD fixed
// 8-slot cache's capacity in a single mutation-free window. On the old
// round-robin design the 9th/10th distinct read evicts an earlier slot
// and rewrites its backing buffer *during a read* — silently clobbering a
// slice a caller is still holding. The unbounded map has no eviction, so
// each tag-set owns its buffer forever and borrows stay stable.

const M0 = struct { v: u8 = 0 };
const M1 = struct { v: u8 = 0 };
const M2 = struct { v: u8 = 0 };
const M3 = struct { v: u8 = 0 };
const M4 = struct { v: u8 = 0 };
const M5 = struct { v: u8 = 0 };
const M6 = struct { v: u8 = 0 };
const M7 = struct { v: u8 = 0 };
const M8 = struct { v: u8 = 0 };
const M9 = struct { v: u8 = 0 };

const markers = .{ M0, M1, M2, M3, M4, M5, M6, M7, M8, M9 };

test "entitiesWith (#657): a borrowed slice is not clobbered by reads of >8 other tag-sets" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Two entities hold M0; exactly one entity holds each of M1..M9.
    const m0a = game.createEntity();
    const m0b = game.createEntity();
    game.addComponent(m0a, M0{});
    game.addComponent(m0b, M0{});
    inline for (1..markers.len) |i| {
        const e = game.createEntity();
        game.addComponent(e, markers[i]{});
    }

    // Borrow M0's roster (len 2) and snapshot its contents.
    const a = game.entitiesWith(.{M0});
    try testing.expectEqual(@as(usize, 2), a.len);
    var snapshot: [2]TestGame.EntityType = undefined;
    @memcpy(&snapshot, a[0..2]);

    // Read M1..M9 — NINE further distinct tag-sets, zero structural
    // mutations. On the old design the 9th read evicts M0's slot and
    // rewrites the exact buffer `a` points into (to a len-1 roster).
    inline for (1..markers.len) |i| {
        const r = game.entitiesWith(.{markers[i]});
        try testing.expectEqual(@as(usize, 1), r.len);
    }

    // `a` must still describe M0 element-for-element. (Compare CONTENTS,
    // not just the pointer: the old design reuses the same buffer, so a
    // pure pointer-equality check would pass while the data is wrong.)
    try testing.expectEqual(@as(usize, 2), a.len);
    try testing.expectEqualSlices(TestGame.EntityType, &snapshot, a);

    // A fresh re-read of M0 must also still be correct.
    const a2 = game.entitiesWith(.{M0});
    try testing.expectEqual(@as(usize, 2), a2.len);
    try testing.expect(contains(a2, m0a));
    try testing.expect(contains(a2, m0b));
}

test "entitiesWith (#657): all tag-sets cache concurrently — no eviction, pure hits on re-read" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // One entity per marker so every roster has a live, allocated buffer.
    var owners: [markers.len]TestGame.EntityType = undefined;
    inline for (0..markers.len) |i| {
        const e = game.createEntity();
        game.addComponent(e, markers[i]{});
        owners[i] = e;
    }

    // First pass: read all 10 tag-sets, holding every returned slice.
    var first: [markers.len][]const TestGame.EntityType = undefined;
    inline for (0..markers.len) |i| {
        first[i] = game.entitiesWith(.{markers[i]});
        try testing.expectEqual(@as(usize, 1), first[i].len);
        try testing.expect(contains(first[i], owners[i]));
    }

    // Every backing pointer is distinct — no two tag-sets share a slot.
    for (0..markers.len) |i| {
        for (i + 1..markers.len) |j| {
            try testing.expect(first[i].ptr != first[j].ptr);
        }
    }

    // Second pass (still mutation-free): every read is a pure cache hit —
    // same backing pointer as the first pass, still content-correct. The
    // held first-pass slices remain valid despite the intervening
    // getOrPut inserts (which may rehash and move slot *values*, but the
    // heap buffers a slice points at do not move).
    inline for (0..markers.len) |i| {
        const again = game.entitiesWith(.{markers[i]});
        try testing.expectEqual(first[i].ptr, again.ptr);
        try testing.expectEqual(@as(usize, 1), again.len);
        try testing.expect(contains(again, owners[i]));
        // The originally-held slice is still intact.
        try testing.expectEqual(@as(usize, 1), first[i].len);
        try testing.expect(contains(first[i], owners[i]));
    }
}

test "entitiesWith (#657): roster-cache map OOM returns an empty roster and recovers" {
    // No existing FailingAllocator idiom in this repo — established here.
    //
    // The default MockEcsBackend's `view()` allocates eagerly and
    // `@panic("OOM")`s on failure, so the append-path OOM can't be driven
    // without tripping the backend first. Instead we drive the map-level
    // `getOrPut` OOM branch, which returns BEFORE `view()` is reached:
    // fail the very next allocation while the roster map is still empty,
    // so the first `getOrPut` (which must allocate the map's storage)
    // fails. entitiesWith must hand back an empty, non-borrowed roster and
    // not crash — then recover cleanly once the allocator is healthy.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var game = TestGame.init(failing.allocator());
    defer game.deinit();

    // Populate five Velocity entities BEFORE arming the allocator.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = game.createEntity();
        game.addComponent(e, Velocity{});
    }

    // Arm: the next allocation fails. The roster map is still empty, so
    // the upcoming read's `getOrPut` must allocate map storage → fails.
    failing.fail_index = failing.alloc_index;
    const under_oom = game.entitiesWith(.{Velocity});
    try testing.expectEqual(@as(usize, 0), under_oom.len); // empty, no crash

    // Heal the allocator; the same read must now succeed with all five —
    // proving the OOM left no poisoned entry behind.
    failing.fail_index = std.math.maxInt(usize);
    const recovered = game.entitiesWith(.{Velocity});
    try testing.expectEqual(@as(usize, 5), recovered.len);
}
