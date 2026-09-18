const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");
const Ecs = core.MockEcsBackend(u32);
const sm = core.shader_material;
const MockRenderer = struct {
    const Self = @This();
    const Entity = u32;
    pub const Sprite = struct { sprite_name: []const u8 = "", visible: bool = true, z_index: i16 = 0, layer: enum { default } = .default, material: core.Material = .{} };
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
    visual_dirty_count: usize = 0,
    creates: u64 = 0,
    destroys: usize = 0,
    invalidates: usize = 0,
    writes: usize = 0,
    texture_writes: usize = 0,
    fail_create: bool = false,
    fail_update: bool = false,
    stale: bool = false,
    last_texture: core.TextureId = .invalid,
    pub fn init(_: std.mem.Allocator) Self {
        return .{};
    }
    pub fn deinit(_: *Self) void {}
    pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
    pub fn untrackEntity(_: *Self, _: Entity) void {}
    pub fn markPositionDirty(_: *Self, _: Entity) void {}
    pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
    pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
    pub fn markVisualDirty(self: *Self, _: Entity) void {
        self.visual_dirty_count += 1;
    }
    pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
    pub fn render(_: *Self) void {}
    pub fn setScreenHeight(_: *Self, _: f32) void {}
    pub fn clear(_: *Self) void {}
    pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
    pub fn hasEntity(_: *const Self, _: Entity) bool {
        return false;
    }

    pub fn shaderMaterialSupported(_: *const Self) bool {
        return true;
    }
    pub fn createShaderMaterial(self: *Self, desc: ShaderMaterialDescriptor) !sm.Id {
        if (self.fail_create) return error.InvalidShader;
        self.creates += 1;
        if (desc.textures.len > 0) self.last_texture = desc.textures[0].texture;
        return @enumFromInt(self.creates);
    }
    pub fn destroyShaderMaterial(self: *Self, _: sm.Id) void {
        self.destroys += 1;
    }
    pub fn invalidateShaderMaterials(self: *Self) void {
        self.invalidates += 1;
    }
    pub fn setShaderParameter(self: *Self, _: sm.Id, _: []const u8, _: []const f32) !void {
        if (self.stale) return error.InvalidHandle;
        self.writes += 1;
    }
    pub fn setShaderTexture(self: *Self, _: sm.Id, _: []const u8, texture: core.TextureId) !void {
        if (self.fail_update) return error.InvalidTexture;
        if (self.stale) return error.InvalidHandle;
        self.texture_writes += 1;
        self.last_texture = texture;
    }
};
const Empty = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};
fn GameWith(comptime R: type) type {
    return engine.GameConfig(R, Ecs, engine.StubInput, engine.StubAudio, engine.StubVideo, engine.StubGui, void, core.StubLogSink, Empty, &.{}, void);
}
const Game = GameWith(MockRenderer);
const descriptor: engine.ShaderMaterialDescriptor = .{ .shaders = .{ .spv = "fragment" }, .parameters = &.{.{ .name = "u_time", .kind = .scalar }} };
fn spawn(game: *Game) !u32 {
    const e = game.createEntity();
    game.addSprite(e, .{});
    try game.createShaderMaterial(e, descriptor);
    return e;
}
test "shader facade executes create update replace clear and entity destruction" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try spawn(&game);
    try testing.expectEqual(@as(u64, 1), game.renderer.creates);
    try testing.expectEqual(game.shaderMaterial(e).?, game.ecs_backend.getComponent(e, MockRenderer.Sprite).?.material.shader);
    try game.setShaderParameter(e, "u_time", &.{3});
    try testing.expectEqual(@as(usize, 1), game.renderer.writes);
    const old = game.shaderMaterial(e);
    game.renderer.fail_create = true;
    try testing.expectError(error.InvalidShader, game.createShaderMaterial(e, descriptor));
    try testing.expectEqual(old, game.shaderMaterial(e));
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
    game.renderer.fail_create = false;
    try game.createShaderMaterial(e, descriptor);
    // #883: the superseded material is RETIRED, not destroyed on the
    // spot — the renderer's cached draw list may still name it for the
    // frame it was synced in. `flushRetiredShaderMaterials` (which `tick`
    // runs right after `renderer.sync`) is what frees it.
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
    game.flushRetiredShaderMaterials();
    try testing.expectEqual(@as(usize, 1), game.renderer.destroys);
    game.destroyEntity(e);
    game.flushRetiredShaderMaterials();
    try testing.expectEqual(@as(usize, 2), game.renderer.destroys);
    try testing.expect(game.shaderMaterial(e) == null);
    game.clearShaderMaterial(e);
    game.flushRetiredShaderMaterials();
    try testing.expectEqual(@as(usize, 2), game.renderer.destroys);
}
test "shader scene reset destroys instances and reused entity ids start empty" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    _ = try spawn(&game);
    _ = try spawn(&game);
    game.resetEcsBackend();
    game.flushRetiredShaderMaterials();
    try testing.expectEqual(@as(usize, 2), game.renderer.destroys);
    const e = game.createEntity();
    try testing.expect(game.shaderMaterial(e) == null);
    game.addSprite(e, .{});
    try game.createShaderMaterial(e, descriptor);
    try testing.expectEqual(@as(u64, 3), game.renderer.creates);
}
test "shader ownership stays with named worlds and context loss clears every world" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.createWorld("a");
    try game.setActiveWorld("a");
    const a = try spawn(&game);
    const world_a = game.active_world;
    try game.createWorld("b");
    try game.setActiveWorld("b");
    const b_entity = try spawn(&game);
    try testing.expectEqual(a, b_entity);
    try testing.expectEqual(@as(usize, 0), world_a.renderer.destroys);
    game.surfaceLost();
    try testing.expectEqual(@as(usize, 0), world_a.renderer.destroys);
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
    try testing.expectEqual(@as(usize, 1), world_a.renderer.invalidates);
    try testing.expectEqual(@as(usize, 1), game.renderer.invalidates);
    try testing.expect(game.shaderMaterial(b_entity) == null);
    try testing.expectError(error.GpuSurfaceUnavailable, game.createShaderMaterial(b_entity, descriptor));
    try game.setActiveWorld("a");
    try testing.expect(game.shaderMaterial(a) == null);
    game.destroyWorld("b");
}
test "backend invalid handle clears binding and game can recreate" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try spawn(&game);
    game.renderer.stale = true;
    try testing.expectError(error.InvalidHandle, game.setShaderParameter(e, "u_time", &.{0}));
    try testing.expect(game.shaderMaterial(e) == null);
    try testing.expectEqual(sm.Id.none, game.ecs_backend.getComponent(e, MockRenderer.Sprite).?.material.shader);
    game.renderer.stale = false;
    try game.createShaderMaterial(e, descriptor);
    try testing.expectEqual(@as(u64, 2), game.renderer.creates);
}
test "unsupported renderer returns actionable errors with no resource state" {
    var game = GameWith(core.StubRender(u32)).init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();
    try testing.expectError(error.Unsupported, game.createShaderMaterial(e, descriptor));
    try testing.expectError(error.Unsupported, game.setShaderParameter(e, "u_time", &.{0}));
    try testing.expectError(error.Unsupported, game.setShaderTexture(e, "s_mask", "mask"));
    game.clearShaderMaterial(e);
}
const ImageBackend = struct {
    var next: u32 = 700;
    var uploads: usize = 0;
    var unloads: usize = 0;
    fn decode(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) !engine.DecodedImage {
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0xff);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }
    fn upload(_: engine.DecodedImage) !engine.AssetTexture {
        uploads += 1;
        next += 1;
        return next;
    }
    fn unload(_: engine.AssetTexture) void {
        unloads += 1;
    }
    fn install() void {
        uploads = 0;
        unloads = 0;
        engine.ImageLoader.setBackend(.{ .decode = decode, .upload = upload, .unload = unload });
    }
};
fn refs(game: *Game, key: []const u8) u32 {
    return game.assets.entries.getPtr(key).?.refcount;
}
fn pumpReady(game: *Game, key: []const u8) !void {
    for (0..1000) |_| {
        game.assets.pump();
        if (game.assets.isReady(key)) return;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TextureDidNotLoad;
}
fn textured(key: []const u8, binding: *[1]engine.ShaderTextureBinding) engine.ShaderMaterialDescriptor {
    binding.* = .{.{ .name = "s_mask", .texture = .{ .catalog = key } }};
    var d = descriptor;
    d.textures = binding;
    return d;
}
test "cold catalog request holds one pending pin, retries, and restores last-owner texture" {
    ImageBackend.install();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.registerImageFromMemory("mask", ".png", "fake");
    const e = game.createEntity();
    game.addSprite(e, .{});
    var binding: [1]engine.ShaderTextureBinding = undefined;
    const d = textured("mask", &binding);
    try testing.expectError(error.TextureNotReady, game.createShaderMaterial(e, d));
    try testing.expectEqual(@as(u32, 1), refs(&game, "mask"));
    try testing.expectError(error.TextureNotReady, game.createShaderMaterial(e, d));
    try testing.expectEqual(@as(u32, 1), refs(&game, "mask"));
    try pumpReady(&game, "mask");
    try game.createShaderMaterial(e, d);
    try testing.expectEqual(@as(u32, 1), refs(&game, "mask"));
    try testing.expectEqual(@as(usize, 0), game.active_world.shader_pending.count());
    const before = game.renderer.last_texture;
    game.surfaceLost();
    try testing.expectEqual(@as(u32, 0), refs(&game, "mask"));
    try testing.expect(game.shaderMaterial(e) == null);
    game.surfaceRestored();
    try testing.expectError(error.TextureNotReady, game.createShaderMaterial(e, d));
    try pumpReady(&game, "mask");
    try game.createShaderMaterial(e, d);
    try testing.expect(game.renderer.last_texture != before);
    try testing.expectEqual(@as(u32, 1), refs(&game, "mask"));
    game.destroyEntityOnly(e);
    try testing.expectEqual(@as(u32, 0), refs(&game, "mask"));
    try testing.expectEqual(@as(usize, 2), ImageBackend.uploads);
}
test "catalog texture replacement balances success failure and superseded pending bindings" {
    ImageBackend.install();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.loadImageFromMemory("ready", ".png", "fake");
    try game.registerImageFromMemory("cold", ".png", "fake");
    const e = game.createEntity();
    game.addSprite(e, .{});
    var binding: [1]engine.ShaderTextureBinding = undefined;
    try game.createShaderMaterial(e, textured("ready", &binding));
    try testing.expectEqual(@as(u32, 2), refs(&game, "ready"));
    try testing.expectError(error.TextureNotReady, game.setShaderTexture(e, "s_mask", "cold"));
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    try game.setShaderTexture(e, "s_mask", "ready");
    try testing.expectEqual(@as(u32, 0), refs(&game, "cold"));
    try testing.expectEqual(@as(u32, 2), refs(&game, "ready"));
    try game.registerImageFromMemory("cold2", ".png", "fake");
    try testing.expectError(error.TextureNotReady, game.setShaderTexture(e, "s_mask", "cold2"));
    try game.setShaderTexture(e, "s_mask", @as(core.TextureId, @enumFromInt(99)));
    try testing.expectEqual(@as(u32, 0), refs(&game, "cold2"));
    try testing.expectEqual(@as(u32, 1), refs(&game, "ready"));
    game.renderer.fail_update = true;
    try testing.expectError(error.InvalidTexture, game.setShaderTexture(e, "s_mask", "ready"));
    try testing.expectEqual(@as(u32, 1), refs(&game, "ready"));
    game.renderer.fail_update = false;
    try game.setShaderTexture(e, "s_mask", @as(engine.ShaderTexture, .{ .catalog = "ready" }));
    game.clearShaderMaterial(e);
    try testing.expectEqual(@as(u32, 1), refs(&game, "ready"));
}
test "pending acquisitions survive failed material creation and are released on scene reset" {
    ImageBackend.install();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.registerImageFromMemory("cold", ".png", "fake");
    const e = game.createEntity();
    game.addSprite(e, .{});
    var binding: [1]engine.ShaderTextureBinding = undefined;
    const d = textured("cold", &binding);
    try testing.expectError(error.TextureNotReady, game.createShaderMaterial(e, d));
    try pumpReady(&game, "cold");
    game.renderer.fail_create = true;
    try testing.expectError(error.InvalidShader, game.createShaderMaterial(e, d));
    // The attempt's own committed pin was released; the retained pending
    // request (the asset is already streamed) is NOT — a retry must not
    // re-stream it.
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    try testing.expectEqual(@as(usize, 1), game.active_world.shader_pending.count());
    game.renderer.fail_create = false;
    try game.createShaderMaterial(e, d);
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    try testing.expectEqual(@as(usize, 0), game.active_world.shader_pending.count());
    game.clearShaderMaterial(e);
    try testing.expectEqual(@as(u32, 0), refs(&game, "cold"));
    try game.registerImageFromMemory("reset", ".png", "fake");
    try testing.expectError(error.TextureNotReady, game.createShaderMaterial(e, textured("reset", &binding)));
    game.resetEcsBackend();
    try testing.expectEqual(@as(u32, 0), refs(&game, "reset"));
    try testing.expectEqual(@as(usize, 0), game.active_world.shader_pending.count());
}
test "direct ECS destruction and sprite removal reap committed and pending ownership" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try spawn(&game);
    game.ecs_backend.destroyEntity(e);
    game.reapShaderMaterials();
    try testing.expect(game.shaderMaterial(e) == null);
    const next = try spawn(&game);
    game.ecs_backend.removeComponent(next, MockRenderer.Sprite);
    game.reapShaderMaterials();
    game.flushRetiredShaderMaterials();
    try testing.expectEqual(@as(usize, 2), game.renderer.destroys);
}
test "actual atomic scene swap clears shader ownership before new scene loader" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try spawn(&game);
    const Loader = struct {
        fn load(g: *Game) anyerror!void {
            try testing.expectEqual(@as(usize, 0), g.active_world.shader_materials.count());
            _ = try spawn(g);
        }
    };
    game.registerSceneSimple("next", Loader.load);
    try game.setSceneAtomic("next");
    game.flushRetiredShaderMaterials();
    try testing.expectEqual(@as(usize, 1), game.renderer.destroys);
    try testing.expectEqual(@as(u64, 2), game.renderer.creates);
    try testing.expect(game.shaderMaterial(e).? != @as(sm.Id, @enumFromInt(1)));
}
test "prefab JSONC cannot restore a live shader runtime handle" {
    const Value = engine.SceneValue;
    const parsed = engine.jsonc_deserializer.deserialize(sm.Id, Value{ .integer = 123 }, testing.allocator);
    try testing.expectEqual(sm.Id.none, parsed.?);
}
test "superseding one pending sampler preserves another sampler request" {
    ImageBackend.install();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.registerImageFromMemory("cold_a", ".png", "fake");
    try game.registerImageFromMemory("cold_b", ".png", "fake");
    const e = game.createEntity();
    game.addSprite(e, .{});
    var d = descriptor;
    d.textures = &.{ .{ .name = "s_a", .texture = .{ .id = @enumFromInt(99) } }, .{ .name = "s_b", .texture = .{ .id = @enumFromInt(98) } } };
    try game.createShaderMaterial(e, d);
    try testing.expectError(error.TextureNotReady, game.setShaderTexture(e, "s_a", "cold_a"));
    try testing.expectError(error.TextureNotReady, game.setShaderTexture(e, "s_b", "cold_b"));
    try game.setShaderTexture(e, "s_a", @as(core.TextureId, @enumFromInt(97)));
    try testing.expectEqual(@as(u32, 0), refs(&game, "cold_a"));
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold_b"));
    try pumpReady(&game, "cold_b");
    try game.setShaderTexture(e, "s_b", "cold_b");
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold_b"));
    game.clearMaterial(e);
    try testing.expectEqual(@as(u32, 0), refs(&game, "cold_b"));
    try testing.expect(game.shaderMaterial(e) == null);
}

test "zon writer rejects typed authored shader handles" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const Writer = @import("scene").entity_writer.EntityWriter(Game, Empty);
    const e = game.createEntity();
    _ = Writer.addComponents(e, &game, .{ .Sprite = @as(MockRenderer.Sprite, .{ .material = .{ .shader = @enumFromInt(123) } }) }, null);
    try testing.expectEqual(sm.Id.none, game.ecs_backend.getComponent(e, MockRenderer.Sprite).?.material.shader);
}

// A game-owned shader takes PRECEDENCE over a curated effect; it does not
// replace it. Creating and then clearing a shader material must leave the
// authored `effect`/`uniforms` exactly as the game set them — asserted on the
// component itself, so a fix that merely re-derived the same `.none` would not
// pass.
test "shader creation preserves the curated material effect it takes precedence over" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();
    game.addSprite(e, .{});
    game.setMaterial(e, .{ .effect = .flash, .uniforms = .{ .scalar0 = 0.5, .r = 1 } });
    try game.createShaderMaterial(e, descriptor);
    const sprite = game.ecs_backend.getComponent(e, MockRenderer.Sprite).?;
    try testing.expect(sprite.material.shader != .none);
    try testing.expectEqual(core.MaterialEffect.flash, sprite.material.effect);
    try testing.expectEqual(@as(f32, 0.5), sprite.material.uniforms.scalar0);
    try testing.expectEqual(@as(f32, 1), sprite.material.uniforms.r);
    game.clearShaderMaterial(e);
    try testing.expectEqual(sm.Id.none, sprite.material.shader);
    try testing.expectEqual(core.MaterialEffect.flash, sprite.material.effect);
    try testing.expectEqual(@as(f32, 0.5), sprite.material.uniforms.scalar0);
}

// Contract: "Calls while the GPU is unavailable return GpuSurfaceUnavailable."
// Asserted on a LIVE entity whose material existed before the loss, so the
// error cannot be the incidental `InvalidHandle` an unknown entity would give.
test "shader setters report surface loss rather than a handle error" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = try spawn(&game);
    game.surfaceLost();
    try testing.expectError(error.GpuSurfaceUnavailable, game.setShaderParameter(e, "u_time", &.{0}));
    try testing.expectError(error.GpuSurfaceUnavailable, game.setShaderTexture(e, "s_mask", "mask"));
    game.surfaceRestored();
    try testing.expectError(error.InvalidHandle, game.setShaderParameter(e, "u_time", &.{0}));
    try game.createShaderMaterial(e, descriptor);
    try game.setShaderParameter(e, "u_time", &.{1});
}

// Stage-before-commit for the PENDING side (codex on #882): re-authoring on
// an entity that holds a cold pending request must not release that request
// — or the committed material — unless the replacement fully commits.
// Refcounts are asserted directly, and the ids compared, so a fix that
// merely re-requested the asset (refcount dips to 0 then back) would fail.
test "failed re-authoring keeps the previous material and every pending pin" {
    ImageBackend.install();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.loadImageFromMemory("ready", ".png", "fake");
    try game.registerImageFromMemory("cold", ".png", "fake");
    const e = game.createEntity();
    game.addSprite(e, .{});
    var binding: [1]engine.ShaderTextureBinding = undefined;
    try game.createShaderMaterial(e, textured("ready", &binding));
    const live = game.shaderMaterial(e).?;
    try testing.expectError(error.TextureNotReady, game.setShaderTexture(e, "s_mask", "cold"));
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    // Resolution failure on a descriptor that does not mention the pending binding.
    var other: [1]engine.ShaderTextureBinding = .{.{ .name = "s_other", .texture = .{ .catalog = "missing" } }};
    var d = descriptor;
    d.textures = &other;
    try testing.expectError(error.AssetNotRegistered, game.createShaderMaterial(e, d));
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    try testing.expectEqual(@as(u32, 2), refs(&game, "ready"));
    try testing.expectEqual(live, game.shaderMaterial(e).?);
    try testing.expectEqual(live, game.ecs_backend.getComponent(e, MockRenderer.Sprite).?.material.shader);
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
    // Backend creation failure after every texture resolved.
    game.renderer.fail_create = true;
    try testing.expectError(error.InvalidShader, game.createShaderMaterial(e, textured("ready", &binding)));
    game.renderer.fail_create = false;
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    try testing.expectEqual(@as(u32, 2), refs(&game, "ready"));
    try testing.expectEqual(live, game.shaderMaterial(e).?);
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
    // A failed texture update on the SAME binding keeps the pending request too.
    try testing.expectError(error.AssetNotRegistered, game.setShaderTexture(e, "s_mask", "missing"));
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    // The retained request is still the live one: once ready it commits
    // without re-streaming, and the sweep leaves exactly the committed pin.
    try pumpReady(&game, "cold");
    try game.setShaderTexture(e, "s_mask", "cold");
    try testing.expectEqual(@as(u32, 1), refs(&game, "cold"));
    try testing.expectEqual(@as(u32, 1), refs(&game, "ready"));
    try testing.expectEqual(@as(usize, 0), game.active_world.shader_pending.count());
    // "ready" (loadImageFromMemory) + "cold" exactly once: the retained
    // request kept it streamed across every failure, so nothing re-uploaded.
    try testing.expectEqual(@as(usize, 2), ImageBackend.uploads);
    game.clearShaderMaterial(e);
    try testing.expectEqual(@as(u32, 0), refs(&game, "cold"));
}

// labelle-gfx#361 hand-off: on surface loss the engine must FORGET materials
// through `invalidateShaderMaterials` — never destroy through the lost
// context — and its pin releases must not reach the image backend either
// (the catalog is invalidated first). After restore the setters report the
// stale id and a recreate goes live.
test "surface loss forgets materials without a backend destroy and recreation goes live after restore" {
    ImageBackend.install();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.loadImageFromMemory("mask", ".png", "fake");
    const e = game.createEntity();
    game.addSprite(e, .{});
    var binding: [1]engine.ShaderTextureBinding = undefined;
    try game.createShaderMaterial(e, textured("mask", &binding));
    const textureless = game.createEntity();
    game.addSprite(textureless, .{});
    try game.createShaderMaterial(textureless, descriptor);
    try testing.expectEqual(@as(u32, 2), refs(&game, "mask"));
    game.surfaceLost();
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
    try testing.expectEqual(@as(usize, 1), game.renderer.invalidates);
    try testing.expectEqual(@as(usize, 0), ImageBackend.unloads);
    try testing.expectEqual(@as(u32, 1), refs(&game, "mask"));
    try testing.expect(game.shaderMaterial(e) == null);
    try testing.expect(game.shaderMaterial(textureless) == null);
    try testing.expectEqual(sm.Id.none, game.ecs_backend.getComponent(e, MockRenderer.Sprite).?.material.shader);
    try testing.expectEqual(sm.Id.none, game.ecs_backend.getComponent(textureless, MockRenderer.Sprite).?.material.shader);
    game.surfaceRestored();
    try testing.expectError(error.InvalidHandle, game.setShaderParameter(e, "u_time", &.{0}));
    try pumpReady(&game, "mask");
    try game.createShaderMaterial(e, textured("mask", &binding));
    try testing.expectEqual(@as(u64, 3), game.renderer.creates);
    try testing.expect(game.shaderMaterial(e) != null);
    try game.setShaderParameter(e, "u_time", &.{1});
    try testing.expectEqual(@as(usize, 0), game.renderer.destroys);
}
