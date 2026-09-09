//! Cycle detection for the scene/prefab loader (RFC #569).
//!
//! Extracted from `scene_loader.zig` (slice of the <1000-line split).
//! Runs the shared `tree_walker` purely for its cycle detector: a
//! referenced-prefab cycle (`A -> B -> A`) is a load-time error.
//!
//! `CycleDetect` is parameterized by the same `GameType`/`Components`
//! as the parent `SceneLoader`, plus the parent `Self` type so it can
//! read `Self.LoadEntityError` / `Self.MAX_DEPTH`. Behavior is
//! identical to the inlined version — only the source location moved.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;

const prefab_cache_mod = @import("../prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;
const tree_walker = @import("../tree_walker.zig");

/// Adapt a `PrefabCache` into a `tree_walker.Resolver`. The walker
/// expands `prefab` references through this so its cycle detector
/// sees the same reference graph the instantiation pass does.
pub fn prefabResolver(cache: *PrefabCache) tree_walker.Resolver {
    const Wrap = struct {
        fn get(ctx: *anyopaque, name: []const u8) ?Value {
            const c: *PrefabCache = @ptrCast(@alignCast(ctx));
            return c.get(name);
        }
    };
    return .{ .ctx = cache, .getFn = &Wrap.get };
}

/// A walker visitor that does nothing — used when the only thing a
/// walk needs to surface is cycle detection (the walker raises
/// `error.PrefabCycle` on its own; the visitor never has to act).
pub const CycleCheckVisitor = struct {
    pub const VisitError = error{};
    pub fn visit(_: CycleCheckVisitor, _: tree_walker.Node(VisitError)) VisitError!void {}
};

pub fn CycleDetect(comptime GameType: type, comptime Components: type, comptime Self: type) type {
    _ = Components;
    return struct {
        /// Run the shared entity-tree walker over `entity_value`
        /// purely for its cycle detector. A referenced-prefab cycle
        /// (`A -> B -> A`) is a load-time error: the full chain is
        /// logged and `error.PrefabCycle` propagates so the loader
        /// aborts before instantiating a tree that would recurse
        /// forever. Both inference (static) and instantiation
        /// (runtime) gate on this shared check.
        pub fn checkEntityTreeCycles(
            game: *GameType,
            entity_value: Value,
            prefab_cache: *PrefabCache,
            ctx: *tree_walker.WalkContext,
        ) Self.LoadEntityError!void {
            // Track the loader's recursion limit so the walk fails
            // with the same depth ceiling `loadEntityInternal` does
            // — a tree the loader would reject as too deep is
            // surfaced here as `IncludeDepthExceeded`, not silently
            // walked.
            ctx.max_depth = Self.MAX_DEPTH;
            tree_walker.walk(ctx, prefabResolver(prefab_cache), entity_value, CycleCheckVisitor{}) catch |err| switch (err) {
                error.PrefabCycle => {
                    // `formatCycleChain` either returns an
                    // allocator-owned slice (success) or raises
                    // `OutOfMemory`. Use an optional to signal which
                    // one, rather than a literal-string fallback —
                    // a string-equality probe to decide whether to
                    // free is brittle (and just happens to work
                    // because no real chain is "<unknown>").
                    const chain_opt: ?[]const u8 = ctx.formatCycleChain(game.allocator) catch null;
                    defer if (chain_opt) |c| game.allocator.free(c);
                    const chain = chain_opt orelse "<unknown>";
                    game.log.err("[scene] prefab reference cycle: {s} (RFC #560, #569)", .{chain});
                    return error.PrefabCycle;
                },
                error.DepthExceeded => return error.IncludeDepthExceeded,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    };
}
