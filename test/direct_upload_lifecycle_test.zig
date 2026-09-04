//! #820 — direct `game.loadTextureFromMemory` uploads carried across a
//! GPU surface loss under their ORIGINAL ids.
//!
//! The asset catalog and the engine's UI fonts already survive an Android
//! TERM_WINDOW / INIT_WINDOW round-trip; direct uploads did not, so every
//! game holding one needed its own release/re-create hook pair. With
//! gfx's re-arm seam (`invalidateTexture` + `reuploadTextureFromMemory`
//! on `GfxRenderer`, labelle-gfx#345) the engine retains the bytes on
//! load, invalidates on `surfaceLost`, re-uploads under the same id on
//! `surfaceRestored` — BEFORE `engine__surface_restored` is delivered —
//! and frees the copy on `unloadTexture` / `deinit`.
//!
//! The renderers here are LOCAL test types, not core's `StubRender`: the
//! seam is optional, so one renderer exposes it (tracking on) and one
//! does not (tracking off, v2.13.0 behaviour), and both must compile.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

const Entity = core.MockEcsBackend(u32).Entity;

// ── Shared visual component decls (what `GameConfig` reads off a renderer) ──

const SpriteComp = struct {
    sprite_name: []const u8 = "",
    visible: bool = true,
    z_index: i16 = 0,
    layer: enum { default } = .default,
};
const ShapeComp = struct {
    shape: union(enum) {
        rectangle: struct { width: f32 = 10, height: f32 = 10 },
        circle: struct { radius: f32 = 10 },
    } = .{ .rectangle = .{} },
    color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
    visible: bool = true,
    z_index: i16 = 0,
    layer: enum { default } = .default,
};
const TextComp = struct {
    text: [:0]const u8 = "",
    visible: bool = true,
    z_index: i16 = 0,
};
const IconComp = struct {
    name: []const u8 = "",
    visible: bool = true,
};

/// One recorded `reuploadTextureFromMemory` call. `bytes` is a COPY taken
/// at call time, so the assertion proves the engine passed live memory,
/// not a pointer into something it had already freed.
const Reupload = struct {
    id: u32,
    file_type: [64]u8,
    file_type_len: usize,
    bytes: [64]u8,
    bytes_len: usize,

    fn fileType(self: *const Reupload) []const u8 {
        return self.file_type[0..self.file_type_len];
    }
    fn data(self: *const Reupload) []const u8 {
        return self.bytes[0..self.bytes_len];
    }
};

/// Renderer WITH the gfx re-arm seam. Same shape as the real `GfxRenderer`
/// (core `TextureId` params, `!void` re-upload) and instance-level
/// recording so each test reads what ITS game's renderer saw.
const TrackingRender = struct {
    const Self = @This();
    pub const Sprite = SpriteComp;
    pub const Shape = ShapeComp;
    pub const Text = TextComp;
    pub const Icon = IconComp;

    next_id: u32 = 1 << 31,
    live: std.AutoHashMapUnmanaged(u32, void) = .empty,
    invalidated: std.ArrayListUnmanaged(u32) = .empty,
    reuploads: std.ArrayListUnmanaged(Reupload) = .empty,
    unloaded: std.ArrayListUnmanaged(u32) = .empty,
    fail_load: bool = false,
    fail_reupload: bool = false,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .alloc = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.live.deinit(self.alloc);
        self.invalidated.deinit(self.alloc);
        self.reuploads.deinit(self.alloc);
        self.unloaded.deinit(self.alloc);
    }
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

    pub fn loadTextureFromMemory(self: *Self, _: [:0]const u8, _: []const u8) !core.TextureId {
        if (self.fail_load) return error.DecodeFailed;
        const id = self.next_id;
        self.next_id += 1;
        try self.live.put(self.alloc, id, {});
        return @enumFromInt(id);
    }
    pub fn unloadTexture(self: *Self, id: core.TextureId) void {
        _ = self.live.remove(@intFromEnum(id));
        self.unloaded.append(self.alloc, @intFromEnum(id)) catch unreachable;
    }
    pub fn invalidateTexture(self: *Self, id: core.TextureId) void {
        self.invalidated.append(self.alloc, @intFromEnum(id)) catch unreachable;
    }
    pub fn reuploadTextureFromMemory(self: *Self, id: core.TextureId, file_type: [:0]const u8, data: []const u8) !void {
        if (self.fail_reupload) return error.DecodeFailed;
        if (!self.live.contains(@intFromEnum(id))) return error.TextureNotRegistered;
        var rec = Reupload{ .id = @intFromEnum(id), .file_type = undefined, .file_type_len = file_type.len, .bytes = undefined, .bytes_len = data.len };
        @memcpy(rec.file_type[0..file_type.len], file_type);
        @memcpy(rec.bytes[0..data.len], data);
        try self.reuploads.append(self.alloc, rec);
    }
};

/// Renderer WITHOUT the seam — `loadTextureFromMemory`/`unloadTexture`
/// only, i.e. every gfx before 1.31. The engine must compile against it
/// and fall back to the v2.13.0 contract (no retention, nothing on the
/// surface events).
const PlainRender = struct {
    const Self = @This();
    pub const Sprite = SpriteComp;
    pub const Shape = ShapeComp;
    pub const Text = TextComp;
    pub const Icon = IconComp;

    next_id: u32 = 1 << 31,
    unload_count: usize = 0,

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

    pub fn loadTextureFromMemory(self: *Self, _: [:0]const u8, _: []const u8) !core.TextureId {
        const id = self.next_id;
        self.next_id += 1;
        return @enumFromInt(id);
    }
    pub fn unloadTexture(self: *Self, _: core.TextureId) void {
        self.unload_count += 1;
    }
};

// ── Hook recorder: proves ordering against the sync surface events ──────

const SurfaceEvents = union(enum) {
    engine__surface_lost: engine.Events.surface_lost,
    engine__surface_restored: engine.Events.surface_restored,
};

const Recorder = struct {
    /// Null for the `PlainRender` game — nothing to peek at there.
    renderer: ?*TrackingRender = null,
    lost_count: usize = 0,
    restored_count: usize = 0,
    /// `renderer.invalidated.len` as seen INSIDE the lost hook.
    invalidated_at_lost: usize = 0,
    /// `renderer.reuploads.len` as seen INSIDE the restored hook.
    reuploads_at_restored: usize = 0,

    pub fn engine__surface_lost(self: *Recorder, _: anytype) void {
        self.lost_count += 1;
        if (self.renderer) |r| self.invalidated_at_lost = r.invalidated.items.len;
    }
    pub fn engine__surface_restored(self: *Recorder, _: anytype) void {
        self.restored_count += 1;
        if (self.renderer) |r| self.reuploads_at_restored = r.reuploads.items.len;
    }
};

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

fn GameFor(comptime Render: type) type {
    return game_mod.GameConfig(
        Render,
        core.MockEcsBackend(u32),
        engine.StubInput,
        engine.StubAudio,
        engine.StubVideo,
        engine.StubGui,
        *Recorder,
        core.StubLogSink,
        EmptyComponents,
        &.{},
        SurfaceEvents,
    );
}

const TrackingGame = GameFor(TrackingRender);
const PlainGame = GameFor(PlainRender);

const png_a = "\x89PNG-a";
const png_b = "\x89PNG-bb";

// ── With the seam ───────────────────────────────────────────────────────

test "the seam is detected from the renderer's decls" {
    try testing.expect(TrackingGame.tracks_direct_uploads);
    try testing.expect(!PlainGame.tracks_direct_uploads);
}

test "loadTextureFromMemory retains an OWNED copy of the bytes keyed by the public id" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    recorder.renderer = game.renderer;
    game.setHooks(&recorder);

    // Bytes on the stack, mutated after the load: the retained copy must
    // not follow — the engine cannot re-upload from a buffer the game has
    // since reused.
    var scratch: [png_a.len]u8 = undefined;
    @memcpy(&scratch, png_a);
    const id = try game.loadTextureFromMemory("png", &scratch);
    scratch[0] = 0;

    try testing.expectEqual(@as(u32, 1), game.active_world.direct_textures.count());
    const dt = game.active_world.direct_textures.get(id).?;
    try testing.expectEqualStrings("png", dt.file_type);
    try testing.expectEqualStrings(png_a, dt.bytes);
    try testing.expect(dt.bytes.ptr != &scratch);
}

test "unloadTexture frees the retained copy (u32 and typed handles alike)" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    recorder.renderer = game.renderer;
    game.setHooks(&recorder);

    const a = try game.loadTextureFromMemory("png", png_a);
    const b = try game.loadTextureFromMemory("png", png_b);
    try testing.expectEqual(@as(u32, 2), game.active_world.direct_textures.count());

    game.unloadTexture(a);
    try testing.expectEqual(@as(u32, 1), game.active_world.direct_textures.count());
    try testing.expect(game.active_world.direct_textures.get(a) == null);

    const typed: core.TextureId = @enumFromInt(b);
    game.unloadTexture(typed);
    try testing.expectEqual(@as(u32, 0), game.active_world.direct_textures.count());
    try testing.expectEqual(@as(usize, 2), game.renderer.unloaded.items.len);

    // Releasing an unknown id is harmless (and still reaches the renderer,
    // as before).
    game.unloadTexture(@as(u32, 12345));
    try testing.expectEqual(@as(usize, 3), game.renderer.unloaded.items.len);
    // `defer game.deinit()` under testing.allocator proves the rest.
}

test "deinit frees retained copies that were never unloaded" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    recorder.renderer = game.renderer;
    game.setHooks(&recorder);
    _ = try game.loadTextureFromMemory("png", png_a);
    _ = try game.loadTextureFromMemory("png", png_b);
    // testing.allocator reports the leak if `deinit` forgets them.
    game.deinit();
}

test "surfaceLost invalidates every retained id (never unloads); surfaceRestored re-uploads under the SAME ids before the hook" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    recorder.renderer = game.renderer;
    game.setHooks(&recorder);

    const a = try game.loadTextureFromMemory("png", png_a);
    const b = try game.loadTextureFromMemory("qoi", png_b);

    game.surfaceLost();
    // Both ids invalidated, none unloaded — the handle is dead, freeing
    // it later would hit a recycled slot.
    try testing.expectEqual(@as(usize, 2), game.renderer.invalidated.items.len);
    try testing.expectEqual(@as(usize, 0), game.renderer.unloaded.items.len);
    try testing.expectEqual(@as(usize, 1), recorder.lost_count);
    // ...and it happened BEFORE the sync hook ran.
    try testing.expectEqual(@as(usize, 2), recorder.invalidated_at_lost);
    // Retained copies untouched: the ids are still live.
    try testing.expectEqual(@as(u32, 2), game.active_world.direct_textures.count());

    game.surfaceRestored();
    try testing.expectEqual(@as(usize, 1), recorder.restored_count);
    // Re-upload landed BEFORE `engine__surface_restored`, so a hook that
    // re-resolves `nativeTextureId` from its held id sees the new texture.
    try testing.expectEqual(@as(usize, 2), recorder.reuploads_at_restored);

    const ups = game.renderer.reuploads.items;
    try testing.expectEqual(@as(usize, 2), ups.len);
    // Same public ids, original file types and bytes (map order is not
    // insertion order, so match by id).
    var seen_a = false;
    var seen_b = false;
    for (ups) |*u| {
        if (u.id == a) {
            seen_a = true;
            try testing.expectEqualStrings("png", u.fileType());
            try testing.expectEqualStrings(png_a, u.data());
        } else if (u.id == b) {
            seen_b = true;
            try testing.expectEqualStrings("qoi", u.fileType());
            try testing.expectEqualStrings(png_b, u.data());
        } else return error.UnexpectedId;
    }
    try testing.expect(seen_a and seen_b);
    // No fresh key was minted: the renderer still has exactly the two.
    try testing.expectEqual(@as(u32, 2), game.renderer.live.count());
}

test "an id released between loss and restore is not re-uploaded" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    recorder.renderer = game.renderer;
    game.setHooks(&recorder);

    const a = try game.loadTextureFromMemory("png", png_a);
    const b = try game.loadTextureFromMemory("png", png_b);
    game.surfaceLost();
    // A game that still follows the v2.13.0 contract and releases in its
    // lost hook loses nothing: the retained copy goes with the id.
    game.unloadTexture(a);
    game.surfaceRestored();

    const ups = game.renderer.reuploads.items;
    try testing.expectEqual(@as(usize, 1), ups.len);
    try testing.expectEqual(b, ups[0].id);
}

test "a failed re-upload is logged, the entry kept, and the restore still completes" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    recorder.renderer = game.renderer;
    game.setHooks(&recorder);

    _ = try game.loadTextureFromMemory("png", png_a);
    game.renderer.fail_reupload = true;
    game.surfaceLost();
    game.surfaceRestored();
    try testing.expectEqual(@as(usize, 1), recorder.restored_count);
    try testing.expectEqual(@as(usize, 0), game.renderer.reuploads.items.len);
    // Kept so `unloadTexture`/`deinit` still own the copy (no leak, no
    // dangling id).
    try testing.expectEqual(@as(u32, 1), game.active_world.direct_textures.count());
}

test "a failed load retains nothing" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    recorder.renderer = game.renderer;
    game.setHooks(&recorder);

    game.renderer.fail_load = true;
    try testing.expectError(error.DecodeFailed, game.loadTextureFromMemory("png", png_a));
    try testing.expectEqual(@as(u32, 0), game.active_world.direct_textures.count());
}

// ── Without the seam (gfx < 1.31): v2.13.0 behaviour, byte for byte ─────

test "a renderer without the seam retains nothing and the surface events do nothing extra" {
    var recorder = Recorder{};
    var game = PlainGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    const id = try game.loadTextureFromMemory("png", png_a);
    try testing.expect(id >= (1 << 31));
    try testing.expectEqual(@as(u32, 0), game.active_world.direct_textures.count());

    // Both compile and run; nothing to invalidate or re-upload.
    game.surfaceLost();
    game.surfaceRestored();
    try testing.expectEqual(@as(usize, 1), recorder.lost_count);
    try testing.expectEqual(@as(usize, 1), recorder.restored_count);

    game.unloadTexture(id);
    try testing.expectEqual(@as(usize, 1), game.renderer.unload_count);
}

// ── Multi-world scoping (review round 1) ────────────────────────────────
//
// Every `World` owns its own renderer, and every renderer mints ids from
// the same base — so world A and world B routinely hand out the SAME
// `u32`. A game-global retention map keyed by that bare id cross-wires
// them: a load/unload in B replaces or frees A's entry, and a surface
// cycle while B is active re-uploads A's bytes through B's renderer,
// clobbering an unrelated texture. The store lives on the World instead.
//
// The other half of the argument: one backend GPU context serves every
// world, so its loss kills the SHELVED worlds' textures too — the surface
// cycle must cover all of them, each against its own renderer.

const world_a_png = "\x89PNG-A-world";
const world_b_png = "\x89PNG-B-world";

test "worlds retain independently: identical ids in two worlds do not clobber each other across a surface cycle" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    // World A becomes active (the unnamed default is destroyed) and takes
    // an upload; then world B, whose fresh renderer mints the SAME id.
    try game.createWorld("a");
    try game.setActiveWorld("a");
    const world_a = game.active_world;
    const id_a = try game.loadTextureFromMemory("png", world_a_png);

    try game.createWorld("b");
    try game.setActiveWorld("b");
    const world_b = game.active_world;
    const id_b = try game.loadTextureFromMemory("qoi", world_b_png);

    // The premise of the bug: same number, different registries.
    try testing.expectEqual(id_a, id_b);
    try testing.expect(world_a != world_b);

    // Neither store leaked into the other, and B's load did not replace A's.
    try testing.expectEqual(@as(u32, 1), world_a.direct_textures.count());
    try testing.expectEqual(@as(u32, 1), world_b.direct_textures.count());
    try testing.expectEqualStrings(world_a_png, world_a.direct_textures.get(id_a).?.bytes);
    try testing.expectEqualStrings(world_b_png, world_b.direct_textures.get(id_b).?.bytes);

    // Surface cycle while B is active. One GPU context serves both worlds,
    // so BOTH must be invalidated and re-uploaded — each against its own
    // renderer, with its own bytes.
    game.surfaceLost();
    try testing.expectEqual(@as(usize, 1), world_a.renderer.invalidated.items.len);
    try testing.expectEqual(@as(usize, 1), world_b.renderer.invalidated.items.len);

    game.surfaceRestored();
    const ups_a = world_a.renderer.reuploads.items;
    const ups_b = world_b.renderer.reuploads.items;
    try testing.expectEqual(@as(usize, 1), ups_a.len);
    try testing.expectEqual(@as(usize, 1), ups_b.len);
    // Each world's renderer saw ITS world's file type and bytes — the
    // clobber this test exists for would show up as A's png in B or a
    // double re-upload in the active renderer.
    try testing.expectEqualStrings("png", ups_a[0].fileType());
    try testing.expectEqualStrings(world_a_png, ups_a[0].data());
    try testing.expectEqualStrings("qoi", ups_b[0].fileType());
    try testing.expectEqualStrings(world_b_png, ups_b[0].data());
}

test "unloading in the active world leaves an identically-numbered entry in a shelved world intact" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    try game.createWorld("a");
    try game.setActiveWorld("a");
    const world_a = game.active_world;
    const id_a = try game.loadTextureFromMemory("png", world_a_png);

    try game.createWorld("b");
    try game.setActiveWorld("b");
    const world_b = game.active_world;
    const id_b = try game.loadTextureFromMemory("qoi", world_b_png);
    try testing.expectEqual(id_a, id_b);

    game.unloadTexture(id_b);

    // B's entry is gone; A's — same number, different world — untouched.
    try testing.expectEqual(@as(u32, 0), world_b.direct_textures.count());
    try testing.expectEqual(@as(u32, 1), world_a.direct_textures.count());
    try testing.expectEqualStrings(world_a_png, world_a.direct_textures.get(id_a).?.bytes);

    // The release reached B's renderer only.
    try testing.expectEqual(@as(usize, 1), world_b.renderer.unloaded.items.len);
    try testing.expectEqual(@as(usize, 0), world_a.renderer.unloaded.items.len);

    // And the surviving world still re-uploads on a cycle.
    game.surfaceLost();
    game.surfaceRestored();
    try testing.expectEqual(@as(usize, 1), world_a.renderer.reuploads.items.len);
    try testing.expectEqual(@as(usize, 0), world_b.renderer.reuploads.items.len);
}

test "a shelved world's retained copies are freed with the world, not leaked" {
    var recorder = Recorder{};
    var game = TrackingGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    try game.createWorld("a");
    try game.setActiveWorld("a");
    _ = try game.loadTextureFromMemory("png", world_a_png);

    try game.createWorld("b");
    try game.setActiveWorld("b");
    _ = try game.loadTextureFromMemory("qoi", world_b_png);

    // Destroying a shelved world frees its store...
    try game.setActiveWorld("a");
    game.destroyWorld("b");
    // ...and `game.deinit` frees the active one's. testing.allocator
    // reports either miss as a leak.
}
