//! Hook Types
//!
//! Rich hook payload union for engine lifecycle events.
//! Extends the basic EngineHookPayload from labelle-core with
//! scene lifecycle and component lifecycle hooks.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Full hook payload union for the engine.
/// Games can use this with HookDispatcher for rich lifecycle events.
pub fn HookPayload(comptime Entity: type) type {
    return union(enum) {
        // Game lifecycle
        game_init: GameInitInfo,
        game_deinit: void,
        frame_start: FrameInfo,
        frame_end: FrameInfo,
        fixed_update: FixedUpdateInfo,

        // Scene lifecycle
        scene_before_reset: SceneInfo,
        scene_before_load: SceneBeforeLoadInfo,
        scene_load: SceneInfo,
        scene_unload: SceneInfo,
        scene_assets_acquire: SceneAssetsInfo,
        scene_assets_release: SceneAssetsInfo,

        // State lifecycle
        state_before_change: StateChangeInfo,
        state_after_change: StateChangeInfo,

        // Pause lifecycle
        pause_changed: PauseChangedInfo,

        // Entity lifecycle
        entity_created: EntityInfo(Entity),
        entity_destroyed: EntityInfo(Entity),
    };
}

pub const GameInitInfo = struct {
    allocator: Allocator,
};

pub const FrameInfo = struct {
    frame_number: u64 = 0,
    dt: f32 = 0,
};

/// Payload for `fixed_update` — emitted once per fixed-timestep step the
/// accumulator runs inside a single `tick` (#751). Unlike `frame_start` /
/// `frame_end` (which fire once per rendered frame on the variable dt),
/// `fixed_update` fires 0..N times per frame at a stable `dt` so
/// determinism-sensitive logic (physics, lockstep sim) advances on a fixed
/// clock decoupled from render rate. `step_index` is the monotonic global
/// fixed-step counter (never reset across frames) — handy for lockstep /
/// state-hash assertions. `dt` is the fixed step (`Game.fixed_dt`).
pub const FixedUpdateInfo = struct {
    step_index: u64 = 0,
    dt: f32 = 0,
};

pub const SceneBeforeLoadInfo = struct {
    name: []const u8,
    allocator: Allocator,
};

pub const SceneInfo = struct {
    name: []const u8,
};

/// Payload for `scene_assets_acquire` / `scene_assets_release`. `assets`
/// is the manifest attached to the scene entry — listeners can read it
/// without a `scenes.get(name)` lookup. Slice lifetime matches the
/// `SceneEntry.assets` slice (program-lifetime when populated by the
/// assembler).
pub const SceneAssetsInfo = struct {
    name: []const u8,
    assets: []const []const u8,
};

pub const StateChangeInfo = struct {
    old_state: []const u8,
    new_state: []const u8,
};

/// Payload for `pause_changed` — emitted by `Game.setPaused` when the
/// pause flag actually changes value. Plugin-shipped scripts gate on
/// `game.isPaused()` directly; this hook is for game/system code that
/// wants to react to the transition (e.g. fade audio, pulse a UI badge).
pub const PauseChangedInfo = struct {
    paused: bool,
};

pub fn EntityInfo(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
        prefab_name: ?[]const u8 = null,
    };
}

/// Payload for component lifecycle callbacks (onAdd, onSet, onRemove).
pub const ComponentPayload = struct {
    entity_id: u64,
    game_ptr: *anyopaque,

    pub fn getGame(self: ComponentPayload, comptime GameType: type) *GameType {
        return @ptrCast(@alignCast(self.game_ptr));
    }
};

// ─── Typed hook context (#855) ──────────────────────────────────────────
//
// Every hook receiver today opens its handlers with a hand-written cast:
//
//     fn getGame(ptr: *anyopaque) *@import("root").Game {
//         return @ptrCast(@alignCast(ptr));
//     }
//     pub const AnimationHooks = struct {
//         game_ptr: *anyopaque = undefined,
//         pub fn worker_eat_start(self: *AnimationHooks, p: anytype) void {
//             const game = getGame(self.game_ptr);
//             ...
//
// `HookContext` replaces that boilerplate with a declared field the
// engine fills in at `setHooks` time:
//
//     pub const AnimationHooks = struct {
//         ctx: engine.HookContext = .{},
//         pub fn worker_eat_start(self: *AnimationHooks, p: anytype) void {
//             const game = self.ctx.game();
//             ...
//
// ## Why the pointer is still type-erased
//
// The obvious API — a field `game: *Game` the engine injects — does not
// compile. A hook receiver is reflected on by the dispatcher
// (`labelle-core`'s `UnwrapReceiver` / `MergeHooks` call `@typeInfo` on
// the receiver type), and `@typeInfo` forces the receiver's FIELDS to
// resolve. If a field names the Game type, resolving the receiver needs
// the Game, and building the Game needs the dispatcher, which needs the
// receiver:
//
//     error: dependency loop with length 3
//       type 'AnimationHooks' uses value of declaration 'Game' here
//       value of declaration 'Game' uses value of declaration 'GameHooks'
//       value of 'GameHooks' depends on type 'AnimationHooks' for type
//         information query here   (labelle-core/src/dispatcher.zig:5)
//
// The same loop appears with a `pub const GameType = ...` declaration
// (`MergeHooks` evaluates every public declaration to find handlers).
// Only *private* declarations and *function bodies* are analysed late
// enough to name the Game — which is exactly why the status-quo
// `getGame` helper works. So the Game type can be named at the point of
// USE but never at the point of DECLARATION, and the stored pointer has
// to stay erased. See `RFC-TYPED-HOOK-CONTEXT.md` for the full analysis
// and for what a compiler-checked binding would cost.
//
// What `HookContext` buys over the hand-written cast:
//
//   * no `@ptrCast` / `@alignCast` and no `getGame` helper per file;
//   * `game()` resolves the assembled Game from the compilation root, so
//     no `@import("root").Game` spelled out in every hooks file either;
//   * the binding is *checked*: the context records the identity of the
//     Game it was bound to, and a mismatched or unbound context panics
//     with both type names in safety-checked builds instead of silently
//     reinterpreting memory;
//   * `gameAs(T)` rejects a non-Game `T` at compile time.

/// Opaque per-type identity token. Two `typeId` calls return the same
/// pointer iff they were passed the same type.
pub const TypeId = *const anyopaque;

/// A stable, unique address per instantiating type. `marker` lives in the
/// per-instantiation namespace of `Holder`, and `Holder` mentions `T` so
/// two structurally identical instantiations are not merged.
pub fn typeId(comptime T: type) TypeId {
    const Holder = struct {
        const bound = T;
        var marker: u8 = 0;
    };
    return @ptrCast(&Holder.marker);
}

/// The assembled `Game` type of the current compilation.
///
/// The assembler emits `pub const Game = AssembledGame;` into the
/// generated `main.zig`, which is the compilation root of every built
/// game — so `@import("root").Game` is a contract, not a guess. Calling
/// this from a library/test binary whose root has no `Game` is a compile
/// error naming the alternative (`gameAs`).
pub fn RootGame() type {
    const root = @import("root");
    if (!@hasDecl(root, "Game")) @compileError(
        "HookContext.game(): the compilation root exports no `Game`. " ++
            "This is the assembled `main.zig` in a normal `labelle` build; " ++
            "in a unit test or a library build, name the game type " ++
            "explicitly with `ctx.gameAs(MyGame)` instead.",
    );
    return root.Game;
}

/// Compile-time shape check: does `T` look like an engine `Game`?
/// `EntityType` + `HooksParam` are `GameConfig` re-exports no ordinary
/// game struct carries, so this catches the common slip of passing a
/// component or a payload type to `gameAs`.
fn assertGameType(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct" or !@hasDecl(T, "EntityType") or !@hasDecl(T, "HooksParam")) {
        @compileError(
            "HookContext.gameAs(" ++ @typeName(T) ++ "): expected an engine " ++
                "`Game` type (a `GameConfig(...)` instantiation, normally " ++
                "`@import(\"root\").Game`), but " ++ @typeName(T) ++
                " has no `EntityType`/`HooksParam` declarations.",
        );
    }
}

/// Typed access to the assembled game from inside a hook handler.
///
/// Declare it as a field on a hook receiver — any field name works, the
/// engine injects by TYPE:
///
///     pub const MyHooks = struct {
///         ctx: engine.HookContext = .{},
///         calls: usize = 0,          // receiver state survives as usual
///
///         pub fn some_event(self: *MyHooks, payload: anytype) void {
///             const game = self.ctx.game();
///             self.calls += 1;
///             _ = game;
///         }
///     };
///
/// The engine fills every `HookContext` field of every registered
/// receiver in `Game.setHooks`, before the first `game_init` hook fires.
pub const HookContext = struct {
    /// Erased pointer to the bound `Game`. `null` until `setHooks`.
    ptr: ?*anyopaque = null,
    /// Identity of the Game type `ptr` points at — the checked half.
    id: ?TypeId = null,
    /// `@typeName` of the bound Game, for the mismatch diagnostic.
    bound_name: []const u8 = "(unbound)",

    /// Bind a context to `g`. Called by `Game.setHooks`; games do not
    /// call this directly.
    pub fn bind(comptime G: type, g: *G) HookContext {
        return .{ .ptr = @ptrCast(g), .id = typeId(G), .bound_name = @typeName(G) };
    }

    /// True once `setHooks` has bound this context.
    pub fn isBound(self: HookContext) bool {
        return self.ptr != null;
    }

    /// The assembled game, typed as the compilation root's `Game`.
    ///
    /// This is the everyday form: no import, no cast. It compile-errors
    /// when the root exports no `Game` (see `RootGame`) and panics in
    /// safety-checked builds when the receiver was bound to a *different*
    /// Game type — the only way `ctx.game()` can be wrong.
    pub inline fn game(self: HookContext) *RootGame() {
        return self.gameAs(RootGame());
    }

    /// The assembled game, typed as `G`. Use when the root's `Game` is
    /// not the right answer — engine unit tests, a host binary driving
    /// more than one `Game` instantiation, or a hooks file deliberately
    /// pinned to a named game type.
    pub inline fn gameAs(self: HookContext, comptime G: type) *G {
        comptime assertGameType(G);
        const p = self.ptr orelse @panic(
            "hook context is unbound: this receiver was never passed to " ++
                "Game.setHooks (check that it is listed in the MergeHooks " ++
                "receiver tuple), or the hook ran before setHooks.",
        );
        if (std.debug.runtime_safety) {
            if (self.id != typeId(G)) {
                std.debug.panic(
                    "hook context type mismatch: bound to {s}, asked for {s}",
                    .{ self.bound_name, @typeName(G) },
                );
            }
        }
        return @ptrCast(@alignCast(p));
    }
};
