//! zspec BDD specs for the shared entity-tree walker (RFC #560,
//! ticket #569).
//!
//! The walker is the single traversal entry point every entity-tree
//! consumer (instantiation, save/load tagging, postLoad firing,
//! asset inference) shares. These specs pin:
//!
//!  - the normative pre-order walk crossing BOTH `children` AND
//!    prefab references nested in entity-bearing component fields
//!    (the `Room.movement_nodes` pattern),
//!  - prefab-reference expansion through a resolver,
//!  - cycle detection reporting the FULL chain (`A -> B -> A`), for
//!    a direct self-cycle and a multi-hop cycle.
//!
//! See RFC-UNIFY-SCENES-AND-PREFABS.md.

const std = @import("std");
const zspec = @import("zspec");
const engine = @import("engine");

const expect = zspec.expect;
const Fixture = zspec.Fixture;

const tw = engine.tree_walker;
const Value = engine.SceneValue;
const JsoncParser = engine.JsoncParser;

// ── A static prefab table standing in for PrefabCache ───────────
//
// The walker resolves `prefab` names through a `Resolver`; in
// production that is `PrefabCache.get`. The specs back it with a
// parse-on-demand table over a fixed JSONC corpus so a walk can be
// exercised without the full scene-loader machinery.

const PrefabTable = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMap(Value),

    fn init(allocator: std.mem.Allocator) PrefabTable {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = std.StringHashMap(Value).init(allocator),
        };
    }

    fn deinit(self: *PrefabTable) void {
        self.entries.deinit();
        self.arena.deinit();
    }

    /// Parse `source` and register it under `name`.
    fn add(self: *PrefabTable, name: []const u8, source: []const u8) !void {
        var parser = JsoncParser.init(self.arena.allocator(), source);
        const val = try parser.parse();
        try self.entries.put(name, val);
    }

    fn get(ctx: *anyopaque, name: []const u8) ?Value {
        const self: *PrefabTable = @ptrCast(@alignCast(ctx));
        return self.entries.get(name);
    }

    fn resolver(self: *PrefabTable) tw.Resolver {
        return .{ .ctx = self, .getFn = &PrefabTable.get };
    }
};

/// Parse a single JSONC source into a `Value` in `arena`.
fn parse(arena: std.mem.Allocator, source: []const u8) !Value {
    var parser = JsoncParser.init(arena, source);
    return parser.parse();
}

// ── A recording visitor ─────────────────────────────────────────
//
// Captures every visited node so a test can assert on the count,
// the walk order, and each node's origin / depth / component name.

const Visit = struct {
    origin: tw.Origin,
    depth: usize,
    component_name: ?[]const u8,
    has_prefab_root: bool,
    /// The visited entity's `Marker.id`, or `null` when it carries
    /// no inline `Marker` — a cheap identity probe for ordering
    /// assertions. Prefab-sourced markers are not visible here
    /// (the walker yields the *reference* entry, not the resolved
    /// prefab body).
    marker_id: ?i64,
};

const Recorder = struct {
    pub const VisitError = error{OutOfMemory};

    list: *std.ArrayList(Visit),
    allocator: std.mem.Allocator,

    pub fn visit(self: Recorder, node: tw.Node(VisitError)) VisitError!void {
        var marker_id: ?i64 = null;
        if (node.obj.getObject("components")) |c| {
            if (c.getObject("Marker")) |m| marker_id = m.getInteger("id");
        }
        try self.list.append(self.allocator, .{
            .origin = node.origin,
            .depth = node.depth,
            .component_name = node.component_name,
            .has_prefab_root = node.prefab_root != null,
            .marker_id = marker_id,
        });
    }
};

// ── JSONC corpus ────────────────────────────────────────────────

const Sources = struct {
    /// Entity with two `children`.
    parent_two_children: []const u8,
    /// Entity whose `Room` component carries a `movement_nodes`
    /// entity-bearing array — the second structural birth-place.
    room_with_nodes: []const u8,
    /// A leaf prefab body.
    leaf_prefab: []const u8,
    /// A prefab that references itself directly (`self -> self`).
    self_cycle_prefab: []const u8,
    /// Two prefabs forming a `chain_a -> chain_b -> chain_a` cycle.
    chain_a_prefab: []const u8,
    chain_b_prefab: []const u8,
};

const Corpus = Fixture.define(Sources, .{
    .parent_two_children =
    \\{ "components": { "Marker": { "id": 1 } }, "children": [
    \\  { "components": { "Marker": { "id": 2 } } },
    \\  { "components": { "Marker": { "id": 3 } } }
    \\] }
    ,
    .room_with_nodes =
    \\{ "components": { "Room": { "movement_nodes": [
    \\  { "components": { "Marker": { "id": 10 } } },
    \\  { "prefab": "leaf" }
    \\] } } }
    ,
    .leaf_prefab =
    \\{ "root": { "components": { "Marker": { "id": 99 } } } }
    ,
    .self_cycle_prefab =
    \\{ "root": { "components": { "Marker": { "id": 1 } },
    \\  "children": [ { "prefab": "self" } ] } }
    ,
    .chain_a_prefab =
    \\{ "root": { "children": [ { "prefab": "chain_b" } ] } }
    ,
    .chain_b_prefab =
    \\{ "root": { "children": [ { "prefab": "chain_a" } ] } }
    ,
});

/// A resolver that knows no prefabs — for inline-only walks.
fn emptyResolver() tw.Resolver {
    const Empty = struct {
        fn get(_: *anyopaque, _: []const u8) ?Value {
            return null;
        }
    };
    var dummy: u8 = 0;
    return .{ .ctx = &dummy, .getFn = &Empty.get };
}

pub const TreeWalkerSpec = struct {
    var arena: std.heap.ArenaAllocator = undefined;

    test "tests:before" {
        arena = std.heap.ArenaAllocator.init(zspec.allocator);
    }

    test "tests:after" {
        arena.deinit();
    }

    // ── crossing the `children` array ───────────────────────────

    pub const @"walking an entity with a children array" = struct {
        test "visits the root pre-order then every child" {
            const a = arena.allocator();
            const src = Corpus.create(.{});
            const root = try parse(a, src.parent_two_children);

            var visits: std.ArrayList(Visit) = .empty;
            var ctx = tw.WalkContext.init(a);
            defer ctx.deinit();

            try tw.walk(&ctx, emptyResolver(), root, Recorder{ .list = &visits, .allocator = a });

            try expect.equal(visits.items.len, 3);
            // Pre-order: root first.
            try expect.equal(visits.items[0].origin, tw.Origin.root);
            try expect.equal(visits.items[0].marker_id.?, @as(i64, 1));
            // Then each child, in array order, at depth 1.
            try expect.equal(visits.items[1].origin, tw.Origin.child);
            try expect.equal(visits.items[1].depth, @as(usize, 1));
            try expect.equal(visits.items[1].marker_id.?, @as(i64, 2));
            try expect.equal(visits.items[2].marker_id.?, @as(i64, 3));
        }
    };

    // ── crossing entity-bearing component fields ────────────────

    pub const @"walking prefab refs nested in component fields" = struct {
        test "crosses a Room.movement_nodes entity array" {
            const a = arena.allocator();
            const src = Corpus.create(.{});

            var table = PrefabTable.init(a);
            defer table.deinit();
            try table.add("leaf", src.leaf_prefab);

            const root = try parse(a, src.room_with_nodes);

            var visits: std.ArrayList(Visit) = .empty;
            var ctx = tw.WalkContext.init(a);
            defer ctx.deinit();

            try tw.walk(&ctx, table.resolver(), root, Recorder{ .list = &visits, .allocator = a });

            // Root Room entity + two movement_nodes entries.
            try expect.equal(visits.items.len, 3);
            try expect.equal(visits.items[0].origin, tw.Origin.root);

            // The nested inline entity is reached via the component
            // field and attributed to the `Room` component.
            try expect.equal(visits.items[1].origin, tw.Origin.component_field);
            try expect.equal(visits.items[1].component_name.?, @as([]const u8, "Room"));
            try expect.equal(visits.items[1].marker_id.?, @as(i64, 10));

            // The nested *prefab reference* is crossed too and its
            // prefab resolved.
            try expect.equal(visits.items[2].origin, tw.Origin.component_field);
            try expect.toBeTrue(visits.items[2].has_prefab_root);
        }
    };

    // ── cycle detection ─────────────────────────────────────────

    pub const @"a direct self-referential prefab cycle" = struct {
        test "errors with the full chain self -> self" {
            const a = arena.allocator();
            const src = Corpus.create(.{});

            var table = PrefabTable.init(a);
            defer table.deinit();
            try table.add("self", src.self_cycle_prefab);

            // A scene-level reference entry to the cyclic prefab.
            var ref_entries = [_]Value.Object.Entry{
                .{ .key = "prefab", .value = .{ .string = "self" } },
            };
            const ref = Value{ .object = .{ .entries = &ref_entries } };

            var visits: std.ArrayList(Visit) = .empty;
            var ctx = tw.WalkContext.init(a);
            defer ctx.deinit();

            const result = tw.walk(&ctx, table.resolver(), ref, Recorder{ .list = &visits, .allocator = a });
            try expect.toReturnError(result, error.PrefabCycle);

            const chain = try ctx.formatCycleChain(a);
            try expect.equal(chain, @as([]const u8, "self -> self"));
        }
    };

    pub const @"a multi-hop prefab cycle" = struct {
        test "errors with the full chain chain_a -> chain_b -> chain_a" {
            const a = arena.allocator();
            const src = Corpus.create(.{});

            var table = PrefabTable.init(a);
            defer table.deinit();
            try table.add("chain_a", src.chain_a_prefab);
            try table.add("chain_b", src.chain_b_prefab);

            var ref_entries = [_]Value.Object.Entry{
                .{ .key = "prefab", .value = .{ .string = "chain_a" } },
            };
            const ref = Value{ .object = .{ .entries = &ref_entries } };

            var visits: std.ArrayList(Visit) = .empty;
            var ctx = tw.WalkContext.init(a);
            defer ctx.deinit();

            const result = tw.walk(&ctx, table.resolver(), ref, Recorder{ .list = &visits, .allocator = a });
            try expect.toReturnError(result, error.PrefabCycle);

            const chain = try ctx.formatCycleChain(a);
            try expect.equal(chain, @as([]const u8, "chain_a -> chain_b -> chain_a"));
        }
    };

    pub const @"an acyclic prefab tree" = struct {
        test "walks to completion without a cycle error" {
            const a = arena.allocator();
            const src = Corpus.create(.{});

            var table = PrefabTable.init(a);
            defer table.deinit();
            try table.add("leaf", src.leaf_prefab);

            var ref_entries = [_]Value.Object.Entry{
                .{ .key = "prefab", .value = .{ .string = "leaf" } },
            };
            const ref = Value{ .object = .{ .entries = &ref_entries } };

            var visits: std.ArrayList(Visit) = .empty;
            var ctx = tw.WalkContext.init(a);
            defer ctx.deinit();

            try tw.walk(&ctx, table.resolver(), ref, Recorder{ .list = &visits, .allocator = a });
            // One visit: the reference entry, with its prefab resolved.
            try expect.equal(visits.items.len, 1);
            try expect.toBeTrue(visits.items[0].has_prefab_root);
        }
    };
};
