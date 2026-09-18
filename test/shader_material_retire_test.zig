//! #883 — a shader material destroyed mid-update must not be submitted
//! for one frame.
//!
//! `tick` runs `renderer.sync` in its always-run block, well BEFORE
//! `active_scene_update_fn`. A material replaced or cleared during that
//! update therefore had its backend material destroyed while the imminent
//! `render()` was still holding the id the sync cached — one frame drawn
//! through the plain-sprite fallback. The same ordering applies to the
//! curated `setMaterial` path, which clears the shader slot through
//! `clearShaderMaterial`.
//!
//! The fix is a **retire list**: destruction is deferred until after the
//! next `renderer.sync`, so a submitted id is always live for the frame it
//! was cached in. Bounded to one extra frame, and it covers `setMaterial`
//! for free.
//!
//! These tests assert the MECHANISM, not the absence of a crash. The
//! renderer below behaves like a real one with a cached draw list: `sync`
//! snapshots each sprite's material id, `render` walks that snapshot and
//! books every draw as `material_draws` (live id), `fallback_draws`
//! (`.none`) or `dead_submits` (an id the backend already destroyed —
//! precisely the #883 defect). A test that only checked "nothing crashed"
//! would pass against the bug.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const Ecs = core.MockEcsBackend(u32);
const sm = core.shader_material;

/// Renderer with a CACHED DRAW LIST — the shape that makes #883
/// observable. `sync` snapshots; `render` submits the snapshot.
const CachingRenderer = struct {
    const Self = @This();
    const Entity = u32;
    const max_cached = 16;
    const max_ids = 64;

    pub const Sprite = struct {
        sprite_name: []const u8 = "",
        visible: bool = true,
        z_index: i16 = 0,
        layer: enum { default } = .default,
        material: core.Material = .{},
    };
    pub const Shape = core.StubRender(u32).Shape;
    pub const ShaderMaterialDescriptor = struct {
        version: u32 = sm.VERSION,
        label: []const u8 = "",
        shaders: sm.ShaderVariants,
        parameters: []const sm.Parameter = &.{},
        textures: []const Binding = &.{},
        blend: sm.Blend = .alpha,
    };
    pub const Binding = struct { name: [:0]const u8, texture: core.TextureId, sampler: sm.Sampler = .point };

    creates: u64 = 0,
    destroys: usize = 0,
    /// `alive[i]` — whether material id `i` is still a live backend
    /// resource. Indexed by the id's integer value.
    alive: [max_ids]bool = @splat(false),

    /// What the last `sync` cached for the imminent `render`.
    cached: [max_cached]sm.Id = @splat(.none),
    cached_len: usize = 0,
    syncs: usize = 0,

    // Draw bookkeeping, filled by `render`.
    material_draws: usize = 0,
    fallback_draws: usize = 0,
    /// The defect: a cached id whose backend material was already
    /// destroyed. Must stay 0 forever.
    dead_submits: usize = 0,

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
    pub fn setScreenHeight(_: *Self, _: f32) void {}
    pub fn clear(_: *Self) void {}
    pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
    pub fn hasEntity(_: *const Self, _: Entity) bool {
        return false;
    }

    /// Snapshot every sprite's material id — the renderer-side cache the
    /// subsequent `render` submits from.
    pub fn sync(self: *Self, comptime EcsType: type, ecs: *EcsType) void {
        self.syncs += 1;
        self.cached_len = 0;
        var view = ecs.view(.{Sprite}, .{});
        defer view.deinit();
        while (view.next()) |entity| {
            const sprite = ecs.getComponent(entity, Sprite) orelse continue;
            if (self.cached_len == max_cached) break;
            self.cached[self.cached_len] = sprite.material.shader;
            self.cached_len += 1;
        }
    }

    /// Submit the cached draw list. A real backend cannot tell a dead id
    /// from a live one without asking; this one can, which is the whole
    /// point — it books the dead submit the real backend would silently
    /// turn into a plain-sprite draw.
    pub fn render(self: *Self) void {
        for (self.cached[0..self.cached_len]) |id| {
            if (id == .none) {
                self.fallback_draws += 1;
            } else if (!self.alive[@intFromEnum(id)]) {
                self.dead_submits += 1;
                self.fallback_draws += 1;
            } else {
                self.material_draws += 1;
            }
        }
    }

    pub fn shaderMaterialSupported(_: *const Self) bool {
        return true;
    }
    pub fn createShaderMaterial(self: *Self, _: ShaderMaterialDescriptor) !sm.Id {
        self.creates += 1;
        total_creates += 1;
        const id: sm.Id = @enumFromInt(self.creates);
        self.alive[@intFromEnum(id)] = true;
        return id;
    }
    pub fn destroyShaderMaterial(self: *Self, id: sm.Id) void {
        self.destroys += 1;
        total_destroys += 1;
        self.alive[@intFromEnum(id)] = false;
    }
    pub fn invalidateShaderMaterials(self: *Self) void {
        self.alive = @splat(false);
    }
    pub fn setShaderParameter(_: *Self, _: sm.Id, _: []const u8, _: []const f32) !void {}
    pub fn setShaderTexture(_: *Self, _: sm.Id, _: []const u8, _: core.TextureId) !void {}
};

/// Process-wide create/destroy tally. The per-renderer counters live
/// inside the `World` and go away with it, so the no-leak assertion —
/// which has to read the tally AFTER `Game.deinit` — reads these.
var total_creates: usize = 0;
var total_destroys: usize = 0;

const Empty = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const Game = engine.GameConfig(
    CachingRenderer,
    Ecs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    Empty,
    &.{},
    void,
);

const descriptor: engine.ShaderMaterialDescriptor = .{ .shaders = .{ .spv = "fragment" } };

/// What the scene update fn does this frame. The update runs AFTER
/// `renderer.sync` inside `tick`, which is the whole hazard.
const Swap = enum { replace_shader, clear_shader, curated_set_material, nothing };

var swap_mode: Swap = .nothing;
var swap_entity: u32 = 0;
var swap_error: ?anyerror = null;

fn sceneUpdate(ptr: *anyopaque, _: f32) void {
    const game: *Game = @ptrCast(@alignCast(ptr));
    switch (swap_mode) {
        .replace_shader => game.createShaderMaterial(swap_entity, descriptor) catch |err| {
            swap_error = err;
        },
        .clear_shader => game.clearShaderMaterial(swap_entity),
        // The curated path clears the shader slot through
        // `clearShaderMaterial` — same ordering, same hazard.
        .curated_set_material => game.setMaterial(swap_entity, .{ .effect = .flash }),
        .nothing => {},
    }
    swap_mode = .nothing;
}

fn boot(game: *Game) !u32 {
    total_creates = 0;
    total_destroys = 0;
    swap_mode = .nothing;
    swap_error = null;
    const e = game.createEntity();
    game.addSprite(e, .{});
    try game.createShaderMaterial(e, descriptor);
    swap_entity = e;
    game.active_scene_ptr = @ptrCast(game);
    game.active_scene_update_fn = &sceneUpdate;
    return e;
}

/// One engine frame, in the order the generated main drives it.
fn frame(game: *Game) void {
    game.tick(0.016);
    game.render();
}

// ── The defect ──────────────────────────────────────────────────────────

test "a shader material replaced mid-update is never submitted dead, and the material path still runs that frame" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try boot(&game);

    // Frame 1: sync caches material #1, THEN the update replaces it with
    // material #2. The render that follows still submits #1.
    swap_mode = .replace_shader;
    frame(&game);
    if (swap_error) |err| return err;

    try testing.expectEqual(@as(usize, 0), game.renderer.dead_submits);
    // The mechanism, not just the absence of a crash: this frame went out
    // through the MATERIAL path, not the plain-sprite fallback.
    try testing.expectEqual(@as(usize, 1), game.renderer.material_draws);
    try testing.expectEqual(@as(usize, 0), game.renderer.fallback_draws);
    // Destruction is DEFERRED — the superseded id was still needed.
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);

    // Frame 2: the sync at the top of `tick` re-reads the ECS, so the old
    // id can no longer be cached — and the flush right after it destroys
    // the retired material. Bounded to exactly one frame: no leak.
    frame(&game);
    try testing.expectEqual(@as(usize, 1), game.renderer.destroys);
    try testing.expectEqual(@as(usize, 0), game.renderer.dead_submits);
    try testing.expectEqual(@as(usize, 2), game.renderer.material_draws);
    try testing.expectEqual(@as(usize, 0), game.renderer.fallback_draws);
    // The live material is the replacement, and it is still alive.
    const live = game.shaderMaterial(e).?;
    try testing.expectEqual(@as(sm.Id, @enumFromInt(2)), live);
    try testing.expect(game.renderer.alive[@intFromEnum(live)]);
}

test "a shader material cleared mid-update is never submitted dead" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try boot(&game);

    swap_mode = .clear_shader;
    frame(&game);

    // The sprite is on the plain path in the ECS now, but the renderer's
    // cached draw list still names material #1 for THIS frame — so it must
    // still be alive.
    try testing.expectEqual(@as(usize, 0), game.renderer.dead_submits);
    try testing.expectEqual(@as(usize, 1), game.renderer.material_draws);
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
    try testing.expect(game.shaderMaterial(e) == null);

    // Next frame the sprite genuinely draws plain, and the retired
    // material is destroyed.
    frame(&game);
    try testing.expectEqual(@as(usize, 1), game.renderer.destroys);
    try testing.expectEqual(@as(usize, 1), game.renderer.fallback_draws);
    try testing.expectEqual(@as(usize, 0), game.renderer.dead_submits);
}

test "the curated setMaterial path gets the same deferral" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try boot(&game);

    swap_mode = .curated_set_material;
    frame(&game);

    try testing.expectEqual(@as(usize, 0), game.renderer.dead_submits);
    try testing.expectEqual(@as(usize, 1), game.renderer.material_draws);
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);

    frame(&game);
    try testing.expectEqual(@as(usize, 1), game.renderer.destroys);
    try testing.expectEqual(@as(usize, 0), game.renderer.dead_submits);
    // The curated effect the game asked for survived the shader's
    // retirement.
    try testing.expectEqual(core.MaterialEffect.flash, game.ecs_backend.getComponent(e, CachingRenderer.Sprite).?.material.effect);
}

// ── Deferral must not become a leak ─────────────────────────────────────

test "a material retired after the last sync is still destroyed on teardown" {
    {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        const e = try boot(&game);

        // Retire one material and never tick again — nothing flushes it
        // before teardown.
        try game.createShaderMaterial(e, descriptor);
        try testing.expectEqual(@as(usize, 2), total_creates);
        try testing.expectEqual(@as(usize, 0), total_destroys);
    }
    // `World.deinit` flushes the retire list while the renderer is still
    // alive: deferral never turns into a leak.
    try testing.expectEqual(total_creates, total_destroys);
}

test "every retired material is destroyed exactly once" {
    {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        const e = try boot(&game);
        // Three generations: two retirements plus the live one.
        try game.createShaderMaterial(e, descriptor);
        try game.createShaderMaterial(e, descriptor);
        try testing.expectEqual(@as(usize, 3), total_creates);
        try testing.expectEqual(@as(usize, 0), total_destroys);

        game.flushRetiredShaderMaterials();
        try testing.expectEqual(@as(usize, 2), total_destroys);
        // A second flush must not re-destroy anything.
        game.flushRetiredShaderMaterials();
        try testing.expectEqual(@as(usize, 2), total_destroys);
    }
    try testing.expectEqual(@as(usize, 3), total_creates);
    try testing.expectEqual(@as(usize, 3), total_destroys);
}
