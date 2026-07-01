//! Tests for two-tier component visibility + per-pack registry partition.
//! Packs isolation model · labelle-engine #652 (umbrella #651).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const ComponentRegistry = engine.ComponentRegistry;
const Visibility = engine.Visibility;
const getVisibility = engine.getVisibility;
const PackView = engine.PackView;
const ComponentView = engine.ComponentView;

// ─── Sample components across two notional packs + a global facet ───────────

/// Global contract facet — every pack may name it.
const Locked = struct {
    pub const visibility = .global;
    by: u64 = 0,
};

/// Global facet declared with an explicit type annotation.
const Position = struct {
    pub const visibility: Visibility = .global;
    x: f32 = 0,
    y: f32 = 0,
};

/// Private to the "citizens" pack (default visibility = .pack).
const Worker = struct {
    hunger: f32 = 0,
};

/// Private to the "citizens" pack.
const Home = struct {
    capacity: u8 = 0,
};

/// Private to the "ships" pack — foreign to citizens.
const Ship = struct {
    pub const visibility = .pack;
    fuel: f32 = 0,
};

const FullRegistry = ComponentRegistry(.{
    .Locked = Locked,
    .Position = Position,
    .Worker = Worker,
    .Home = Home,
    .Ship = Ship,
});

// Each pack's resolvable registry = all globals ++ its own private components.
const CitizensView = PackView(FullRegistry, &.{ "Worker", "Home" });
const ShipsView = PackView(FullRegistry, &.{"Ship"});

// ─── Part 1: per-component visibility ───────────────────────────────────────

test "getVisibility: default is .pack (private)" {
    try testing.expectEqual(Visibility.pack, getVisibility(Worker));
    try testing.expectEqual(Visibility.pack, getVisibility(Home));
}

test "getVisibility: .global declared via enum literal" {
    try testing.expectEqual(Visibility.global, getVisibility(Locked));
}

test "getVisibility: .global declared with explicit type" {
    try testing.expectEqual(Visibility.global, getVisibility(Position));
}

test "getVisibility: explicit .pack matches the default" {
    try testing.expectEqual(Visibility.pack, getVisibility(Ship));
}

test "isGlobal helper" {
    try testing.expect(engine.isGlobalComponent(Locked));
    try testing.expect(!engine.isGlobalComponent(Worker));
}

test "globalNames lists only the global components" {
    const globals = engine.globalComponentNames(FullRegistry);
    try testing.expectEqual(@as(usize, 2), globals.len);
    // Order follows FullRegistry.names() — Locked then Position.
    try testing.expectEqualStrings("Locked", globals[0]);
    try testing.expectEqualStrings("Position", globals[1]);
}

// ─── Part 2: per-pack partition view ────────────────────────────────────────

test "PackView resolves the pack's own private components" {
    try testing.expect(CitizensView.has("Worker"));
    try testing.expect(CitizensView.has("Home"));
    try testing.expect(Worker == CitizensView.getType("Worker"));
    try testing.expect(Home == CitizensView.getType("Home"));
}

test "PackView resolves all .global components" {
    try testing.expect(CitizensView.has("Locked"));
    try testing.expect(CitizensView.has("Position"));
    try testing.expect(Locked == CitizensView.getType("Locked"));
    // Globals are visible to every pack, including the ships pack.
    try testing.expect(ShipsView.has("Locked"));
    try testing.expect(Position == ShipsView.getType("Position"));
}

test "PackView: foreign-private names miss (escape hole closed)" {
    // citizens cannot see the ships pack's private component...
    try testing.expect(!CitizensView.has("Ship"));
    try testing.expect(!CitizensView.isAllowed("Ship"));
    // ...and vice-versa.
    try testing.expect(!ShipsView.has("Worker"));
    try testing.expect(!ShipsView.has("Home"));
    try testing.expect(!ShipsView.isAllowed("Worker"));

    // The full/global registry is UNCHANGED — it still resolves every name
    // (this is what the serializer + ECS use).
    try testing.expect(FullRegistry.has("Ship"));
    try testing.expect(FullRegistry.has("Worker"));
}

test "ComponentView.names returns the visible, defined names" {
    const names = CitizensView.names();
    // 2 globals (Locked, Position) + 2 own (Worker, Home).
    try testing.expectEqual(@as(usize, 4), names.len);

    var saw_worker = false;
    var saw_ship = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "Worker")) saw_worker = true;
        if (std.mem.eql(u8, n, "Ship")) saw_ship = true;
    }
    try testing.expect(saw_worker);
    try testing.expect(!saw_ship);
}

// ─── entityHasNamed dispatches through the view ─────────────────────────────

const StubEcs = struct {
    /// Pretend every queried entity has every type it is asked about.
    pub fn hasComponent(self: @This(), entity: u32, comptime T: type) bool {
        _ = self;
        _ = entity;
        _ = T;
        return true;
    }
};

test "entityHasNamed resolves an allowed name through the view" {
    const ecs = StubEcs{};
    try testing.expect(CitizensView.entityHasNamed(ecs, @as(u32, 1), "Worker"));
    try testing.expect(CitizensView.entityHasNamed(ecs, @as(u32, 1), "Locked"));
}

// ─── Documented compile-error case (the escape closure) ─────────────────────
//
// Resolving a foreign-private name through a partitioned view is a COMPILE
// ERROR — the demonstration cannot live in a passing test, so it is captured
// here as a commented case. Uncommenting any line below makes `zig build test`
// fail at comptime with:
//   "Component 'Ship' is not visible to this pack (foreign-private or unknown)."
//
//   _ = CitizensView.getType("Ship");
//   _ = CitizensView.entityHasNamed(StubEcs{}, @as(u32, 1), "Ship");
//
// The runtime-friendly negative path is exercised above via `has()` /
// `isAllowed()` returning false.

test "view over the full registry with an empty allow-list resolves nothing" {
    const Empty = ComponentView(FullRegistry, &.{});
    try testing.expect(!Empty.has("Worker"));
    try testing.expect(!Empty.has("Locked"));
    try testing.expectEqual(@as(usize, 0), Empty.names().len);
}
