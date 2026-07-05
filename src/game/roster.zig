//! Roster cache (#653, Packs Phase 2 / #657) — the engine-owned,
//! generation-invalidated `entitiesWith` cache, extracted from
//! `game.zig` (facade split; same Mixin(Game) idiom as its siblings).
//!
//! `entitiesWith(includes)` returns a slice **borrowed from an
//! engine-owned cache**. The slice is valid only until the next
//! structural mutation (component add/remove, entity create/destroy,
//! world switch / ECS reset) — callers must NOT free it, and must
//! **copy** it if they need to retain it past such a mutation.
//! Repeated reads of the same tag-set within a mutation-free window
//! return the cached slice without re-scanning the ECS; the first
//! read after a mutation lazily re-queries.
//!
//! Slots live in a hash map keyed by the comptime tag-set hash
//! (`rosterKey`). The key space is statically bounded (every key is a
//! comptime constant), so the map **never evicts**: a slot's buffer
//! is only ever rewritten for the SAME tag-set after a generation
//! bump. That is precisely what makes the borrowed-slice contract
//! sound — within a mutation-free window the slice is stable **no
//! matter how many other tag-sets are queried** (the #657 fix; the
//! old fixed-slot design used a fixed 8-slot array with round-robin
//! eviction, which mutated a still-borrowed buffer during an
//! unrelated read once more than 8 tag-sets were live — a
//! lifetime-contract violation the map design removes).
//!
//! On OOM the read logs and returns a truncated roster, leaving the
//! entry `valid = false` so the next read retries the full query
//! rather than treating the partial result as fresh.
//!
//! This backs the Packs query-surface caching (e.g.
//! `citizens.idleWorkers()` borrows from here) and the
//! "borrowed-slice" lifetime contract for list-returning queries —
//! they hand back this cached slice rather than a caller-owned
//! `collectEntities` allocation.

const std = @import("std");

/// One cached roster. `Game` owns two pieces of state for the cache:
/// `roster_generation` (the epoch) and `roster_cache`
/// (`AutoHashMap(u64, Slot(Entity))`) — both declared as fields in
/// `game.zig`, freed in the lifecycle mixin's `deinit`.
pub fn Slot(comptime Entity: type) type {
    return struct {
        /// `roster_generation` value at which `list` was filled.
        gen: u64 = 0,
        /// False until first filled (or after an OOM during refill).
        valid: bool = false,
        /// Borrowed-out collection; owned by `Game`, freed in `deinit`.
        list: std.ArrayList(Entity) = .empty,
    };
}

/// Returns the roster mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;

    return struct {
        /// `includes` mirrors the include tuple of `collectEntities`
        /// (e.g. `.{Health}` or `.{Health, Velocity}`); the exclude
        /// set is always empty for rosters. See the module header for
        /// the borrowed-slice lifetime contract.
        pub fn entitiesWith(self: *Game, comptime includes: anytype) []const Entity {
            const key = comptime rosterKey(includes);
            // A rehash while inserting a new key moves slot *values*,
            // but borrowed slices point at each list's heap buffer,
            // not the slot struct — so never hold `value_ptr` across
            // another `roster_cache` operation (this fn doesn't).
            const gop = self.roster_cache.getOrPut(key) catch |err| {
                // OOM growing the map itself: there is no slot to fill,
                // so hand back a static empty roster (not borrowed).
                self.log.err("[Game] entitiesWith: roster cache OOM for key {d}: {s}", .{ key, @errorName(err) });
                return &[_]Entity{};
            };
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const slot = gop.value_ptr;
            // Cache hit: this tag-set's slot, filled at the current epoch.
            if (slot.valid and slot.gen == self.roster_generation) {
                return slot.list.items;
            }
            // Stale or never filled — re-query. This slot belongs to
            // `key` forever, so its buffer is never rewritten on behalf
            // of a different tag-set.
            slot.list.clearRetainingCapacity();
            slot.valid = false;
            var view = self.ecs_backend.view(includes, .{});
            defer view.deinit();
            while (view.next()) |ent| {
                slot.list.append(self.allocator, ent) catch |err| {
                    // OOM mid-fill: leave the slot invalid so the next
                    // read retries the full query rather than handing
                    // back a truncated roster as if it were fresh. Log
                    // it — the truncated slice we hand back this frame
                    // is otherwise indistinguishable from a genuinely
                    // small roster, so a silent miss would be very hard
                    // to diagnose.
                    self.log.err("[Game] entitiesWith: roster refill OOM for key {d}: {s}", .{ key, @errorName(err) });
                    return slot.list.items;
                };
            }
            slot.gen = self.roster_generation;
            slot.valid = true;
            return slot.list.items;
        }

        /// Comptime hash identifying a tag-set by the concatenation of
        /// its component type names. The names are sorted alphabetically
        /// before hashing, so `entitiesWith(.{A, B})` and
        /// `entitiesWith(.{B, A})` produce the same key and share a
        /// single cache slot instead of thrashing two.
        fn rosterKey(comptime includes: anytype) u64 {
            comptime {
                var names: [includes.len][]const u8 = undefined;
                for (includes, 0..) |T, i| {
                    names[i] = @typeName(T);
                }
                // Insertion sort — tag-sets are tiny (a handful of
                // components), and this runs entirely at comptime.
                for (1..names.len) |i| {
                    var j = i;
                    while (j > 0 and std.mem.order(u8, names[j - 1], names[j]) == .gt) : (j -= 1) {
                        const tmp = names[j - 1];
                        names[j - 1] = names[j];
                        names[j] = tmp;
                    }
                }
                var h = std.hash.Wyhash.init(0);
                for (names) |name| {
                    h.update(name);
                    h.update("\x00");
                }
                return h.final();
            }
        }

        /// Invalidate every cached roster by advancing the epoch. Cheap
        /// (one add); called from every structural-mutation path (the
        /// entity / component / world / visual mixins) so the next
        /// `entitiesWith` read re-queries. Capacity in each slot's
        /// list is retained for reuse.
        pub inline fn bumpRoster(self: *Game) void {
            self.roster_generation +%= 1;
        }
    };
}
