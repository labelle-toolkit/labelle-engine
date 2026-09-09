/// Animation-runtime mixin — runtime `AnimationDef` overrides on a live
/// game (labelle-engine#672 driver seam, labelle-studio Play mode).
///
/// The comptime `AnimationDef` path bakes clip tables into the binary;
/// this mixin lets a host push a re-parsed `.zon` def into the RUNNING
/// game and have live animation components pick the new numbers up. It is
/// the engine half of the studio's `_editor_load_animation_def` hot-push
/// (`editor_api.zig` dispatches here); a desktop host loop watching file
/// mtimes (`ReloadWatcher`) can call the same `loadAnimationDefSource`.
///
/// ## How live entities are found — the `anim_def_name` convention
///
/// The engine can't know which game component mirrors which def (the
/// binding is a comptime `@import` in game code). A game component opts
/// in by declaring the def it was generated from:
///
/// ```zig
/// pub const AnimationState = struct {
///     pub const anim_def_name = "worker"; // animations/worker.zon
///     clip: Clip = .idle,   // u8 or enum — both refresh
///     ...
/// };
/// ```
///
/// On every successful `loadAnimationDefSource("worker", src)`, all
/// registered components whose `anim_def_name` matches are walked and
/// `refreshState`-ed (stale `frame_count`/`speed`/`mode` copies re-read,
/// out-of-range `clip`/`variant`/`frame` clamped, `dirty` set). Declaring
/// `anim_def_name` opts the component into `refreshState`'s duck-type
/// contract (`.clip/.variant/.frame/.frame_count/.speed/.mode/.dirty`).
/// Components without the decl are never touched, and a game with no
/// opted-in components compiles this walk away entirely.
///
/// ## What the game must still do itself
///
/// The refresh updates STATE; sprite-name resolution and transition
/// metadata still come from wherever the game reads them. For reloaded
/// numbers to survive the next `transition`, game code consults
/// `runtimeAnimDef(name)` (falling back to its comptime table) — the
/// `AnimDefSource` seam. Games that don't are still refreshed in place,
/// but revert to comptime numbers on their next clip switch.
const std = @import("std");
const animation_def_runtime = @import("../animation_def_runtime.zig");

/// Returns the animation-runtime mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        /// Parse a `.zon` animation-def source and install it as the
        /// runtime override for `name` (the def's stem, `"worker"` for
        /// `animations/worker.zon`), then refresh every live component
        /// that declares `anim_def_name == name`. On a parse/validation
        /// error NOTHING changes — the previous override (or the
        /// comptime table) stays live, so a half-saved file never
        /// corrupts a running preview. `name` and `source` are copied;
        /// the caller may free both immediately.
        pub fn loadAnimationDefSource(self: *Game, name: []const u8, source: []const u8) !void {
            var def = try animation_def_runtime.RuntimeAnimationDef.load(self.allocator, source);
            errdefer def.deinit();
            try self.runtime_anim_defs.put(name, def);
            refreshAnimationStates(self, name);
        }

        /// The live runtime override for `name`, or null when nothing
        /// was pushed. Game code resolving sprite names / transition
        /// metadata should prefer this over its comptime table when
        /// present (the `AnimDefSource` seam). The borrow stays valid
        /// until `deinit` — see `RuntimeAnimDefs`' graveyard note.
        pub fn runtimeAnimDef(self: *const Game, name: []const u8) ?*const animation_def_runtime.RuntimeAnimationDef {
            return self.runtime_anim_defs.get(name);
        }

        /// Re-sync every live component whose `anim_def_name` decl
        /// matches `name` against the current runtime override (no-op
        /// when none is installed). Called by `loadAnimationDefSource`;
        /// public so hosts with their own reload plumbing can re-run it.
        pub fn refreshAnimationStates(self: *Game, name: []const u8) void {
            const def = self.runtime_anim_defs.get(name) orelse return;
            const Registry = Game.ComponentRegistry;
            if (comptime !@hasDecl(Registry, "names")) return;
            inline for (comptime Registry.names()) |cname| {
                const C = Registry.getType(cname);
                if (comptime animDefNameOf(C)) |def_name| {
                    if (std.mem.eql(u8, def_name, name)) {
                        var view = self.ecs_backend.view(.{C}, .{});
                        defer view.deinit();
                        while (view.next()) |entity| {
                            if (self.ecs_backend.getComponent(entity, C)) |state| {
                                animation_def_runtime.refreshState(state, def);
                            }
                        }
                    }
                }
            }
        }

        /// The def name a component opted into via `pub const
        /// anim_def_name`, or null (= never refreshed).
        fn animDefNameOf(comptime C: type) ?[]const u8 {
            if (@typeInfo(C) != .@"struct") return null;
            if (!@hasDecl(C, "anim_def_name")) return null;
            return C.anim_def_name;
        }
    };
}
