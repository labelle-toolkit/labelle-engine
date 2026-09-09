/// Tests for the `Emitter` component + the particle tick's pure render
/// helpers (#750). The component's `resolvedConfig` preset selection and the
/// `packAbgr` / `particleQuad` geometry are pure and unit-testable without a
/// Game; the end-to-end tick/draw wiring is in `particles_tick_test.zig`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Emitter = engine.Emitter;
const EmitterConfig = engine.EmitterConfig;
const ptick = engine.particles_tick;

// ── Emitter.resolvedConfig ──────────────────────────────────────────────

test "resolvedConfig uses the inline config when preset is none" {
    const e: Emitter = .{ .config = .{ .rate = 99, .lifetime = 3 } };
    const cfg = e.resolvedConfig();
    try testing.expectEqual(@as(f32, 99), cfg.rate);
    try testing.expectEqual(@as(f32, 3), cfg.lifetime);
}

test "resolvedConfig selects the named preset, ignoring inline config" {
    const smoke: Emitter = .{ .preset = .smoke, .config = .{ .rate = 99 } };
    try testing.expectEqual(engine.particle_presets.smoke.rate, smoke.resolvedConfig().rate);

    const sparks: Emitter = .{ .preset = .sparks };
    try testing.expectEqual(engine.particle_presets.sparks.rate, sparks.resolvedConfig().rate);

    const rain: Emitter = .{ .preset = .rain };
    try testing.expectEqual(engine.particle_presets.rain.rate, rain.resolvedConfig().rate);
}

test "default Emitter resolves to the default EmitterConfig" {
    const e: Emitter = .{};
    const def: EmitterConfig = .{};
    try testing.expectEqual(def.rate, e.resolvedConfig().rate);
    try testing.expectEqual(def.max_particles, e.resolvedConfig().max_particles);
}

// ── packAbgr ────────────────────────────────────────────────────────────

test "packAbgr packs channels in 0xAABBGGRR order" {
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), ptick.packAbgr(.{ .r = 1, .g = 1, .b = 1, .a = 1 }));
    try testing.expectEqual(@as(u32, 0x00000000), ptick.packAbgr(.{ .r = 0, .g = 0, .b = 0, .a = 0 }));
    // Pure red, opaque: R=0xFF in the low byte, A=0xFF in the high byte.
    try testing.expectEqual(@as(u32, 0xFF0000FF), ptick.packAbgr(.{ .r = 1, .g = 0, .b = 0, .a = 1 }));
    // Pure blue: B in the 0x00BB0000 slot.
    try testing.expectEqual(@as(u32, 0xFFFF0000), ptick.packAbgr(.{ .r = 0, .g = 0, .b = 1, .a = 1 }));
}

test "packAbgr clamps out-of-range channels instead of wrapping" {
    // An alpha-ramp overshoot / over-bright colour must clamp to 0xFF, not
    // wrap the byte.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), ptick.packAbgr(.{ .r = 2, .g = 5, .b = 1.5, .a = 10 }));
    try testing.expectEqual(@as(u32, 0x00000000), ptick.packAbgr(.{ .r = -1, .g = -0.5, .b = -9, .a = -1 }));
}

// ── particleQuad ────────────────────────────────────────────────────────

test "particleQuad centres a size x size quad on the particle position" {
    const q = ptick.particleQuad(.{
        .x = 10,
        .y = 20,
        .size = 4,
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .sprite_frame = null,
    });
    // Half-size 2 around (10,20): BL(8,18) BR(12,18) TR(12,22) TL(8,22).
    try testing.expectEqualSlices(f32, &.{ 8, 18, 12, 18, 12, 22, 8, 22 }, &q.positions);
    try testing.expectEqualSlices(f32, &.{ 0, 1, 1, 1, 1, 0, 0, 0 }, &q.uvs);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), q.color);
}
