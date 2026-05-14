//! Tests for the flow-codegen-facing slice of `Game`'s API
//! (labelle-toolkit/labelle-gui#96):
//!
//!   - `getComponent(entity, comptime T) ?*T`
//!   - `setField(comptime T, comptime field, entity, value)`
//!   - `game.preview` reachable as an optional Preview by-value
//!
//! These are the exact shapes the codegen in
//! `labelle-gui/flow-codegen/src/codegen.zig` emits, e.g.:
//!
//!     const n0_value = game.getComponent(entity, Position) orelse return;
//!     game.setField(Position, .x, entity, 7);
//!     if (game.preview) |*_p| {
//!         _p.emitNodeEntered("flow_name", 1) catch {};
//!     }
//!
//! The tests use the in-tree `Game = GameWith(void)` (MockEcsBackend +
//! StubRender) so they don't need a real ECS plugin wired up.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;
const Preview = engine.preview_mode_mod.Preview;

// Loopback harness — minimal echo of what `preview_mode_test.zig`
// uses, kept private here so this test file is self-contained.
const LoopbackHarness = struct {
    server: std.net.Server,
    port: u16,
    conn: ?std.net.Server.Connection = null,

    fn init() !LoopbackHarness {
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        var server = try addr.listen(.{ .reuse_address = true });
        const port = server.listen_address.getPort();
        return .{ .server = server, .port = port };
    }

    fn deinit(self: *LoopbackHarness) void {
        if (self.conn) |*c| c.stream.close();
        self.server.deinit();
    }

    fn hostPort(self: *LoopbackHarness, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "127.0.0.1:{d}", .{self.port});
    }

    fn accept(self: *LoopbackHarness) !void {
        self.conn = try self.server.accept();
    }
};

// ── getComponent ─────────────────────────────────────────────────

test "getComponent: returns null when entity has no component of T" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const entity = game.createEntity();

    // No addComponent before the read — the storage is empty for T.
    try testing.expectEqual(@as(?*Tag, null), game.getComponent(entity, Tag));
}

test "getComponent: returns a pointer to the component when present" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const entity = game.createEntity();
    game.addComponent(entity, Tag{ .label = 42 });

    const got = game.getComponent(entity, Tag);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u32, 42), got.?.label);

    // The pointer aliases storage — a write through it must be
    // observable on the next read. This pins down the `?*T` shape
    // the codegen relies on.
    got.?.label = 99;
    try testing.expectEqual(@as(u32, 99), game.getComponent(entity, Tag).?.label);
}

// ── setField ────────────────────────────────────────────────────

test "setField: updates the named field in place; getComponent reads the new value" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Vec = struct { x: f32, y: f32 };
    const entity = game.createEntity();
    game.addComponent(entity, Vec{ .x = 1.0, .y = 2.0 });

    game.setField(Vec, .x, entity, 9.0);

    const v = game.getComponent(entity, Vec).?;
    try testing.expectEqual(@as(f32, 9.0), v.x);
    // Sibling field untouched — `setField` writes exactly one field.
    try testing.expectEqual(@as(f32, 2.0), v.y);
}

test "setField: on entity without component is a silent no-op" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const entity = game.createEntity();
    // No `addComponent(entity, Tag{...})` — entity lacks T.

    // Must not crash, must not magically materialize a component.
    game.setField(Tag, .label, entity, 7);

    try testing.expectEqual(@as(?*Tag, null), game.getComponent(entity, Tag));
}

test "setField: codegen-style call (game.setField(T, .field, entity, value))" {
    // Exact shape `labelle-gui/flow-codegen/src/codegen.zig` emits
    // for a SetField node — pinning it down as a regression guard
    // for the API contract.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Position = struct { x: f32, y: f32 };
    const entity = game.createEntity();
    game.addComponent(entity, Position{ .x = 0, .y = 0 });

    const n4_value: f32 = 12.5;
    game.setField(Position, .x, entity, n4_value);

    try testing.expectEqual(@as(f32, 12.5), game.getComponent(entity, Position).?.x);
}

// ── preview accessor ────────────────────────────────────────────

test "preview: game.preview is null when preview mode is off" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Default-constructed Game has no preview channel; the codegen's
    // `if (game.preview)` guard short-circuits and no socket work
    // happens in production builds.
    try testing.expect(game.preview == null);
}

test "preview: codegen pattern `if (game.preview) |*_p| _p.emitNodeEntered(...)` resolves" {
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);

    var game = Game.init(testing.allocator);
    defer game.deinit();

    // The repo's convention is direct field assignment — `Game.deinit`
    // owns the channel by value once set (see `preview_mode_test.zig`).
    game.preview = try Preview.connect(testing.allocator, host_port);
    try harness.accept();

    try testing.expect(game.preview != null);

    // Exercise the exact `|*_p|` capture the codegen emits. The
    // `catch {}` mirrors the generated code's failure-swallowing
    // contract: a closed editor socket must never crash gameplay.
    if (game.preview) |*_p| {
        _p.emitNodeEntered("flow_name", 1) catch {};
    }
}
