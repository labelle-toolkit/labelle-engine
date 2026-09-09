//! Save/Load common helpers — shared by the save and load directions.
//!
//! Extracted verbatim from `save_load_mixin.zig`; behaviour is identical.
//! Holds the format version plus the three helpers used by BOTH the
//! `save.zig` writer and the `load.zig` reader (entity-id widening,
//! registry-identity guard, view collection). Keeping them here — rather
//! than duplicating per direction — is what preserves the save/load
//! symmetry these guards depend on. The `save`/`load` mixins reach these
//! through `Common.<fn>` after instantiating this mixin against the same
//! `Game` (the same idiom `loop_mixin` uses for `AtlasMixin`).

const std = @import("std");
const core = @import("labelle-core");

/// Save-file format version. Shared: the writer stamps it, the reader
/// validates it, so it lives on the common seam between the two.
pub const SAVE_VERSION: u32 = 2;

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Reg = Game.ComponentRegistry;

    return struct {
        pub fn entityToU64(entity: Entity) u64 {
            return @intCast(entity);
        }

        /// `true` when `T` is registered in the game's
        /// `ComponentRegistry`. The built-in save/load channel for
        /// engine-defined components (`Position`, `Parent`,
        /// `PrefabInstance`, `PrefabChild`) guards on the negation
        /// of this so a game that decides to register one of them
        /// directly doesn't end up with duplicate JSON keys (the
        /// registry-driven path would also emit that component).
        pub fn isRegistered(comptime T: type) bool {
            const names = comptime Reg.names();
            inline for (names) |name| {
                if (Reg.getType(name) == T) return true;
            }
            return false;
        }

        /// Collect entities from a view into an ArrayList, closing the view after.
        ///
        /// Local convenience over the public `Game.collectEntities`
        /// (game.zig). save/load callers reach the ecs backend
        /// directly (no `Game` handle in scope), so this thin
        /// wrapper keeps the same single-type signature while the
        /// shape stays identical to the public helper.
        pub fn collectEntities(comptime T: type, ecs: anytype, allocator: std.mem.Allocator) !std.ArrayList(Entity) {
            var buf: std.ArrayList(Entity) = .empty;
            errdefer buf.deinit(allocator);
            var view = ecs.view(.{T}, .{});
            defer view.deinit();
            while (view.next()) |ent| {
                try buf.append(allocator, ent);
            }
            return buf;
        }
    };
}
