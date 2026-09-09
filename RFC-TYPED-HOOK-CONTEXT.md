# RFC: Typed Hook Context

**Issue:** labelle-toolkit/labelle-engine#855 (parent: #854)
**Status:** Implemented (engine side); one follow-up left to the assembler
**Date:** 2026-09-08
**Zig:** 0.16.0

## Problem

Every hook receiver in a shipped game opens its handlers by casting an
injected `*anyopaque` back to the assembled game. From
`flying-platform-labelle/hooks/animation_hooks.zig`:

```zig
fn getGame(ptr: *anyopaque) *@import("root").Game {
    return @ptrCast(@alignCast(ptr));
}
const Entity = @import("root").Game.EntityType;

pub const AnimationHooks = struct {
    game_ptr: *anyopaque = undefined,

    pub fn citizens__worker_eat_start(self: *AnimationHooks, payload: anytype) void {
        const game = getGame(self.game_ptr);
        ...
    }
};
```

That five-line preamble is repeated in every hooks file of every game and
every pack (flying-platform has ten such files). It costs the author a
`@ptrCast`, an `@alignCast`, a guessed `@import("root")`, and — worse — it
is unchecked: nothing verifies that `game_ptr` really points at that
`Game`, so a receiver wired into the wrong game, or one whose handler runs
before `setHooks`, silently reinterprets memory.

The event *payload* is already typed and the dispatch is already typed.
Only the game handle is not.

## The constraint that shapes the whole design

The obvious API is a typed field the engine injects:

```zig
pub const AnimationHooks = struct {
    game: *@import("root").Game = undefined,   // <-- does not compile
    ...
};
```

It does not compile, and it cannot be made to compile without changing
`labelle-core`. A hook receiver is *reflected on* by the dispatcher:
`labelle-core/src/dispatcher.zig`'s `UnwrapReceiver` calls `@typeInfo` on
the receiver type, and `MergeHooks` walks `std.meta.declarations` on it to
validate handler names. In Zig 0.16 `@typeInfo` forces the type to
**fully resolve, fields included**. So:

```
resolve AnimationHooks fields
  -> needs the value of `Game`
     -> needs the value of `GameHooks` (the MergeHooks instantiation)
        -> @typeInfo(AnimationHooks)   <-- back where we started
```

Measured, not assumed. Four probes were compiled against this worktree
(`zig 0.16.0`, engine `main`):

| # | Receiver spells the Game type as… | Result |
|---|-----------------------------------|--------|
| A | a **field** `game: *Game`, merged receiver | `error: dependency loop with length 3`, blamed on `dispatcher.zig:5` (`UnwrapReceiver`'s `@typeInfo`) |
| B | a **public decl** `pub const GameType = Game;` | `error: dependency loop with length 3` — `MergeHooks` evaluates every public decl looking for 2-parameter handlers |
| C | a **private decl** `const GameType = Game;` | compiles |
| D | a **field**, single-receiver `HookDispatcher` (no `MergeHooks`) | `error: dependency loop with length 2` — same `UnwrapReceiver` line |

So a receiver may name its Game type only from a place the compiler
analyses *late*: a **function body** or a **private declaration**. It may
never name it from a field type or a public declaration. That is exactly
why the status-quo `getGame` helper works, and it is a property of the
dispatcher's reflection, not of the engine.

**Consequence:** a *compiler-checked* typed game handle on a hook receiver
is not reachable from this repository. The stored pointer must stay
erased. What is reachable is (a) removing the casts and the import from
authoring code, and (b) making the binding *checked at runtime* instead of
unchecked.

## Options considered

**1. Typed field `game: *Game`, injected by `setHooks`.**
The design the issue asks for. Rejected: probes A and D above — hard
dependency loop, and the blocking `@typeInfo` is in `labelle-core`, a
different repository shared by every consumer.

**2. Public `pub const GameType` on the receiver, verified at `setHooks`.**
Would give a real compile-time check (`setHooks` knows `Game` and could
`@compileError` on a mismatch). Rejected: probe B — `MergeHooks`'
declaration walk evaluates it, same loop.

**3. Generic receiver factory `pub fn AnimationHooks(comptime G: type) type`.**
Clean in principle, and it does break the loop (the receiver type is only
created once `Game` exists). Rejected for now on two counts. First, Zig
0.16 cannot synthesise declarations, so the factory body must still spell
out every handler by hand — it buys the typed field but nothing else.
Second, and decisively, the assembler emits the receiver type as a plain
identifier in two places (`MergeHooks(..., .{ *mod.AnimationHooks })` and
`var inst = mod.AnimationHooks{};`, see any generated `main.zig`), so a
factory form requires an assembler change. **This is the part that cannot
be done from this repository**; see "Left to the assembler" below.

**4. Type-erased context struct with a recorded type identity.** Chosen.

**5. Erasing `Game.hooks` to `*anyopaque` + a dispatch trampoline**, so
the Game type stops depending on the receiver types. This would break the
loop from the engine side — but only halfway: `MergeHooks` still calls
`@typeInfo` on the receiver at its own instantiation, and the receiver
still names `Game`. Probe D shows the loop survives even without
`MergeHooks`. Rejected as ineffective, before considering that it also
turns a fully devirtualised dispatch into an indirect call and changes a
public field's type.

## Design

`engine.HookContext` — a three-word, non-generic struct declared as a
field on a receiver and filled in by `Game.setHooks`:

```zig
const AnimationState = @import("../components/animation_state.zig").AnimationState;

pub const AnimationHooks = struct {
    ctx: engine.HookContext = .{},

    pub fn citizens__worker_eat_start(self: *AnimationHooks, payload: anytype) void {
        const game = self.ctx.game();
        const anim = game.active_world.ecs_backend.getComponent(
            @as(@TypeOf(game.*).EntityType, @intCast(payload.worker_id)),
            AnimationState,
        ) orelse return;
        anim.transitionClip(game, .eat);
    }
};
```

No `getGame`, no `@ptrCast`, no `@alignCast`, no `@import("root")`.
Receiver state is untouched — a `HookContext` is just another field, so
stateful receivers keep working exactly as before.

### Injection is by field TYPE, not field name

`setHooks` walks each registered receiver's fields and binds **every**
field whose type is `HookContext`, whatever it is called. A pack is free
to name it `hook_ctx`, a root hook `ctx`. Name-based injection would have
collided with receivers that already have a field called `ctx`; type-based
injection cannot.

### The check

`HookContext` records the identity of the Game type it was bound to
(`engine.typeId`, a unique per-type address) plus its `@typeName`.

* `ctx.game()` — the everyday form. Resolves `@import("root").Game`, the
  type the assembler's generated `main.zig` exports. If the compilation
  root has no `Game` (a library or unit-test build), that is a **compile
  error** naming the alternative rather than a mystery.
* `ctx.gameAs(G)` — names the game type explicitly. `G` is checked at
  **compile time** for the `EntityType` / `HooksParam` declarations every
  `GameConfig` instantiation carries, so passing a component or payload
  type by mistake is a compile error, not a cast.
* Either form **panics in safety-checked builds** if the context is
  unbound (receiver never passed to `setHooks`) or was bound to a
  different Game type, with both type names in the message. The check
  compiles out under `ReleaseFast`.

Be precise about what this is: the *game type* is compile-time checked,
the *binding* is runtime checked. This is a strictly stronger guarantee
than the unchecked `@ptrCast` it replaces, and a strictly weaker one than
a `game: *Game` field would give. Per the issue's request to distinguish
the two — this is **not** a compiler-checked game handle, and the reason
is the dependency loop above, not an oversight.

## Backward compatibility

Purely additive. Nothing about the existing forms changes:

* `game_ptr: *anyopaque` receivers are still injected, by name, on the
  same line they always were.
* Receivers with neither a `game_ptr` nor a `HookContext` are untouched.
* Old and new receivers mix freely inside one `MergeHooks` tuple. This is
  what makes the migration incremental: a game can convert one hooks file
  at a time, or never.
* No change to handler signatures, to `MergeHooks`, to the payload
  unions, or to any generated code. No assembler version floor.

`test/typed_hook_context_test.zig` pins all four of those, including a
receiver copied from flying-platform's shape that must keep working
unedited.

### Migration (optional, per file)

```diff
-fn getGame(ptr: *anyopaque) *@import("root").Game {
-    return @ptrCast(@alignCast(ptr));
-}
-
 pub const AnimationHooks = struct {
-    game_ptr: *anyopaque = undefined,
+    ctx: engine.HookContext = .{},

     pub fn citizens__worker_eat_start(self: *AnimationHooks, payload: anytype) void {
-        const game = getGame(self.game_ptr);
+        const game = self.ctx.game();
```

`const Entity = @import("root").Game.EntityType;` at container scope is a
*private* declaration, so it keeps compiling (probe C). It can also be
written `@TypeOf(game.*).EntityType` inside a handler.

## Comptime cost

The injection walk is `receivers x fields`, evaluated once at `setHooks`.
It is **independent of the number of events and the number of handlers**,
so it does not touch the `receivers x variants` product in
`MergeHooks.emit` that the 100,000-branch quota exists for.

Measured on this worktree, Zig 0.16.0, aarch64-darwin, three cold builds
each (separate cache dirs), at the scale #854 validated — **64 event
variants x 16 receivers**, every receiver handling 16 variants and
touching the game in each handler:

| Harness | Cold build (3 runs) |
|---|---|
| every receiver on the legacy `game_ptr` + `getGame` form | 1.98s / 1.92s / 1.92s |
| every receiver on `HookContext` + `ctx.game()` | 2.00s / 2.00s / 2.01s |

About +3%, i.e. +0.06s at a scale no shipped game has reached. A third
harness with 27 fields per receiver (24 padding fields on top) built in
1.87s, confirming the field walk is not where the time goes. Both
harnesses compile under the existing quota; neither needed it raised.

## Left to the assembler (not doable from this repository)

Two things this change deliberately does not attempt.

1. **A compiler-checked game handle.** It needs the receiver type to be
   created *after* the Game type — i.e. option 3, a receiver factory
   `pub fn AnimationHooks(comptime G: type) type`, with the assembler
   emitting `mod.AnimationHooks(Game)` in the `MergeHooks` tuple and in
   the instance declaration. That is an assembler codegen change plus a
   scaffold/discovery convention for telling a factory receiver from a
   plain one. Worth a follow-up issue against `labelle-assembler`; it is
   not blocked by anything here, and `HookContext` remains valid
   alongside it for receivers that stay plain.

2. **Scaffolding the new form.** `labelle-init` / the pack scaffold still
   emit the `game_ptr` + `getGame` preamble. Flipping the generated
   template to `ctx: engine.HookContext = .{}` is a one-line assembler /
   CLI change and should follow this.

## Tests

* `test/typed_hook_context_test.zig` — injection into a root receiver and
  a pack receiver (different field names), same-instance binding across
  the tuple, unbound-before-`setHooks`, `gameAs` typing, survival across
  `resetEcsBackend` + pause + many frames, `typeId` uniqueness, the
  recorded identity, and the three backward-compatibility cases (legacy
  `game_ptr` receiver unchanged, context-free receiver untouched, old and
  new mixed in one tuple).
* `test/typed_hook_context_root_exe.zig` — a headless executable whose
  root declares `pub const Game`, exactly like a generated `main.zig`.
  This is the only place `ctx.game()` (the no-argument form) can be
  compiled and run, because under `zig test` the compilation root is
  Zig's test runner. It emits both a root event and a pack-namespaced
  event, asserts receipt and live mutation through the typed pointer, and
  exits non-zero on failure. Wired into `zig build test`.
