//! Tests for the engine-hosted INPUT EVENTS (labelle-gui#208, Option B).
//!
//! `Game.tick` scans the unified `InputInterface` and emits six engine
//! events into the buffered event path:
//!
//!   engine__key_pressed / engine__key_released
//!   engine__mouse_button_pressed / engine__mouse_button_released
//!   engine__gamepad_connected / engine__gamepad_disconnected
//!
//! Each scan loop is comptime-gated on `@hasField(GameEvents, tag)`, so
//! an event-less game (`GameEvents = void`) compiles fine and emits
//! nothing — the scans fold away entirely.
//!
//! The tests below drive a CONTROLLABLE input stub (settable per-key /
//! per-button / per-gamepad state) and a recorder hook, ticking the
//! game and draining `dispatchEvents` to observe what fired.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

// ── Controllable input stub ────────────────────────────────────────────
//
// Satisfies the `InputInterface(Impl)` contract (`isKeyDown` +
// `isKeyPressed` are required; the rest are optional and we provide the
// ones the scan uses). State is process-global because the interface
// dispatches to *type* decls (static fns), not an instance — mirrors how
// the real backends wrap a global window/input context. Reset between
// tests via `TestInput.reset()`.
const TestInput = struct {
    var pressed_key: ?u32 = null;
    var released_key: ?u32 = null;
    var pressed_button: ?u32 = null;
    var released_button: ?u32 = null;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;

    // Gamepad hotplug events the backend will hand to the engine on the
    // NEXT `pollGamepadEvents` drain (core#18). The engine no longer diffs
    // availability per slot; it drains whatever the backend queues. Each
    // drain consumes (clears) the pending events, mirroring a real backend
    // that reports an edge once.
    var pending_events: [16]core.GamepadEvent = undefined;
    var pending_len: usize = 0;

    fn reset() void {
        pressed_key = null;
        released_key = null;
        pressed_button = null;
        released_button = null;
        mouse_x = 0;
        mouse_y = 0;
        pending_len = 0;
    }

    /// Queue an event to be drained on the next tick's `pollGamepadEvents`.
    fn queue(ev: core.GamepadEvent) void {
        pending_events[pending_len] = ev;
        pending_len += 1;
    }

    // Required by InputInterface.
    pub fn isKeyDown(_: u32) bool {
        return false;
    }
    pub fn isKeyPressed(key: u32) bool {
        return pressed_key != null and pressed_key.? == key;
    }

    // Optional wrappers the scan relies on.
    pub fn isKeyReleased(key: u32) bool {
        return released_key != null and released_key.? == key;
    }
    pub fn getMouseX() f32 {
        return mouse_x;
    }
    pub fn getMouseY() f32 {
        return mouse_y;
    }
    pub fn isMouseButtonPressed(button: u32) bool {
        return pressed_button != null and pressed_button.? == button;
    }
    pub fn isMouseButtonReleased(button: u32) bool {
        return released_button != null and released_button.? == button;
    }

    /// Backend gamepad-event drain (core#18). Declaring this makes the
    /// engine select the BACKEND source (not the per-OS `gamepad_source`).
    /// Copies up to `out.len` queued events and clears the queue.
    pub fn pollGamepadEvents(out: []core.GamepadEvent) usize {
        const n = @min(out.len, pending_len);
        for (0..n) |i| out[i] = pending_events[i];
        pending_len = 0;
        return n;
    }
};

// ── GameEvents union with the six input variants ───────────────────────
const InputGameEvents = union(enum) {
    engine__key_pressed: engine.Events.key_pressed,
    engine__key_released: engine.Events.key_released,
    engine__mouse_button_pressed: engine.Events.mouse_button_pressed,
    engine__mouse_button_released: engine.Events.mouse_button_released,
    engine__gamepad_connected: engine.Events.gamepad_connected,
    engine__gamepad_disconnected: engine.Events.gamepad_disconnected,
};

// ── Recorder hook ──────────────────────────────────────────────────────
const InputRecorder = struct {
    key_pressed_count: usize = 0,
    key_released_count: usize = 0,
    mouse_pressed_count: usize = 0,
    mouse_released_count: usize = 0,
    gamepad_connected_count: usize = 0,
    gamepad_disconnected_count: usize = 0,

    last_key: u32 = 0,
    last_released_key: u32 = 0,
    last_button: u32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_gamepad_connected: u32 = 0,
    last_gamepad_disconnected: u32 = 0,
    // Enriched connect-payload capture (core#18).
    last_gamepad_name_buf: [core.gamepad.NAME_CAPACITY]u8 = undefined,
    last_gamepad_name_len: usize = 0,
    last_gamepad_guid: ?[16]u8 = null,
    last_gamepad_source_class: core.GamepadSourceClass = .unknown,
    last_gamepad_type_hint: core.GamepadTypeHint = .unknown,

    fn lastConnectedName(self: *const InputRecorder) []const u8 {
        return self.last_gamepad_name_buf[0..self.last_gamepad_name_len];
    }

    pub fn engine__key_pressed(self: *InputRecorder, info: anytype) void {
        self.key_pressed_count += 1;
        self.last_key = info.key;
    }
    pub fn engine__key_released(self: *InputRecorder, info: anytype) void {
        self.key_released_count += 1;
        self.last_released_key = info.key;
    }
    pub fn engine__mouse_button_pressed(self: *InputRecorder, info: anytype) void {
        self.mouse_pressed_count += 1;
        self.last_button = info.button;
        self.last_x = info.x;
        self.last_y = info.y;
    }
    pub fn engine__mouse_button_released(self: *InputRecorder, info: anytype) void {
        self.mouse_released_count += 1;
        self.last_button = info.button;
        self.last_x = info.x;
        self.last_y = info.y;
    }
    pub fn engine__gamepad_connected(self: *InputRecorder, info: anytype) void {
        self.gamepad_connected_count += 1;
        self.last_gamepad_connected = info.id;
        // Copy the enriched fields out of the payload. `info.name` is an
        // inline buffer (not a borrowed slice) so this stays valid past
        // the buffered-dispatch window.
        const name = info.nameSlice();
        @memcpy(self.last_gamepad_name_buf[0..name.len], name);
        self.last_gamepad_name_len = name.len;
        self.last_gamepad_guid = info.guid;
        self.last_gamepad_source_class = info.source_class;
        self.last_gamepad_type_hint = info.type_hint;
    }
    pub fn engine__gamepad_disconnected(self: *InputRecorder, info: anytype) void {
        self.gamepad_disconnected_count += 1;
        self.last_gamepad_disconnected = info.id;
    }
};

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const InputGame = game_mod.GameConfig(
    core.StubRender(core.MockEcsBackend(u32).Entity),
    core.MockEcsBackend(u32),
    TestInput,
    engine.StubAudio,
    engine.StubGui,
    *InputRecorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    InputGameEvents,
);

// raylib-compatible key/button codes (see src/input_types.zig).
const KEY_SPACE: u32 = 32;
const KEY_A: u32 = 65;
const MOUSE_LEFT: u32 = 0;
const MOUSE_RIGHT: u32 = 1;

fn newGame(recorder: *InputRecorder) InputGame {
    var game = InputGame.init(testing.allocator);
    game.setHooks(recorder);
    // Drain the buffered `game_init` (not a variant of this union, so it
    // never buffers anyway) — keep the buffer clean for the assertions.
    game.dispatchEvents();
    recorder.* = .{};
    return game;
}

// ── Keyboard ───────────────────────────────────────────────────────────

test "key down-edge emits key_pressed with the right code" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.pressed_key = KEY_SPACE;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.key_pressed_count);
    try testing.expectEqual(KEY_SPACE, recorder.last_key);
    try testing.expectEqual(@as(usize, 0), recorder.key_released_count);
}

test "key up-edge emits key_released with the right code" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.released_key = KEY_A;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.key_released_count);
    try testing.expectEqual(KEY_A, recorder.last_released_key);
    try testing.expectEqual(@as(usize, 0), recorder.key_pressed_count);
}

test "key_null sentinel is never emitted" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    // Force the scan to report key 0 (key_null) as pressed/released.
    TestInput.pressed_key = 0;
    TestInput.released_key = 0;
    game.tick(0.016);
    game.dispatchEvents();

    // key_null (code 0) is skipped at comptime, so nothing fires.
    try testing.expectEqual(@as(usize, 0), recorder.key_pressed_count);
    try testing.expectEqual(@as(usize, 0), recorder.key_released_count);
}

// ── Mouse ──────────────────────────────────────────────────────────────

test "mouse button down-edge emits with cursor x/y" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.pressed_button = MOUSE_LEFT;
    TestInput.mouse_x = 123.5;
    TestInput.mouse_y = 47.0;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.mouse_pressed_count);
    try testing.expectEqual(MOUSE_LEFT, recorder.last_button);
    try testing.expectApproxEqAbs(@as(f32, 123.5), recorder.last_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 47.0), recorder.last_y, 0.001);
}

test "mouse button up-edge emits mouse_button_released with x/y" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.released_button = MOUSE_RIGHT;
    TestInput.mouse_x = 5.0;
    TestInput.mouse_y = 9.0;
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.mouse_released_count);
    try testing.expectEqual(MOUSE_RIGHT, recorder.last_button);
    try testing.expectApproxEqAbs(@as(f32, 5.0), recorder.last_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 9.0), recorder.last_y, 0.001);
}

// ── Gamepad ────────────────────────────────────────────────────────────

test "a drained connect event emits gamepad_connected once (no repeat)" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    // Queue one connect for slot 0; the drain consumes it on this tick.
    TestInput.queue(core.GamepadEvent.connected(0, "Test Pad"));
    game.tick(0.016);
    // Nothing queued next tick: the source reports no edge, so NO repeat.
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.gamepad_connected_count);
    try testing.expectEqual(@as(u32, 0), recorder.last_gamepad_connected);
    try testing.expectEqual(@as(usize, 0), recorder.gamepad_disconnected_count);
}

test "a drained disconnect event emits gamepad_disconnected with its slot" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    TestInput.queue(core.GamepadEvent.connected(1, "Pad One"));
    game.tick(0.016); // connect for slot 1
    TestInput.queue(core.GamepadEvent.disconnected(1));
    game.tick(0.016); // disconnect for slot 1
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.gamepad_connected_count);
    try testing.expectEqual(@as(usize, 1), recorder.gamepad_disconnected_count);
    try testing.expectEqual(@as(u32, 1), recorder.last_gamepad_disconnected);
}

test "multiple events in one drain each emit, per-slot, in order" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    // Beyond the old 4-slot cap to prove the fixed-slot limit is gone.
    TestInput.queue(core.GamepadEvent.connected(0, "P0"));
    TestInput.queue(core.GamepadEvent.connected(7, "P7"));
    TestInput.queue(core.GamepadEvent.disconnected(0));
    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 2), recorder.gamepad_connected_count);
    try testing.expectEqual(@as(usize, 1), recorder.gamepad_disconnected_count);
    // Last connect drained was slot 7; last disconnect was slot 0.
    try testing.expectEqual(@as(u32, 7), recorder.last_gamepad_connected);
    try testing.expectEqual(@as(u32, 0), recorder.last_gamepad_disconnected);
}

test "enriched connect payload propagates name/guid/source_class/type_hint" {
    TestInput.reset();
    var recorder = InputRecorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    var ev = core.GamepadEvent.connected(3, "Xbox Wireless Controller");
    ev.guid = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    ev.source_class = .gamepad;
    ev.type_hint = .xbox;
    TestInput.queue(ev);

    game.tick(0.016);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.gamepad_connected_count);
    try testing.expectEqual(@as(u32, 3), recorder.last_gamepad_connected);
    try testing.expectEqualStrings("Xbox Wireless Controller", recorder.lastConnectedName());
    try testing.expect(recorder.last_gamepad_guid != null);
    try testing.expectEqualSlices(u8, &ev.guid.?, &recorder.last_gamepad_guid.?);
    try testing.expectEqual(core.GamepadSourceClass.gamepad, recorder.last_gamepad_source_class);
    try testing.expectEqual(core.GamepadTypeHint.xbox, recorder.last_gamepad_type_hint);
}

// ── Zero-cost / comptime-gate safety ───────────────────────────────────

// A game whose `GameEvents` lacks the input variants (here `void`) must
// compile and emit nothing — the scan folds away. Exercises the same
// `engine.Game` (GameEvents = void) used everywhere in the unit suite.
test "GameEvents = void emits no input events and compiles" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    // Ticking with input state present must not crash or attempt any
    // emission — the comptime gate eliminated every scan loop.
    game.tick(0.016);
    game.tick(0.016);
    // No assertion: passing == compiles + runs with the scans gated out.
}

// ── Fallback (per-OS `gamepad_source`) path ────────────────────────────
//
// A game on a backend that does NOT declare `pollGamepadEvents`
// (`StubInput`) but whose `GameEvents` carries the gamepad variants must
// take the comptime fallback branch: the engine drains
// `core.gamepad_source.pollEvents` and runs the source's `init`/`deinit`.
// This forces that branch to type-check and run. On hosts whose per-OS
// source is a stub (e.g. macOS → `unsupported.zig`), `pollEvents` returns
// 0, so no events fire — the point is that the fallback path compiles and
// the lifecycle is exercised without a backend `pollGamepadEvents`.
const FallbackGame = game_mod.GameConfig(
    core.StubRender(core.MockEcsBackend(u32).Entity),
    core.MockEcsBackend(u32),
    core.StubInput, // no pollGamepadEvents → engine uses gamepad_source
    engine.StubAudio,
    engine.StubGui,
    *InputRecorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    InputGameEvents,
);

test "no-poll backend routes to gamepad_source fallback (compiles + zero events on stub host)" {
    var recorder = InputRecorder{};
    var game = FallbackGame.init(testing.allocator);
    game.setHooks(&recorder);
    game.dispatchEvents();
    recorder = .{};
    defer game.deinit();

    game.tick(0.016);
    game.dispatchEvents();

    // Stub OS source has nothing to drain — but the fallback branch and
    // the source's init/deinit lifecycle were exercised.
    try testing.expectEqual(@as(usize, 0), recorder.gamepad_connected_count);
    try testing.expectEqual(@as(usize, 0), recorder.gamepad_disconnected_count);
}
