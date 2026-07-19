//! script_contract — the Script Runtime Contract v1 (RFC-LANGUAGE-PLUGINS,
//! labelle-engine#737).
//!
//! The one versioned C-ABI surface every scripting language binds: flat
//! `export fn labelle_*` symbols, strings as ptr+len, payloads as JSON.
//! Embedded-VM languages (Lua, mruby) call these from binding closures;
//! native-compiled languages (Rust, Crystal) declare them `extern "C"`
//! against `contract/labelle_script.h` and link into the host. Both
//! families consume the IDENTICAL surface — proven by the POC in
//! `spike/language-plugins/` (PR #734), whose subscribe/poll-drain event
//! semantics are pinned here verbatim.
//!
//! ## Bind pattern
//!
//! Module-scope `g` in the assembler-generated `main.zig` is not visible
//! to a sibling module, so the generated main hands it to `bind(&g)` once,
//! right after `Game.init`. `bind` is comptime-generic: it instantiates a
//! `Holder` for the concrete Game type, stores the pointer in that
//! instantiation's container-level `var`, and publishes a vtable of plain
//! (non-generic) function pointers. The `export fn`s dispatch through that
//! vtable — they carry no comptime type information themselves.
//!
//! Before `bind` runs, every export is a safe no-op: id-returning ops
//! (incl. `labelle_entity_find`) return 0, rc-returning ops return -1
//! (`labelle_plugin_call` its unroutable sentinel — the same -1, carried
//! in its usize), `labelle_component_get` / `labelle_query` /
//! `labelle_event_poll` / `labelle_plugin_response_fetch` write nothing
//! and return 0, the void ops
//! silently ignore, the `labelle_input_key_*` reads report not-down (0),
//! and `labelle_input_mouse` writes the origin.
//! `labelle_contract_version` is pure and works even before `bind`.
//!
//! ## No symbols in script-less builds
//!
//! This file is reachable from the engine root only through
//! `root.script_contract`, a lazily-analyzed `pub const`. The generated
//! main `@import`s/binds it only when a language plugin is attached; a
//! build that never references the module never semantically analyzes this
//! file, so none of the `labelle_*` exports are emitted — the same
//! zero-cost gate `editor_api` uses for its `editor_*` symbols.
//!
//! ## Generated-main touchpoints (the assembler splices exactly these)
//!
//! ```zig
//! script_contract.bind(&g);            // once, after Game init
//! // per frame:
//! g.tick(dt);                          // plugin tick runs the scripts
//! script_contract.drainEvents(&g);     // AFTER tick, BEFORE dispatchEvents
//! g.dispatchEvents();
//! ```
//!
//! The tick → drainEvents → dispatchEvents ordering is load-bearing:
//! `drainEvents` walks the frame's buffered events (`game.event_buffer`)
//! and copies the subscribed ones into the poll FIFO, WITHOUT consuming
//! the buffer — `dispatchEvents` then drains it to Zig hooks as always.
//! Running the tap after `dispatchEvents` would see an already-emptied
//! buffer (dispatch swaps it out), so scripts would never receive a
//! single event. Call `drainEvents` exactly once per frame: it is also
//! the maintenance point that recycles the `labelle_event_emit` payload
//! arenas (see "Payload memory" below) — skipping it grows them
//! unboundedly, and a second call in one frame would both double-deliver
//! the frame's events and recycle payloads that are still awaiting
//! dispatch.
//!
//! ## Event tap semantics (the POC's subscribe/poll model)
//!
//! A script declares interest with `labelle_event_subscribe(name)` (the
//! `GameEvents` union tag, e.g. `"turret__fired"` or `"engine__tick"`),
//! then DRAINS its inbox once per tick: each `labelle_event_poll` copies
//! the next pending event as `"<name> <json>"` into `out` and returns
//! bytes written; 0 = inbox empty. Dispatch-to-handlers is language-
//! plugin sugar over this drain loop (Lua callbacks, Rust match, Ruby
//! blocks). The event name is the union tag name; the payload is the
//! variant struct serialized through `std.json` reflection. Every event
//! flowing through the buffered path this frame is visible — engine
//! `engine__*` dual-emits, game scripts' `game.emit`, and the script's
//! own `labelle_event_emit` alike. `emitSync` bypasses the buffer and is
//! therefore NOT tappable, mirroring how it also skips flow `OnEvent`s.
//!
//! Subscriptions activate at DRAIN boundaries: `labelle_event_subscribe`
//! parks the name in a PENDING set, and `drainEvents` filters the
//! frame's buffer against the ACTIVE set only, absorbing the pending
//! set at the end — a subscription takes effect for events emitted
//! after the current tick's drain. Without the boundary, a script
//! subscribing mid-tick would be handed events buffered EARLIER in
//! that same tick (`engine__tick` fires before scripts run) — a replay
//! of a past the script never subscribed to.
//!
//! ## Payload memory (`labelle_event_emit`)
//!
//! Emitted payloads are parsed from JSON into the typed variant struct;
//! slice-bearing fields land in one of TWO module-owned arenas that
//! alternate per frame. `drainEvents` flips the active arena and resets
//! the newly-active one — which holds only the PREVIOUS frame's
//! payloads, already delivered by that frame's `dispatchEvents`. The
//! frame's own emits (made during the tick, dispatched after the drain)
//! sit untouched in the other arena until the NEXT flip. Two arenas
//! rather than one because a single reset-at-drain would recycle
//! this-frame payloads BEFORE their end-of-frame dispatch — a
//! use-after-free for any slice-bearing event payload. Steady-state
//! memory is bounded by two frames' worth of emitted payloads.
//!
//! Component-set payloads use a different lifetime: slices parsed for a
//! component land in `active_world.nested_entity_arena`, the exact
//! allocator the JSONC scene bridge uses for deserialized components, so
//! they share the entity's lifetime and free atomically on scene change.
//! Pointer-free components (the per-tick hot path, e.g. `Position`)
//! parse without allocating at all.
//!
//! ## Out-buffer sizing (required-size vs written-bytes)
//!
//! `labelle_query` and `labelle_component_get` size snprintf-style:
//! the return is the bytes the COMPLETE result requires, `required >
//! cap` is the caller's truncation signal (retry right-sized), and a
//! NULL/cap-0 `out` is a legal pure sizing probe. 0 keeps its
//! sentinel meaning (malformed names for the query; absent / unknown
//! / dead for the get). They differ in what an under-sized cap
//! WRITES: the query fills `out` up to the cap, truncated at the
//! last whole id and always valid JSON — a prefix of independent ids
//! has value — while the get writes ALL-OR-NOTHING (only when
//! `required <= cap`): a truncated JSON object prefix is useless, so
//! on overflow the buffer is untouched. `labelle_event_poll` alone
//! returns bytes WRITTEN, because a poll CONSUMES its entry
//! (truncation included) and a required-size return after the copy
//! could not be retried; its sizing story is the paired NULL/cap-0
//! probe instead — the NEXT entry's size, nothing read or consumed —
//! so a sizing caller probes, grows its buffer, then polls.
//! `labelle_plugin_call` (v1.2) is required-size / all-or-nothing
//! like the get, but its probe/retry legs live on the PAIRED
//! `labelle_plugin_response_fetch`: a call EXECUTES the handler, so
//! re-calling to resize would double-execute (see "Plugin commands"
//! below).
//!
//! ## Component name space (registry + scene built-ins)
//!
//! Component names resolve over the game's own `ComponentRegistry` PLUS
//! everything JSONC scenes can author: `Position`, and the five
//! `jsonc/component_apply.zig` special-cases — `Sprite`, `Shape`,
//! `Tilemap`, `Camera`, `Image`. The built-ins are not merely
//! name-aliased: `set` routes through the scene loader's OWN apply fns
//! (`applySprite` → `addSprite` renderer tracking, `applyCamera`'s
//! inline-tag mapping, `applyTilemap`'s asset decode), and `remove`
//! through the engine's typed teardown channels (`removeSprite` /
//! `removeShape` / `removeTilemap`), so a script write is
//! indistinguishable from a scene author. The loader's registry-
//! precedence gates carry over too — `Tilemap`/`Camera`/`Image` defer
//! to a project-registered component of the same name, `Sprite`/`Shape`
//! stay built-in — and `contract/labelle_script.h` tabulates the
//! per-name `get` caveats (renderer-handle fields are omitted; `Camera`
//! serializes `tag` as a string).
//!
//! ## Plugin commands (`labelle_plugin_call`, contract v1.1 #744 / v1.2 #758)
//!
//! Scripts call Zig PLUGIN commands (pathfinder navigate, dungeon
//! generate, …) through the SAME handler channel labelle-studio's
//! plugin panels use: the game's `editorPluginCommand` mixin
//! (`game/editor_command_mixin.zig`, #748) — a SYNCHRONOUS `emitSync`
//! of `engine__editor_plugin_command` to the handler a plugin declared
//! by subscribing to that engine event. One registration is dual-use:
//! a handler written for a studio panel is reachable from every
//! scripting language, unmodified — and the mixin's borrowed-slices
//! handler contract carries over verbatim (the dispatch returns only
//! after the handler ran, so the script's transient buffers stay valid
//! with no copy).
//!
//! The usize return keeps the v1.1 rc encoding and grows a size leg:
//! `plugin_call_unroutable` (`maxInt(usize)`, C's `(size_t)-1` — the rc
//! convention's -1 in a usize) = empty plugin/command, no handler
//! registered in this build (the variant never landed on the merged
//! `GameEvents`), or not bound; 0 = dispatched, no handler responded
//! (the v1.1 fire-and-forward outcome); N = a handler RESPONDED (v1.2,
//! #758: `engine.plugin_command.respond` during the synchronous
//! dispatch — one response per command, first-writer-wins, see the
//! mixin), and N is the bytes the response requires, written into
//! `out` all-or-nothing (`component_get`-style, exactly as v1.1
//! reserved). One deliberate exception keeps old bindings whole — the
//! v1.1-COMPAT FOLD: a call in the exact shape the v1.1 header
//! sanctioned (`out == NULL && out_cap == 0`, "pass NULL/0") returns
//! the v1.1 rc even when a handler responded — 0, never N — so a
//! v1.1-built binding checking `rc == 0` doesn't misread a successful
//! responding dispatch as failure; the response is still published for
//! `labelle_plugin_response_fetch` (the export doc pins the boundary
//! shapes). The channel is a broadcast that handlers name-filter
//! THEMSELVES, so the engine cannot tell an unknown plugin/command
//! from a delivered-and-ignored one: both dispatch as 0 wherever a
//! handler exists. Multi-event results and acks can still travel back
//! as game events — the subscribe/poll tap above.
//!
//! ### Why responses have a paired fetch (`labelle_plugin_response_fetch`)
//!
//! The shared sizing convention's "retry right-sized" leg is WRONG on
//! `labelle_plugin_call` alone: a call EXECUTES the handler, so
//! retrying an over-cap response (or NULL/0 sizing-probing it) would
//! run the command twice — unacceptable for non-idempotent commands.
//! So every responded call also STORES the response (module state,
//! capped at `plugin_command.max_response_len`), and
//! `labelle_plugin_response_fetch` reads the most recently COMPLETED
//! call's response with the full sizing semantics and ZERO side
//! effects: NULL/cap-0 probe, required-size return, all-or-nothing
//! write, repeatable (non-consuming — the store is replaced/cleared as
//! each `labelle_plugin_call` COMPLETES, and on unbind). This mirrors
//! `labelle_event_poll`'s no-consume probe precedent: the
//! side-effecting op stays single-shot, the sizing/read op is free.
//!
//! Calls NEST: a handler may itself issue a `labelle_plugin_call`
//! (the mixin gives the inner dispatch its own response window). Each
//! call dispatches into PER-CALL stack storage and publishes the
//! module store only at its own completion — inner first, outer last —
//! so concurrent in-flight responses never share bytes, and a fetch
//! made after the stack unwinds reads the OUTERMOST call's outcome
//! (the handler already received the inner response in its own call's
//! `out` buffer). Publish-on-completion is what keeps both fetch
//! semantics and response integrity honest under recursion.
//!
//! Single-threaded by design (main thread, during the plugin's tick);
//! no atomics.

const std = @import("std");
const core = @import("labelle-core");
const jsonc = @import("jsonc");
const component_apply = @import("jsonc/component_apply.zig");
/// The plugin-command channel's shared pieces (#758): `max_response_len`
/// sizes the response store below, and the mixin `Result` is what
/// `editorPluginCommandOut` hands back through the vtable impl.
const plugin_command = @import("game/editor_command_mixin.zig");

/// Contract version consumers compile against — bumped on BREAKING ABI
/// or semantic changes only. Language plugins check it via
/// `labelle_contract_version()` at startup and refuse a mismatch, so a
/// bump on additions would strand every still-compatible consumer;
/// ADDITIVE growth (new exports) is a minor revision instead, marked
/// "since v1.x" in `contract/labelle_script.h` and detected by probing
/// for the symbol — the editor-bridge contract's exact convention
/// (v1.1–v1.7). Current surface: v1.1 = v1 + `labelle_plugin_call`
/// (#744); v1.2 = v1.1 + plugin-call responses — `out`/`out_cap`
/// activated per their reserved semantics + `labelle_plugin_response_fetch`
/// (#758); v1.3 = v1.2 + bulk component access — the packed component
/// codec (`labelle_component_get_packed`/`_set_packed`) and the batched
/// query (`labelle_component_batch_get`/`_batch_set`)
/// (labelle-scripting#41; probe for the symbols); v1.4 = v1.3 + the
/// id-tagged batch variant (`labelle_component_batch_get_ids`/
/// `_batch_set_ids`) — each row prefixed with its u64 entity id,
/// applied BY ID on write (#783; probe for the symbols, or comptime
/// via the `batch_id_row_prefix` marker decl below).
pub const CONTRACT_VERSION: u32 = 1;

/// `labelle_plugin_call`'s unroutable sentinel: the rc convention's -1
/// carried in that export's usize return (C's `(size_t)-1`). Distinct
/// from 0 = dispatched — and from any future response-size return,
/// which could never require the whole address space.
pub const plugin_call_unroutable: usize = std.math.maxInt(usize);

/// `labelle_component_batch_get`'s int-field refusal sentinel: the rc
/// convention's -2 carried in that export's usize return (C's
/// `(size_t)-2`). Returned when ANY named component carries an
/// int-typed field — i64/u64 values cannot ride the batch's f32 stream
/// without silent corruption (f32's 24-bit mantissa truncates large
/// ints), so the host refuses the whole batch instead of degrading the
/// data. The same refusal is `-2` from `labelle_component_batch_set`'s
/// i32 return. Distinct from 0 = malformed/not-bound and from any
/// required-size return, which could never need that much space.
pub const batch_int_refused: usize = std.math.maxInt(usize) - 1;

/// The id-tagged batch variant's per-row prefix: each entity's f32
/// stream is preceded by its entity id as a little-endian u64 — 8
/// bytes — in both `labelle_component_batch_get_ids`'s output (after
/// the u32 count header) and `labelle_component_batch_set_ids`'s
/// input. Also the "since v1.4" COMPTIME CAPABILITY MARKER: language
/// plugins detect the id-tagged exports by `@hasDecl(engine
/// .script_contract, "batch_id_row_prefix")` — the exact convention
/// `batch_int_refused` established for v1.3 (see labelle-scripting's
/// `contract.host_has_bulk_access` probe; `@hasDecl` on externs cannot
/// see host exports).
pub const batch_id_row_prefix: usize = 8;

/// Inbox back-pressure cap: pending (drained-but-unpolled) events beyond
/// this are dropped NEWEST-first, matching the POC's fixed-ring behavior.
/// A script that subscribes but never polls can't grow the heap
/// unboundedly; a script that drains each tick never comes near it.
pub const max_pending_events: usize = 256;

// ── Contract-local state (module scope, shared by every Holder) ─────
//
// The subscribe/poll machinery is deliberately NOT per-Game state: like
// `editor_api`'s pause/step counters it belongs to the module, because
// the exports that manipulate it are plain C symbols with no game
// context. All of it needs the bound game's allocator, so unlike
// `editor_pause` it only becomes functional after `bind` (subscribe is
// a documented pre-bind no-op — the generated main binds before the
// language plugin's setup runs, so no real subscriber exists earlier).

var vtable: ?*const VTable = null;
/// The bound game's allocator — owns `subs`/`inbox` entries and the
/// emit arena. `null` = not bound.
var bound_allocator: ?std.mem.Allocator = null;
/// ACTIVE subscribed event names (deduped, owned copies) — the set
/// `drainEvents` filters against.
var subs: std.ArrayList([]u8) = .empty;
/// PENDING subscriptions (deduped against both sets, owned copies):
/// names subscribed since the last drain. `drainEvents` absorbs them
/// into `subs` at the END of the drain, so a subscription made
/// mid-tick can never match events buffered earlier that same tick
/// (effective-next-drain semantics — see the module doc).
var pending_subs: std.ArrayList([]u8) = .empty;
/// FIFO inbox of pending `"<name> <json>"` entries (owned). Popped from
/// `inbox_head` so a drain-heavy frame is O(1) per poll; the backing
/// list is compacted whenever it runs empty, or in place once the dead
/// prefix passes `inbox_compact_threshold` (see `compactInbox` — a
/// budgeted poller that always leaves a backlog never runs it empty).
var inbox: std.ArrayList([]u8) = .empty;
var inbox_head: usize = 0;
/// Dead-slot count past which `compactInbox` slides the pending tail
/// to the front instead of waiting for the inbox to run empty.
const inbox_compact_threshold: usize = 16;
/// The tick's scaled (gameplay) dt as stamped by the language plugin
/// via `labelle_time_dt_stamp`; `null` = never stamped this session,
/// so `labelle_time_dt` reconstructs the value from the frame-profiler
/// ring instead. Reset on bind/unbind — the stamp belongs to the
/// plugin session, exactly like `subs`/`inbox`.
var stamped_dt: ?f32 = null;
/// Double-buffered arenas for `labelle_event_emit` payloads — see the
/// module doc's "Payload memory" section for why one arena would UAF.
/// `emit_active` indexes the arena current emits parse into; it flips
/// at every `drainEvents`.
var emit_arenas: [2]?std.heap.ArenaAllocator = .{ null, null };
var emit_active: u1 = 0;
/// The most recently COMPLETED `labelle_plugin_call`'s handler response
/// (#758) — what `labelle_plugin_response_fetch` reads. A static
/// buffer, not an allocation: the channel is capped at
/// `plugin_command.max_response_len` by design, the store only exists
/// in binaries that reference this module at all (the script-less
/// zero-cost gate), and a static store removes the
/// free-on-unbind/replace bug class entirely. `null` len = no stored
/// response (pre-bind, never called, last completed call unroutable or
/// fire-and-forward).
///
/// PUBLISH-ON-COMPLETION discipline: this is never the live dispatch
/// target — each `labelle_plugin_call` dispatches into its own stack
/// buffer and copies/clears here only as it COMPLETES (`pluginCallImpl`),
/// plus an entry-clear in the export for the pre-dispatch failure legs.
/// Nested calls (a handler calling `labelle_plugin_call`) therefore
/// can't corrupt an in-flight outer response, and the store settles on
/// the OUTERMOST call's outcome. Cleared on unbind.
var response_store: [plugin_command.max_response_len]u8 = undefined;
var response_len: ?usize = null;

// ── Type-erased dispatch ────────────────────────────────────────────

const VTable = struct {
    entity_create: *const fn () u64,
    entity_destroy: *const fn (id: u64) void,
    entity_find: *const fn (name: []const u8) u64,
    prefab_spawn: *const fn (name: []const u8, params_json: []const u8) u64,
    component_set: *const fn (id: u64, name: []const u8, json: []const u8) i32,
    component_get: *const fn (id: u64, name: []const u8, out: []u8) usize,
    // PACKED (binary) codec twins of component_get/set — the JSON-free hot
    // path for scalar-only components. `component_get_packed` writes the
    // packed record (or the 0xFF "not packable" sentinel) into `out` with
    // the same required-size/all-or-nothing semantics as component_get;
    // `component_set_packed` parses a packed record and coerces each field
    // into the target struct (rc -1 = refuse → binding falls back to JSON).
    component_get_packed: *const fn (id: u64, name: []const u8, out: []u8) usize,
    component_set_packed: *const fn (id: u64, name: []const u8, buf: []const u8) i32,
    // BATCHED codec — the whole-query fast path: one call moves ALL
    // matching entities' scalar component data across the boundary as a flat
    // f32 buffer, collapsing the per-entity FFI crossings into 2 per tick.
    // `component_batch_get` writes `[u32 count][f32 stream]` (f32/f64 + bool
    // fields only — a named component with any INT field is refused with
    // `batch_int_refused` / -2, because ints would silently corrupt through
    // f32); `component_batch_set` re-queries and applies the f32 stream
    // positionally, READ-MODIFY-WRITE (only scalar fields overwritten,
    // non-scalar preserved — get/set symmetry), PREFLIGHTING the buffer
    // length against the re-queried entity set and refusing -1 with NO
    // writes on mismatch (the positional-coupling guard).
    component_batch_get: *const fn (names_json: []const u8, out: []u8) usize,
    component_batch_set: *const fn (names_json: []const u8, buf: []const u8) i32,
    // ID-TAGGED batch twins (since v1.4, #783): the same f32 stream, but
    // every entity's floats are prefixed by its u64 id —
    // `_batch_get_ids` writes `[u32 count][rows: u64 id + floats]` and
    // `_batch_set_ids` applies each row BY ID (vanished or
    // no-longer-matching entities are SKIPPED, their floats consumed),
    // closing the positional variant's two residual holes: a same-count
    // entity swap between get and set, and an onSet-hook mutation of
    // the entity set mid-apply.
    component_batch_get_ids: *const fn (names_json: []const u8, out: []u8) usize,
    component_batch_set_ids: *const fn (names_json: []const u8, buf: []const u8) i32,
    component_has: *const fn (id: u64, name: []const u8) i32,
    component_remove: *const fn (id: u64, name: []const u8) i32,
    query: *const fn (names_json: []const u8, out: []u8) usize,
    event_emit: *const fn (name: []const u8, json: []const u8) i32,
    scene_change: *const fn (name: []const u8) i32,
    log: *const fn (msg: []const u8) void,
    time_dt: *const fn () f32,
    input_key_down: *const fn (key: u32) bool,
    input_key_pressed: *const fn (key: u32) bool,
    input_mouse: *const fn () core.Position,
    // Returns the export's wire value directly: `plugin_call_unroutable`,
    // 0 (dispatched, no response), or the response's required size — the
    // impl also deposits responded bytes into `response_store` (same
    // module, so the plain fn ptr needs no out-slice threading).
    plugin_call: *const fn (plugin: []const u8, command: []const u8, params_json: []const u8) usize,
};

// ── Generated-main API (non-export) ─────────────────────────────────

/// Store the concrete Game behind the type-erased vtable. Called once by
/// the generated main, after `Game.init` (and scene registration) and
/// before the language plugin's `setup` runs. `g` must be a stable
/// `*Game` pointer. Re-binding tears the previous session down first
/// (subscriptions and pending events belong to the plugin session, not
/// the process), so a bind-after-bind never leaks or cross-delivers.
pub fn bind(g: anytype) void {
    const GP = @TypeOf(g);
    comptime {
        const info = @typeInfo(GP);
        if (info != .pointer or @typeInfo(info.pointer.child) != .@"struct")
            @compileError("script_contract.bind expects a *Game pointer, got " ++ @typeName(GP));
    }
    if (vtable != null) unbind();
    const H = Holder(GP);
    H.game = g;
    vtable = &H.vtable_impl;
    bound_allocator = g.allocator;
    emit_arenas = .{
        std.heap.ArenaAllocator.init(g.allocator),
        std.heap.ArenaAllocator.init(g.allocator),
    };
    emit_active = 0;
    stamped_dt = null;
}

/// Drop the bound game and reset all contract state (subscriptions,
/// pending inbox entries, the emit arena). Exports revert to their
/// pre-bind no-op behavior. Call before the Game is deinitialized if
/// the module outlives it; tests use it to isolate the module-level
/// state.
pub fn unbind() void {
    vtable = null;
    if (bound_allocator) |alloc| {
        for (subs.items) |s| alloc.free(s);
        subs.deinit(alloc);
        subs = .empty;
        for (pending_subs.items) |s| alloc.free(s);
        pending_subs.deinit(alloc);
        pending_subs = .empty;
        // Entries before `inbox_head` were already freed by poll.
        for (inbox.items[inbox_head..]) |e| alloc.free(e);
        inbox.deinit(alloc);
        inbox = .empty;
        inbox_head = 0;
    }
    for (&emit_arenas) |*slot| {
        if (slot.*) |*a| a.deinit();
        slot.* = null;
    }
    emit_active = 0;
    stamped_dt = null;
    bound_allocator = null;
    // The stored plugin-call response belongs to the session too — a
    // fetch after unbind (or across a re-bind) must not read a previous
    // game's response.
    response_len = null;
}

/// Per-frame event tap, called by the generated main AFTER `g.tick(dt)`
/// and BEFORE `g.dispatchEvents()` — see the module doc for why that
/// ordering is load-bearing (dispatch consumes the buffer; the tap only
/// reads it). Walks the frame's buffered `GameEvents`, serializes each
/// event whose name is in the ACTIVE subscription set to
/// `"<name> <json>"` (name = union tag, payload via `std.json`
/// reflection), and appends it to the poll FIFO. Subscriptions made
/// since the last drain are PENDING and do not match this walk; they
/// activate at the end of it (effective-next-drain — the module doc's
/// "Event tap semantics" section), so a mid-tick subscribe never
/// replays events buffered earlier in the same tick.
///
/// Also the once-per-frame maintenance point: flips the double-buffered
/// `labelle_event_emit` payload arenas and recycles the one holding the
/// PREVIOUS frame's payloads (safe precisely because that frame's
/// `dispatchEvents` already delivered everything referencing it — the
/// module doc's "Payload memory" section spells out the two-arena
/// dance).
///
/// A comptime no-op for games without a `GameEvents` union, and an
/// early-out (past pending-subscription activation) when nothing is
/// subscribed — an unused tap costs one branch per frame.
pub fn drainEvents(g: anytype) void {
    const GP = @TypeOf(g);
    comptime {
        const info = @typeInfo(GP);
        if (info != .pointer or @typeInfo(info.pointer.child) != .@"struct")
            @compileError("script_contract.drainEvents expects a *Game pointer, got " ++ @typeName(GP));
    }
    const G = @typeInfo(GP).pointer.child;
    // Flip + recycle BEFORE the events gate: even a game that never
    // subscribes still routes `labelle_event_emit` payloads through the
    // arenas. The newly-active arena held the previous frame's
    // (already-dispatched) payloads; this frame's own emits stay valid
    // in the other one until the next flip.
    emit_active +%= 1;
    if (emit_arenas[emit_active]) |*a| _ = a.reset(.retain_capacity);
    if (comptime !gameHasEventsUnion(G)) return;
    if (vtable == null) return;
    const alloc = bound_allocator orelse return;
    // Pending subscriptions activate at the END of the drain — the
    // defer covers the no-active-subs early-out below, so a session's
    // FIRST subscription still becomes active for the next drain.
    defer activatePendingSubs(alloc);
    if (subs.items.len == 0) return;

    for (g.event_buffer.items) |ev| {
        switch (ev) {
            inline else => |data, tag| {
                if (!isSubscribed(@tagName(tag))) continue;
                enqueueEvent(alloc, @tagName(tag), data);
            },
        }
    }
}

/// Absorb the pending subscription set into the active one — the tail
/// end of `drainEvents`. Entries MOVE (same allocator owns them);
/// dedupe already happened at subscribe time, against both sets. The
/// OOM policy matches subscribe's: a name that can't be recorded is
/// dropped silently rather than taking the frame down.
fn activatePendingSubs(alloc: std.mem.Allocator) void {
    if (pending_subs.items.len == 0) return;
    for (pending_subs.items) |s| {
        subs.append(alloc, s) catch alloc.free(s);
    }
    pending_subs.clearRetainingCapacity();
}

// ── Exports (plain, non-generic; dispatch through the vtable) ───────

/// The contract version this binary was built with. Pure — works before
/// `bind`, so a plugin can version-check first thing.
pub export fn labelle_contract_version() u32 {
    return CONTRACT_VERSION;
}

/// Create an empty entity. Returns its id, or 0 when not bound (entity
/// ids are never 0 — every ECS backend starts at 1, and the JSONC
/// bridge relies on the same sentinel).
pub export fn labelle_entity_create() u64 {
    const vt = vtable orelse return 0;
    return vt.entity_create();
}

/// Destroy entity `id` (children cascade, exactly like a Zig script's
/// `game.destroyEntity`). Unknown/dead/overflowing ids are ignored, not
/// crashes — mirrors `editor_set_entity_position`'s tolerance.
pub export fn labelle_entity_destroy(id: u64) void {
    const vt = vtable orelse return;
    vt.entity_destroy(id);
}

/// Find an entity by name — the RFC's `entity_find`, resolved through a
/// registered `Name` (or `Tag`) component: the game's own
/// `ComponentRegistry` is searched at COMPTIME for a component of that
/// name carrying a `[]const u8` field (`name`/`value`/`tag`), and the
/// first live entity whose field equals `name` wins. Returns its id, or
/// 0 = no match / empty name / the game registers no such component
/// (the whole lookup folds away at comptime for those, a zero-cost
/// always-0) / not bound. First-match, snapshot over the ECS view at
/// call time. Names are not guaranteed unique — a game that wants
/// uniqueness enforces it; this returns the first the view yields.
pub export fn labelle_entity_find(name_ptr: [*]const u8, name_len: usize) u64 {
    const vt = vtable orelse return 0;
    if (name_len == 0) return 0;
    return vt.entity_find(name_ptr[0..name_len]);
}

/// Spawn a named prefab. `params_json` is optional: NULL or empty
/// (`len == 0`) spawns at the origin; otherwise it is a `{"x":…,"y":…}`
/// object giving the spawn position (unknown keys ignored; malformed
/// JSON fails the spawn). Returns the root entity id, or 0 on failure
/// (unknown prefab, no JSONC scene loaded yet, bad params, not bound).
pub export fn labelle_prefab_spawn(
    name_ptr: [*]const u8,
    name_len: usize,
    json_ptr: ?[*]const u8,
    json_len: usize,
) u64 {
    const vt = vtable orelse return 0;
    if (name_len == 0) return 0;
    return vt.prefab_spawn(
        name_ptr[0..name_len],
        optionalJson(json_ptr, json_len, ""),
    );
}

/// Set component `name` on entity `id` from a JSON object — the general
/// serde seam over the game's OWN `ComponentRegistry`, plus everything
/// scenes can author: the built-in `Position` (routed through
/// `setPosition` so render dirty-tracking fires) and the five scene
/// built-ins `Sprite`/`Shape`/`Tilemap`/`Camera`/`Image`, dispatched
/// through the scene loader's own apply fns with its registry-
/// precedence gates (module doc, "Component name space"). Unlike
/// `editor_set_component` — deliberately allowlisted to the vetted
/// `"Camera"` — this dispatch is open: the contract is the game's own
/// code calling itself, so it gets the full scene-authoring surface.
///
/// REPLACE semantics: the JSON is parsed as the whole component struct
/// (absent fields take the struct's defaults, unknown fields are
/// ignored); there is no merge/patch. `json` may be NULL or empty
/// (`len == 0`), meaning `"{}"` — all defaults. Returns 0 = ok; -1 =
/// unknown component name / unknown-or-dead entity / parse failure /
/// not bound. On -1 the entity is untouched (the parse runs before any
/// mutation). The built-ins follow the scene loader's LENIENT field
/// semantics (a wrong-typed field with a default falls back to that
/// default; malformed JSON and non-object payloads are still -1).
/// On EVERY path the payload must be a single JSON document: trailing
/// bytes after it (beyond whitespace — plus comments on the built-in
/// path, which is JSONC) are malformed JSON, refused with -1.
pub export fn labelle_component_set(
    id: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    json_ptr: ?[*]const u8,
    json_len: usize,
) i32 {
    const vt = vtable orelse return -1;
    if (name_len == 0) return -1;
    return vt.component_set(
        id,
        name_ptr[0..name_len],
        optionalJson(json_ptr, json_len, "{}"),
    );
}

/// Serialize component `name` of entity `id` to JSON into `out`
/// (capacity `out_cap`) and return the bytes the COMPLETE JSON
/// requires (snprintf-style sizing, like `labelle_query`). 0 keeps
/// its sentinel meaning: absent component / unknown name / dead
/// entity / not bound. The write is ALL-OR-NOTHING: `out` is filled
/// only when the whole JSON fits (`required <= out_cap`) — a
/// truncated JSON object prefix is useless, unlike the query's
/// still-valid id prefix — so on overflow the buffer is untouched
/// and `required > out_cap` is the caller's signal to retry with a
/// `required`-sized buffer. A NULL or zero-capacity `out` is a legal
/// pure sizing probe: nothing written, the required size returned.
///
/// Scene built-ins serialize as a scene could have AUTHORED them: any
/// field that is a renderer handle rather than authored data (the
/// non-exhaustive-enum idiom, e.g. gfx `Sprite.texture`) is omitted —
/// it re-derives on the next set — and `Camera.tag` serializes as a
/// string (the inline `[16:0]u8` would emit as a NUL-padded array).
/// The output feeds back through `labelle_component_set` losslessly.
pub export fn labelle_component_get(
    id: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const vt = vtable orelse return 0;
    if (name_len == 0) return 0;
    // NULL (legal only alongside cap 0, but tolerated regardless) is
    // the documented sizing probe: an empty destination — required-size
    // computation runs, nothing is written. Same shape as the query's.
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    return vt.component_get(id, name_ptr[0..name_len], buf);
}

/// PACKED (binary) twin of `labelle_component_get` — serializes component
/// `name` of entity `id` into `out` as a self-describing little-endian
/// record (see `packInto`) rather than JSON text, so a language plugin can
/// refill a scalar view without any JSON parse. Sizing mirrors
/// `labelle_component_get` exactly: required-size return, all-or-nothing
/// write, NULL/cap-0 sizing probe, 0 = absent/unknown/dead/not-bound.
/// When the component carries any non-scalar field the impl writes the
/// single sentinel byte 0xFF and returns 1 — the caller then falls back to
/// the JSON `labelle_component_get` path. Since v1.3, additive (probe by
/// symbol like the editor-bridge additions).
pub export fn labelle_component_get_packed(
    id: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const vt = vtable orelse return 0;
    if (name_len == 0) return 0;
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    return vt.component_get_packed(id, name_ptr[0..name_len], buf);
}

/// PACKED (binary) twin of `labelle_component_set` — applies a packed
/// record (`packInto`'s format) to component `name` of entity `id`,
/// coercing each named field into the target struct's actual scalar type.
/// REPLACE semantics like the JSON set (absent fields take struct
/// defaults). Returns 0 = ok; -1 = unknown component / dead entity /
/// non-scalar-or-non-default-constructible target (the binding then falls
/// back to `labelle_component_set`) / malformed record / not bound. Since
/// v1.3, additive.
pub export fn labelle_component_set_packed(
    id: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    buf_ptr: ?[*]const u8,
    buf_len: usize,
) i32 {
    const vt = vtable orelse return -1;
    if (name_len == 0) return -1;
    const buf: []const u8 = if (buf_ptr) |p| p[0..buf_len] else &.{};
    return vt.component_set_packed(id, name_ptr[0..name_len], buf);
}

/// BATCHED (binary) whole-query read — the spike's per-tick fast path.
/// Resolves the SAME entity set as `labelle_query` (all entities carrying
/// every named component) and writes `[u32 entity_count][f32 stream]` into
/// `out`: for each entity in query order, each named component's scalar
/// fields (given-name order, struct-declaration field order) as raw
/// little-endian f32 (f32/f64 fields directly, bool as 0/1; non-scalar
/// fields skipped identically on get and set).
///
/// INT-FIELD REFUSAL: a named component with ANY int-typed field is
/// refused with `batch_int_refused` (`(size_t)-2`) — i64/u64 would
/// silently corrupt through the f32 stream, so the batch path rejects
/// the whole request and the binding must keep such components on the
/// per-entity paths (packed codec carries ints losslessly).
///
/// Sizing mirrors `labelle_query`: the return is the bytes the COMPLETE
/// buffer requires (retry right-sized on required > cap), 0 = malformed
/// names / not bound, NULL/cap-0 `out` sizes only. Zero matching entities
/// return the 4-byte header alone (count 0), distinct from the 0 sentinel.
/// Since v1.3, additive (probe by symbol).
pub export fn labelle_component_batch_get(
    names_json_ptr: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const vt = vtable orelse return 0;
    if (names_json_len == 0) return 0;
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    return vt.component_batch_get(names_json_ptr[0..names_json_len], buf);
}

/// BATCHED (binary) whole-query write — twin of `labelle_component_batch_get`.
/// Re-queries the same entity set in the same order and reads `buf` (the
/// pure f32 stream, NO count header) positionally, READ-MODIFY-WRITE per
/// component: only the batch-eligible scalar fields are overwritten (the
/// mirror of what `_batch_get` emitted — get/set symmetry), non-scalar
/// fields keep their existing values, and the mutated copy applies
/// through the same channels as the per-entity paths (`setPosition` /
/// `setComponent` / the scene-loader apply fns for built-ins) so hooks
/// and dirty-tracking fire identically.
///
/// POSITIONAL-COUPLING GUARD (PREFLIGHT): before writing anything, the
/// host walks the re-resolved query and requires `buf_len` to EXACTLY
/// match its stream size (count × stride × 4) — a mismatch means the
/// entity set changed between `_batch_get` and `_batch_set` (or the
/// caller sized the buffer wrong) and the call refuses -1 having written
/// NOTHING, so "re-run batch_get and recompute" can never double-apply a
/// prefix. Do NOT spawn or destroy entities between the paired get and
/// set: the layout is positional, so the guard can catch a count change
/// but never a same-count membership/order change — the id-tagged
/// `labelle_component_batch_get_ids`/`_batch_set_ids` pair (since v1.4)
/// closes both holes by matching rows to entities BY ID.
///
/// Returns 0 = ok; -1 = malformed names / entity-count mismatch (buffer
/// size disagrees with the re-queried set) / not bound; -2 = a named
/// component carries an int-typed field (same refusal as `_batch_get`'s
/// `(size_t)-2` — see `batch_int_refused`). Since v1.3, additive.
pub export fn labelle_component_batch_set(
    names_json_ptr: [*]const u8,
    names_json_len: usize,
    buf_ptr: ?[*]const u8,
    buf_len: usize,
) i32 {
    const vt = vtable orelse return -1;
    if (names_json_len == 0) return -1;
    const b: []const u8 = if (buf_ptr) |p| p[0..buf_len] else &.{};
    return vt.component_batch_set(names_json_ptr[0..names_json_len], b);
}

/// ID-TAGGED batched read — `labelle_component_batch_get`'s safer twin
/// (since v1.4, #783; probe by symbol, additive). Resolves the same
/// entity set and writes `[u32 count]` then, per entity in query order,
/// `[u64 entity_id][f32 stream]`: the identical per-entity floats the
/// positional variant emits, each row prefixed by the entity's id as a
/// little-endian u64 (`batch_id_row_prefix` bytes). Everything else
/// mirrors `_batch_get` exactly: int-field refusal (`batch_int_refused`),
/// required-size return, 0 = malformed/not bound, NULL/cap-0 sizing
/// probe, count-0 header for zero matches.
pub export fn labelle_component_batch_get_ids(
    names_json_ptr: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const vt = vtable orelse return 0;
    if (names_json_len == 0) return 0;
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    return vt.component_batch_get_ids(names_json_ptr[0..names_json_len], buf);
}

/// ID-TAGGED batched write — applies `[u64 id][f32 stream]` rows (the
/// exact layout `_batch_get_ids` emitted, minus the u32 count header)
/// BY ID instead of positionally: each row's entity is resolved from
/// its embedded id, and a row whose entity has VANISHED — or no longer
/// carries every named component — is SKIPPED (its floats consumed,
/// nothing written) rather than failing the batch. Rows apply
/// independently through the same RMW channels as `_batch_set`
/// (scalar fields overwritten, non-scalar preserved, hooks and
/// dirty-tracking fire identically). Since v1.4, #783, additive.
///
/// This CLOSES the positional variant's residual holes: a same-count
/// destroy+spawn between get and set can no longer shift rows onto the
/// wrong entities (ids match or the row is skipped — spawned entities
/// absent from the buffer are simply untouched), and an onSet hook
/// mutating the queried set mid-apply downgrades to a skip instead of a
/// partial-commit failure. Within a multi-component row, each component
/// is gated on the ENTITY's liveness and the COMPONENT's presence right
/// before its apply, so a hook that removes a later component — or
/// destroys the whole entity — mid-row skips the affected component(s)
/// cleanly while the row's other still-present components still land;
/// the row never persists half-written. The positional preflight is
/// replaced by a shape check: `buf_len` must be a whole number of rows
/// (count × (8 + stride)).
///
/// Returns 0 = ok (skipped rows/components included — a skip is not an
/// error); -1 = malformed names / unknown component name / buf_len not a
/// whole number of rows / not bound / a GENUINE apply failure on a live,
/// present component (a built-in scene-apply rejection — surfaced, not
/// masked); -2 = int-field refusal (identical to `_batch_set`).
pub export fn labelle_component_batch_set_ids(
    names_json_ptr: [*]const u8,
    names_json_len: usize,
    buf_ptr: ?[*]const u8,
    buf_len: usize,
) i32 {
    const vt = vtable orelse return -1;
    if (names_json_len == 0) return -1;
    const b: []const u8 = if (buf_ptr) |p| p[0..buf_len] else &.{};
    return vt.component_batch_set_ids(names_json_ptr[0..names_json_len], b);
}

/// 1 when entity `id` carries component `name`; 0 otherwise (absent,
/// unknown name, dead entity, not bound).
pub export fn labelle_component_has(id: u64, name_ptr: [*]const u8, name_len: usize) i32 {
    const vt = vtable orelse return 0;
    if (name_len == 0) return 0;
    return vt.component_has(id, name_ptr[0..name_len]);
}

/// Remove component `name` from entity `id`. Idempotent on the
/// component (removing an absent-but-known component is 0). Returns
/// 0 = ok; -1 = unknown component name / unknown-or-dead entity / not
/// bound. Scene built-ins tear down through the engine's typed
/// channels — `removeSprite`/`removeShape` (renderer untrack),
/// `removeTilemap` (frees the decoded side-table runtime) — so a
/// script remove can't strand renderer state.
pub export fn labelle_component_remove(id: u64, name_ptr: [*]const u8, name_len: usize) i32 {
    const vt = vtable orelse return -1;
    if (name_len == 0) return -1;
    return vt.component_remove(id, name_ptr[0..name_len]);
}

/// Query entity ids by component names. `names_json` is a JSON array of
/// component names (`["CloudDrift","Position"]`); the engine iterates a
/// view on the FIRST name and filters the rest, writing the matching ids
/// as a JSON array (`[3,7,12]`) into `out`. Returns the bytes the
/// COMPLETE result requires (snprintf-style sizing — the one deliberate
/// exception to the contract's written-bytes convention, because a query
/// is its only unbounded-cardinality op); 0 = malformed names / not
/// bound. An unknown component name yields the valid empty result `[]`
/// (required = 2). Names resolve over the same space as the component
/// ops — the registry, `Position`, and the scene built-ins (`Sprite`/
/// `Shape`/`Tilemap`/`Camera`/`Image`, with the same registry-precedence
/// gates).
///
/// Writing fills `out` up to `out_cap`, ending at the last whole id, so
/// the written prefix is always valid JSON (same shape as
/// `editor_scene_digest`); a return larger than `out_cap` is how the
/// caller DETECTS truncation — retry with a `required`-sized buffer for
/// the full set. A NULL or zero-capacity `out` is a legal pure sizing
/// probe: nothing is written, the required size still returns.
///
/// Snapshot semantics: the id list is captured at query time, so
/// spawn/destroy while the script walks it is safe (a per-id
/// `labelle_component_get` on a since-destroyed entity returns 0).
pub export fn labelle_query(
    names_json_ptr: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const vt = vtable orelse return 0;
    if (names_json_len == 0) return 0;
    // NULL (legal only alongside cap 0, but tolerated regardless) is the
    // documented sizing probe: an empty destination — required-size
    // computation runs, nothing is written.
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    return vt.query(names_json_ptr[0..names_json_len], buf);
}

/// Emit a game event by name into the buffered event path — the same
/// `game.emit` every Zig script uses, so flows (`OnEvent`), hooks, and
/// other subscribed scripts all see it at this frame's
/// `dispatchEvents`. `name` must be a `GameEvents` union tag; `json` is
/// the variant's payload struct (NULL or empty → `{}`, i.e. all-default
/// fields). VOID-payload variants (the tag declares no payload struct)
/// accept exactly: empty (NULL/len 0), the bytes `{}`, or the bytes
/// `null` — anything else, malformed JSON included, is a parse
/// failure. Returns 0 = ok; -1 = unknown event name / parse failure /
/// the game declares no `GameEvents` union / not bound.
pub export fn labelle_event_emit(
    name_ptr: [*]const u8,
    name_len: usize,
    json_ptr: ?[*]const u8,
    json_len: usize,
) i32 {
    const vt = vtable orelse return -1;
    if (name_len == 0) return -1;
    return vt.event_emit(
        name_ptr[0..name_len],
        optionalJson(json_ptr, json_len, "{}"),
    );
}

/// Declare interest in event `name` (a `GameEvents` union tag). The
/// subscription lands in the PENDING set and takes effect for events
/// emitted after the current tick's drain: `drainEvents` filters
/// against the ACTIVE set only and absorbs pending names at its end.
/// So events already buffered this tick — or emitted later this same
/// tick — are NOT delivered; the next tick's are (no same-tick replay:
/// `engine__tick` fires before scripts run, and a mid-tick subscriber
/// must not receive a past it never subscribed to). Duplicate
/// subscriptions are deduped across both sets. Pre-bind: a safe no-op
/// (the generated main binds before plugin setup, so no real
/// subscriber exists earlier).
pub export fn labelle_event_subscribe(name_ptr: [*]const u8, name_len: usize) void {
    const alloc = bound_allocator orelse return;
    if (name_len == 0) return;
    const name = name_ptr[0..name_len];
    if (isSubscribed(name)) return; // already active
    for (pending_subs.items) |s| {
        if (std.mem.eql(u8, s, name)) return; // already pending
    }
    const copy = alloc.dupe(u8, name) catch return;
    pending_subs.append(alloc, copy) catch {
        alloc.free(copy);
    };
}

/// Drain one pending event: copies the next `"<name> <json>"` entry
/// (FIFO — emission order within and across frames) into `out` and
/// returns bytes WRITTEN; 0 = inbox empty. A real read consumes the
/// entry even when `out_cap` truncates it (POC-pinned behavior) — but
/// no caller ever needs to eat a truncation, because a NULL or
/// zero-capacity `out` is the paired no-consume SIZING PROBE: it
/// returns the NEXT entry's full size (0 = inbox empty) while reading
/// and consuming nothing, so a sizing caller probes, grows its
/// buffer, then polls. An entry is never empty (`"<name> <json>"`
/// carries at least the name), so a probe's non-zero return cannot be
/// confused with inbox-empty. Scripts drain in a `while (poll() > 0)`
/// loop once per tick.
pub export fn labelle_event_poll(out: ?[*]u8, out_cap: usize) usize {
    if (inbox_head >= inbox.items.len) return 0;
    const alloc = bound_allocator orelse return 0;
    const entry = inbox.items[inbox_head];
    // The probe leg: report the pending entry's size, touch nothing.
    const buf = out orelse return entry.len;
    if (out_cap == 0) return entry.len;
    inbox_head += 1;
    const len = @min(entry.len, out_cap);
    @memcpy(buf[0..len], entry[0..len]);
    alloc.free(entry);
    compactInbox();
    return len;
}

/// Reclaim the freed slots head-index popping leaves behind. Fully
/// drained → plain reset; otherwise slide the pending tail to the
/// front once the dead prefix is worth the copy. The in-place slide is
/// what keeps a BUDGETED poller bounded: a script that always leaves a
/// backlog never runs the inbox empty, and without it the backing
/// array would grow every frame even at matched emit/poll throughput.
/// Amortized O(1) per poll — a slide of `pending` entries only happens
/// after at least `pending` (or `inbox_compact_threshold`) dead slots
/// accumulated, and `max_pending_events` caps the slide size anyway.
fn compactInbox() void {
    if (inbox_head == inbox.items.len) {
        inbox.clearRetainingCapacity();
        inbox_head = 0;
        return;
    }
    if (inbox_head < inbox_compact_threshold and inbox_head * 2 < inbox.items.len) return;
    const pending = inbox.items.len - inbox_head;
    std.mem.copyForwards([]u8, inbox.items[0..pending], inbox.items[inbox_head..]);
    inbox.shrinkRetainingCapacity(pending);
    inbox_head = 0;
}

/// Backing capacity of the poll inbox — a test seam (asserts budgeted
/// polling can't grow the storage unboundedly), not part of the C
/// surface.
pub fn inboxCapacity() usize {
    return inbox.capacity;
}

/// Switch to scene `name`. 0 = ok (including a swap deferred on the
/// asset gate — a retry is queued, mirroring `editor_set_scene`),
/// -1 = unknown scene / error / not bound. Validated BEFORE calling
/// `setScene` so a typo'd script request never tears the running scene
/// down.
pub export fn labelle_scene_change(name_ptr: [*]const u8, name_len: usize) i32 {
    const vt = vtable orelse return -1;
    if (name_len == 0) return -1;
    return vt.scene_change(name_ptr[0..name_len]);
}

/// Log through the game's log sink (info level, `[script]`-prefixed so
/// game logs attribute the line). Pre-bind: silently ignored.
pub export fn labelle_log(msg_ptr: [*]const u8, len: usize) void {
    const vt = vtable orelse return;
    if (len == 0) return;
    vt.log(msg_ptr[0..len]);
}

/// The last tick's GAMEPLAY delta-time in seconds — the same scaled dt
/// Zig scripts receive (`engine__tick`'s `.dt`). When the language
/// plugin has stamped the tick (`labelle_time_dt_stamp`), the stamped
/// value is returned verbatim; otherwise — pre-plugin, or a plugin
/// that never stamps — it is reconstructed from the game's own record
/// of the last tick (the `frame_profiler` ring `tick()` feeds every
/// frame): the real frame time × `time_scale`, and 0 while paused. 0
/// before the first tick / pre-bind.
pub export fn labelle_time_dt() f32 {
    const vt = vtable orelse return 0;
    return stamped_dt orelse vt.time_dt();
}

/// Stamp the tick's gameplay delta-time. Called once per tick by the
/// scripting LANGUAGE PLUGIN, with the scaled dt the host handed it,
/// before it runs the frame's scripts — game scripts should not call
/// it. Once a session has stamped, `labelle_time_dt` returns the
/// stamped value exactly, so every script observes the very dt Zig
/// scripts received this tick even when a script changes `time_scale`
/// mid-tick (the profiler reconstruction reads the CURRENT scale and
/// would drift). Pre-bind: silently ignored; bind/unbind reset the
/// stamp with the rest of the session state.
pub export fn labelle_time_dt_stamp(dt: f32) void {
    if (vtable == null) return;
    stamped_dt = dt;
}

// ── Input ────────────────────────────────────────────────────────────
//
// Read-only polling over the game's unified `InputInterface`, valid
// during the plugin's tick (main-thread, like every other op). `key` is
// the backend-agnostic `KeyboardKey` code (the engine enum's integer
// value — the same code Zig scripts pass `game.isKeyDown`); an unknown
// code is simply never down. Mouse coordinates are the same space the
// backend reports to Zig scripts. All three are safe no-ops pre-bind
// (keys read as not-down, the mouse as the origin).

/// 1 while key `key` is held down this frame; 0 otherwise (up, unknown
/// code, or not bound).
pub export fn labelle_input_key_down(key: u32) i32 {
    const vt = vtable orelse return 0;
    return @intFromBool(vt.input_key_down(key));
}

/// 1 on the frame `key` transitions from up to down (the press edge);
/// 0 otherwise (not this frame, unknown code, or not bound).
pub export fn labelle_input_key_pressed(key: u32) i32 {
    const vt = vtable orelse return 0;
    return @intFromBool(vt.input_key_pressed(key));
}

/// Write the current mouse position into `x_out`/`y_out` (either may be
/// NULL to skip that axis). Pre-bind writes (0, 0). The values are the
/// backend's reported cursor coordinates — 0 on platforms/backends with
/// no mouse.
pub export fn labelle_input_mouse(x_out: ?*f32, y_out: ?*f32) void {
    const pos = if (vtable) |vt| vt.input_mouse() else core.Position{};
    if (x_out) |p| p.* = pos.x;
    if (y_out) |p| p.* = pos.y;
}

// ── Plugin commands (contract v1.1 #744 / v1.2 responses #758) ──────

/// Call a named command on a Zig engine PLUGIN — the script-side entry
/// to the handler channel labelle-studio's panels reach through
/// `editor_plugin_command` (editor-bridge v1.7/v1.8): the game's
/// `editorPluginCommand` mixin `emitSync`s `engine__editor_plugin_command`
/// to the handler the plugin registered by subscribing to that event,
/// so ONE registration serves studio panels and every scripting
/// language alike (module doc, "Plugin commands"). `params_json` is the
/// arguments object; NULL or empty (`len == 0`) means `"{}"`. Dispatch
/// is SYNCHRONOUS — the handler has run by the time this returns — and
/// all three strings are borrowed for the call only.
///
/// usize return (v1.2 activates the semantics v1.1 reserved):
/// `plugin_call_unroutable` (`maxInt(usize)`, C's `(size_t)-1`) =
/// unroutable — empty plugin/command, no handler registered in this
/// build, a game shape without the mixin, or not bound; 0 = dispatched
/// into the handler channel with no handler response (fire-and-forward)
/// — OR any dispatched call made in the exact v1.1 shape, see the
/// compat fold below; N = a handler responded via
/// `engine.plugin_command.respond` and the response requires N bytes,
/// written into `out` ALL-OR-NOTHING (only when `N <= out_cap`,
/// `labelle_component_get`-style — a truncated response is useless).
/// Handlers name-filter the broadcast themselves, so a name no plugin
/// claims still returns 0 wherever a handler exists —
/// dispatched-and-ignored is indistinguishable from
/// handled-without-response BY DESIGN.
///
/// ## The v1.1-compat fold (NULL/0)
///
/// `out == NULL && out_cap == 0` — the ONE caller shape the v1.1
/// header sanctioned ("v1.1 never writes to `out`; pass NULL/0") —
/// keeps the exact v1.1 rc contract: a responding dispatch STILL
/// returns 0, never N, so a v1.1-built binding checking `rc == 0`
/// keeps working when a handler it dispatches to grows a response.
/// The response is published all the same — a v1.2 caller without a
/// buffer sizes/reads it through `labelle_plugin_response_fetch`
/// (whose NULL/0 probe is the sanctioned sizing path anyway; probing
/// by re-CALL is forbidden below). The boundary is exactly the
/// promised shape: `out != NULL` with `out_cap == 0` is the v1.2
/// sizing leg (required size returned, nothing written), and a NULL
/// `out` with a nonzero cap — illegal per the conventions block (NULL
/// only together with cap 0) — is tolerated as sizing too, matching
/// `labelle_component_get`'s NULL tolerance.
///
/// Do NOT sizing-probe or cap-retry THIS export: every call executes
/// the handler again. The response is also stored as the call
/// COMPLETES — retry/probe through `labelle_plugin_response_fetch`,
/// which is side-effect-free. Calls may NEST (a handler issuing its own
/// `labelle_plugin_call` mid-dispatch): each call's response travels in
/// per-call storage (no cross-talk with the enclosing call's `out`),
/// and each publishes the store at its own completion — inner first,
/// outer last — so a fetch afterwards reads the OUTERMOST call's
/// outcome. An empty response reads as 0 (no response); handlers ack
/// with `"{}"`. Responses are host-capped at 4096 bytes
/// (`plugin_command.max_response_len`); a caller passing a buffer of
/// that size never needs the fetch.
pub export fn labelle_plugin_call(
    plugin_ptr: [*]const u8,
    plugin_len: usize,
    command_ptr: [*]const u8,
    command_len: usize,
    params_ptr: ?[*]const u8,
    params_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    // Cover the PRE-DISPATCH failure legs (not bound / empty names):
    // they complete this call too, so the previous response dies here —
    // a fetch through them must find nothing, never stale bytes.
    // Dispatched calls don't rely on this clear: `pluginCallImpl`
    // PUBLISHES the store at completion on every outcome (see its doc
    // for the nested-call rationale) — which is what makes fetch's
    // "most recently COMPLETED call" contract hold even when a handler
    // issues its own labelle_plugin_call mid-dispatch.
    response_len = null;
    const vt = vtable orelse return plugin_call_unroutable;
    if (plugin_len == 0 or command_len == 0) return plugin_call_unroutable;
    const n = vt.plugin_call(
        plugin_ptr[0..plugin_len],
        command_ptr[0..command_len],
        optionalJson(params_ptr, params_len, "{}"),
    );
    if (n == 0 or n == plugin_call_unroutable) return n;
    // Responded: the impl deposited the bytes in `response_store` (and
    // set `response_len = n`).
    if (out == null and out_cap == 0) {
        // The v1.1-compat fold (export doc): the exact legacy shape
        // keeps the legacy rc — 0, never the response size — while the
        // publish above still serves labelle_plugin_response_fetch.
        return 0;
    }
    // All-or-nothing into the caller's buffer; NULL out (with a
    // nonzero cap — an illegal-but-tolerated shape) and the non-NULL
    // cap-0 shape both fall through as pure sizing: N returned,
    // nothing written.
    if (out) |p| {
        if (n <= out_cap) @memcpy(p[0..n], response_store[0..n]);
    }
    return n;
}

/// Read the response of the most recently COMPLETED
/// `labelle_plugin_call` — the side-effect-free half of the response
/// channel (since v1.2, #758): the handler is NEVER re-executed, so
/// this is where the shared sizing convention's probe/retry legs live.
/// NULL or zero-capacity `out` is the pure sizing probe; otherwise the
/// write is ALL-OR-NOTHING (`labelle_component_get`-style) and the
/// return is the bytes the complete response requires. 0 = nothing
/// stored: no call yet, the last completed call was unroutable or
/// fire-and-forward (no handler responded, or it responded empty), or
/// not bound. NON-consuming — fetch as many times as needed; the store
/// is replaced/cleared as each `labelle_plugin_call` COMPLETES and on
/// unbind. "Completed" carries the nesting semantics: when a handler
/// itself issues a `labelle_plugin_call`, the inner call publishes
/// first and the enclosing call — completing last — overwrites or
/// clears it, so a fetch made after the whole stack unwinds reads the
/// OUTERMOST call's outcome (a handler that wants the inner response
/// reads it from its own call's `out`, not from a later fetch).
pub export fn labelle_plugin_response_fetch(out: ?[*]u8, out_cap: usize) usize {
    const n = response_len orelse return 0;
    // The mixin folds empty responses to dispatched-no-response, so a
    // stored response is never empty and a non-zero return can't be
    // confused with "nothing stored" (the event_poll probe's argument).
    const p = out orelse return n;
    if (out_cap == 0) return n;
    if (n <= out_cap) @memcpy(p[0..n], response_store[0..n]);
    return n;
}

// ── Implementation ──────────────────────────────────────────────────

/// The documented consumer gate for `Game.GameEvents` (see game.zig):
/// the decl always exists but is `void` for event-less games, so the
/// union check — not `@hasDecl` alone — is what discriminates.
fn gameHasEventsUnion(comptime G: type) bool {
    if (!@hasDecl(G, "GameEvents")) return false;
    return @typeInfo(G.GameEvents) == .@"union";
}

/// Normalize an optional (documented "NULL/len 0") JSON parameter to a
/// slice: NULL or empty selects `default`, the export's documented
/// stand-in payload. NULL must be handled BEFORE any slicing — a null
/// non-optional `[*]const u8` is an invalid ABI value in its own
/// right, len check or no.
fn optionalJson(ptr: ?[*]const u8, len: usize, default: []const u8) []const u8 {
    const p = ptr orelse return default;
    if (len == 0) return default;
    return p[0..len];
}

fn isSubscribed(name: []const u8) bool {
    for (subs.items) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// Comptime: does `T` serialize through `std.json` as AUTHORED data —
/// i.e. would `labelle_component_set`'s deserialize path accept the
/// emitted shape back? Non-exhaustive enums are the renderer-handle
/// idiom (gfx `TextureId`): unnamed values emit as raw integers and are
/// not scene-authorable, so component GET omits such fields — they
/// re-derive from the authored fields on the next set, exactly as the
/// scene loader relies on. Everything else the engine built-ins carry
/// (scalars, strings, exhaustive enums, optionals, tagged unions,
/// nested structs, slices/arrays thereof) round-trips.
fn jsonRoundTrips(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .void => true,
        .@"enum" => |e| e.is_exhaustive,
        .optional => |o| jsonRoundTrips(o.child),
        .array => |a| jsonRoundTrips(a.child),
        .pointer => |p| p.size == .slice and jsonRoundTrips(p.child),
        .@"struct" => |s| blk: {
            for (s.fields) |f| {
                if (!jsonRoundTrips(f.type)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) break :blk false;
            for (u.fields) |f| {
                if (f.type != void and !jsonRoundTrips(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Serialize + queue one tapped event. Drop-newest past the cap (see
/// `max_pending_events`); allocation failures drop silently — an event
/// tap must never take the frame down.
fn enqueueEvent(alloc: std.mem.Allocator, name: []const u8, data: anytype) void {
    if (inbox.items.len - inbox_head >= max_pending_events) return;
    if (comptime @TypeOf(data) == void) {
        appendInboxEntry(alloc, name, "{}");
    } else {
        const payload = std.json.Stringify.valueAlloc(alloc, data, .{}) catch return;
        defer alloc.free(payload);
        appendInboxEntry(alloc, name, payload);
    }
}

fn appendInboxEntry(alloc: std.mem.Allocator, name: []const u8, payload: []const u8) void {
    const entry = std.fmt.allocPrint(alloc, "{s} {s}", .{ name, payload }) catch return;
    inbox.append(alloc, entry) catch alloc.free(entry);
}

/// One instantiation per concrete Game-pointer type. The container-level
/// `var` gives the plain vtable fns a place to find the typed pointer
/// without any runtime type erasure gymnastics — same shape as
/// `editor_api.Holder`.
fn Holder(comptime GP: type) type {
    return struct {
        const G = @typeInfo(GP).pointer.child;
        const Entity = G.EntityType;
        /// The game's own registry — the same `names()`/`getType()`
        /// surface the JSONC scene bridge dispatches over, so the
        /// contract resolves exactly the set of components scenes can
        /// author (plus the built-ins below, which the bridge also
        /// special-cases). Registries without `getType` (the minimal
        /// `GameWith` shape) are fine: `names()` is empty there, so the
        /// `inline for` bodies that reference `getType` never
        /// instantiate.
        const Components = G.ComponentRegistry;
        /// The scene loader's component-apply machinery, instantiated
        /// for this Game — built-in `set`s reuse its per-name apply fns
        /// VERBATIM (`applySprite`/…), so a script's `Sprite` write is
        /// the scene loader's own code path, not a reimplementation.
        const Apply = component_apply.ComponentApply(G, Components);

        /// `true` when the game's registry claims `comp_name` for
        /// itself. The `@hasDecl` belt mirrors `game.zig`'s
        /// `camera_is_builtin`, keeping registry shapes that predate a
        /// `has` decl compiling (they can't shadow built-ins either
        /// way).
        fn registryHas(comptime comp_name: []const u8) bool {
            return @hasDecl(Components, "has") and Components.has(comp_name);
        }

        const BuiltinComp = struct { name: []const u8, T: type };
        /// The five scene BUILT-INS (`jsonc/component_apply.zig`'s
        /// dedicated branches), with the scene loader's exact
        /// precedence: `Sprite`/`Shape` are unconditional (they shadow
        /// a same-named registry entry in the scene path too);
        /// `Tilemap`/`Camera`/`Image` are compiled out when the project
        /// registered its own component of that name — the mirror of
        /// the loader's `!Components.has(…)` gates (and game.zig's
        /// `camera_is_builtin`), so the registry loop below owns the
        /// name exactly when the scene's generic dispatch would.
        const builtin_comps: []const BuiltinComp = blk: {
            var list: []const BuiltinComp = &.{
                .{ .name = "Sprite", .T = G.SpriteComp },
                .{ .name = "Shape", .T = G.ShapeComp },
            };
            if (!registryHas("Tilemap")) list = list ++ &[_]BuiltinComp{.{ .name = "Tilemap", .T = G.TilemapComp }};
            if (!registryHas("Camera")) list = list ++ &[_]BuiltinComp{.{ .name = "Camera", .T = G.CameraComp }};
            if (!registryHas("Image")) list = list ++ &[_]BuiltinComp{.{ .name = "Image", .T = G.ImageComp }};
            break :blk list;
        };

        var game: GP = undefined;

        const vtable_impl = VTable{
            .entity_create = &entityCreateImpl,
            .entity_destroy = &entityDestroyImpl,
            .entity_find = &entityFindImpl,
            .prefab_spawn = &prefabSpawnImpl,
            .component_set = &componentSetImpl,
            .component_get = &componentGetImpl,
            .component_get_packed = &componentGetPackedImpl,
            .component_set_packed = &componentSetPackedImpl,
            .component_batch_get = &componentBatchGetImpl,
            .component_batch_set = &componentBatchSetImpl,
            .component_batch_get_ids = &componentBatchGetIdsImpl,
            .component_batch_set_ids = &componentBatchSetIdsImpl,
            .component_has = &componentHasImpl,
            .component_remove = &componentRemoveImpl,
            .query = &queryImpl,
            .event_emit = &eventEmitImpl,
            .scene_change = &sceneChangeImpl,
            .log = &logImpl,
            .time_dt = &timeDtImpl,
            .input_key_down = &inputKeyDownImpl,
            .input_key_pressed = &inputKeyPressedImpl,
            .input_mouse = &inputMouseImpl,
            .plugin_call = &pluginCallImpl,
        };

        // ── Entities ─────────────────────────────────────────────

        fn entityCreateImpl() u64 {
            return entityId(game.createEntity());
        }

        fn entityDestroyImpl(id: u64) void {
            const ent = castEntity(id) orelse return;
            // Liveness-check first: `destroyEntity` runs the full
            // cascade (hooks, tombstones) and debug builds assert on
            // already-dead ids — a script's stale handle must be a
            // no-op, not a panic.
            if (!game.ecs_backend.entityExists(ent)) return;
            game.destroyEntity(ent);
        }

        /// Comptime-resolved `(component-type, string-field)` for
        /// `entity_find`: a registry component named `Name` or `Tag`
        /// carrying a `[]const u8` field (`name`/`value`/`tag`). `null`
        /// when the game registers no such component — the RFC's "by the
        /// Name/tag component IF ONE EXISTS" — which makes
        /// `labelle_entity_find` a zero-cost always-0 no-op there. The
        /// convention is deliberately narrow (a single well-known
        /// component) so the future language sub-modules bind ONE name;
        /// widening it is a contract change, not an ad-hoc per-game one.
        const name_lookup: ?struct { T: type, field: []const u8 } = blk: {
            if (!@hasDecl(Components, "names") or !@hasDecl(Components, "getType")) break :blk null;
            for (Components.names()) |n| {
                if (!std.mem.eql(u8, n, "Name") and !std.mem.eql(u8, n, "Tag")) continue;
                const T = Components.getType(n);
                if (@typeInfo(T) != .@"struct") continue;
                for (@typeInfo(T).@"struct".fields) |f| {
                    if (f.type != []const u8) continue;
                    if (std.mem.eql(u8, f.name, "name") or
                        std.mem.eql(u8, f.name, "value") or
                        std.mem.eql(u8, f.name, "tag"))
                        break :blk .{ .T = T, .field = f.name };
                }
            }
            break :blk null;
        };

        fn entityFindImpl(name: []const u8) u64 {
            if (comptime name_lookup == null) return 0;
            const lk = comptime name_lookup.?;
            // Snapshot the view at call time (matches `query`): a
            // per-id read on a since-destroyed entity is handled by the
            // caller's later ops, not this scan.
            var v = game.ecs_backend.view(.{lk.T}, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                const comp = game.getComponent(ent, lk.T) orelse continue;
                if (std.mem.eql(u8, @field(comp.*, lk.field), name)) return entityId(ent);
            }
            return 0;
        }

        // ── Prefabs ──────────────────────────────────────────────

        fn prefabSpawnImpl(name: []const u8, params_json: []const u8) u64 {
            var pos = core.Position{};
            if (params_json.len != 0) {
                // Positional params only in v1. Parsed with the game
                // allocator and freed immediately — the struct is
                // pointer-free, so nothing escapes the Parsed arena.
                const SpawnParams = struct { x: f32 = 0, y: f32 = 0 };
                const parsed = std.json.parseFromSlice(
                    SpawnParams,
                    game.allocator,
                    params_json,
                    .{ .ignore_unknown_fields = true },
                ) catch return 0;
                defer parsed.deinit();
                pos = .{ .x = parsed.value.x, .y = parsed.value.y };
            }
            // `spawnPrefab` resolves through the prefab cache the JSONC
            // scene bridge attached (spawn_prefab_fn); before any JSONC
            // scene load it logs + returns null, which maps to 0 here.
            const ent = game.spawnPrefab(name, pos) orelse return 0;
            return entityId(ent);
        }

        // ── Components (serde dispatch over the registry) ────────

        fn componentSetImpl(id: u64, name: []const u8, json: []const u8) i32 {
            const ent = castEntity(id) orelse return -1;
            if (!game.ecs_backend.entityExists(ent)) return -1;
            // Position — built-in for every game (the RFC's own query/
            // set examples use it). Routed through `setPosition` so the
            // render pipeline's dirty-tracking fires, exactly like
            // `editor_set_entity_position`. Pointer-free: parses with
            // no allocation.
            if (std.mem.eql(u8, name, "Position")) {
                const pos = std.json.parseFromSliceLeaky(
                    core.Position,
                    componentAlloc(),
                    json,
                    .{ .ignore_unknown_fields = true },
                ) catch return -1;
                game.setPosition(ent, pos);
                return 0;
            }
            // Scene built-ins — dispatched BEFORE the registry loop so
            // the contract matches the scene loader's precedence
            // (`builtin_comps`), and through its very apply fns so a
            // script's `Sprite`/`Camera`/… write is indistinguishable
            // from a scene author's.
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    return setBuiltinComponent(spec.name, ent, json);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    // Slice-bearing fields land in the nested-entity
                    // arena — the scene bridge's exact lifetime
                    // convention (freed atomically on scene change).
                    // `alloc_always`, never the slice default
                    // alloc_if_needed: an unescaped string field would
                    // otherwise BORROW the caller's json — a buffer
                    // valid only during this call — and the stored
                    // component's slices would dangle on return.
                    const comp = std.json.parseFromSliceLeaky(
                        T,
                        componentAlloc(),
                        json,
                        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
                    ) catch return -1;
                    // `setComponent`, not the backend add: it fires
                    // onSet/onAdd, roster invalidation, and preview
                    // telemetry — a script write must be
                    // indistinguishable from a Zig script's.
                    game.setComponent(ent, comp);
                    return 0;
                }
            }
            return -1;
        }

        /// Set one scene built-in by routing the payload through the
        /// scene loader's own apply fn. The apply fns consume a parsed
        /// JSONC `Value`; the tree is parsed with a call-scoped arena —
        /// `deserialize` copies everything it keeps (strings intern,
        /// other slices land in `componentAlloc()`), so nothing escapes
        /// it. -1 on parse/deserialize failure leaves the entity
        /// untouched: the apply is all-or-nothing.
        fn setBuiltinComponent(comptime comp_name: []const u8, ent: Entity, json: []const u8) i32 {
            var arena = std.heap.ArenaAllocator.init(game.allocator);
            defer arena.deinit();
            var parser = jsonc.JsoncParser.init(arena.allocator(), json);
            const value = parser.parse() catch return -1;
            // The JSONC parser stops after ONE value (consuming any
            // trailing whitespace/comments — JSONC trivia); bytes left
            // past it mean the payload wasn't a single JSON document.
            // That is the contract's malformed-JSON -1, decided BEFORE
            // the apply so the entity stays untouched — std.json's
            // end-of-document check refuses the same shapes on the
            // registry path by itself.
            if (parser.pos != json.len) return -1;
            const applied = if (comptime std.mem.eql(u8, comp_name, "Sprite"))
                Apply.applySprite(game, ent, value)
            else if (comptime std.mem.eql(u8, comp_name, "Shape"))
                Apply.applyShape(game, ent, value)
            else if (comptime std.mem.eql(u8, comp_name, "Tilemap"))
                Apply.applyTilemap(game, ent, value)
            else if (comptime std.mem.eql(u8, comp_name, "Camera"))
                Apply.applyCamera(game, ent, value)
            else
                Apply.applyImage(game, ent, value);
            return if (applied) 0 else -1;
        }

        fn componentGetImpl(id: u64, name: []const u8, out: []u8) usize {
            const ent = castEntity(id) orelse return 0;
            // Liveness guard, same as set/remove: `getComponent` is a
            // raw sparse lookup on real backends, so a stale script id
            // held past `labelle_entity_destroy` could otherwise read a
            // dead — or recycled — entity's row. Dead → 0 (absent).
            if (!game.ecs_backend.entityExists(ent)) return 0;
            if (std.mem.eql(u8, name, "Position")) {
                const pos = game.getComponent(ent, core.Position) orelse return 0;
                return stringifyInto(pos.*, out);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    const comp = game.getComponent(ent, spec.T) orelse return 0;
                    if (comptime std.mem.eql(u8, spec.name, "Camera")) {
                        // `tag` is an inline `[16:0]u8`; serialize the
                        // STRING view so the output round-trips through
                        // the apply branch's `setTagSlice` (the generic
                        // path would emit a NUL-padded byte array).
                        return stringifyInto(.{
                            .zoom = comp.zoom,
                            .viewport = comp.viewport,
                            .tag = comp.tagSlice(),
                        }, out);
                    }
                    // Omit renderer-handle fields (gfx `Sprite.texture`)
                    // — GET mirrors what a scene could have authored.
                    return stringifyFilteredInto(comp.*, out);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    const comp = game.getComponent(ent, T) orelse return 0;
                    return stringifyInto(comp.*, out);
                }
            }
            return 0;
        }

        /// PACKED twin of `componentGetImpl`: the exact same name-dispatch
        /// (Position → scene built-ins → registry `inline for`), but each
        /// arm writes the binary record via `packInto` instead of JSON.
        /// `packInto` self-selects: a component whose every field is a
        /// supported scalar produces a real record; anything else yields
        /// the single 0xFF sentinel byte, so the binding transparently
        /// falls back to the JSON path for those. Scene BUILT-INS emit
        /// the sentinel UNCONDITIONALLY — even a scalar-only one — so
        /// GET agrees with the packed SET's built-in refusal (#782,
        /// see the arm below).
        fn componentGetPackedImpl(id: u64, name: []const u8, out: []u8) usize {
            const ent = castEntity(id) orelse return 0;
            if (!game.ecs_backend.entityExists(ent)) return 0;
            if (std.mem.eql(u8, name, "Position")) {
                const pos = game.getComponent(ent, core.Position) orelse return 0;
                return packInto(pos.*, out);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    if (game.getComponent(ent, spec.T) == null) return 0;
                    // Built-ins take the 0xFF/JSON path in BOTH directions
                    // (#782, GET/SET symmetry): the packed SET must refuse
                    // them — a built-in write routes through the scene
                    // loader's JSON apply fns (renderer tracking, tag
                    // interning), so a packed set would only re-serialize
                    // to JSON, gaining nothing — and GET must AGREE, so
                    // even a scalar-only built-in (real ones carry
                    // handles/strings, but the shape is legal) emits the
                    // sentinel here instead of a record the paired set
                    // would then bounce back to JSON. Absent/dead keep
                    // component_get's 0 sentinel above.
                    if (out.len >= 1) out[0] = 0xFF;
                    return 1;
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    const comp = game.getComponent(ent, T) orelse return 0;
                    return packInto(comp.*, out);
                }
            }
            return 0;
        }

        /// PACKED twin of `componentSetImpl`: the same name-dispatch, but
        /// each arm decodes the binary record into a DEFAULT-initialized
        /// component (REPLACE semantics — absent fields keep their struct
        /// defaults, exactly like the JSON set's `ignore_unknown_fields`
        /// path) and routes through the same `setPosition`/`setComponent`
        /// as the JSON path so hooks/dirty-tracking fire identically.
        /// Returns -1 (host refuses → binding falls back to JSON) for the
        /// scene built-ins and for any registry component that is not a
        /// scalar-only, default-constructible struct.
        fn componentSetPackedImpl(id: u64, name: []const u8, buf: []const u8) i32 {
            const ent = castEntity(id) orelse return -1;
            if (!game.ecs_backend.entityExists(ent)) return -1;
            // A record the binding itself marked unpackable — refuse so it
            // falls back to JSON. (The binding never sends this, but a raw
            // caller might.)
            if (buf.len >= 1 and buf[0] == 0xFF) return -1;
            if (std.mem.eql(u8, name, "Position")) {
                var pos = core.Position{};
                if (!applyPacked(core.Position, &pos, buf)) return -1;
                game.setPosition(ent, pos);
                return 0;
            }
            // Scene built-ins go through the scene-loader apply fns (JSON
            // only) — refuse the packed path for them.
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) return -1;
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (comptime packableStruct(T)) {
                        var comp: T = .{};
                        if (!applyPacked(T, &comp, buf)) return -1;
                        game.setComponent(ent, comp);
                        return 0;
                    } else {
                        // Non-scalar or non-default-constructible: the
                        // packed path can't represent it — JSON fallback.
                        return -1;
                    }
                }
            }
            return -1;
        }

        fn componentHasImpl(id: u64, name: []const u8) i32 {
            const ent = castEntity(id) orelse return 0;
            // Liveness guard — see componentGetImpl. Dead → 0 (absent).
            if (!game.ecs_backend.entityExists(ent)) return 0;
            if (std.mem.eql(u8, name, "Position")) {
                return @intFromBool(game.hasComponent(ent, core.Position));
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    return @intFromBool(game.hasComponent(ent, spec.T));
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    return @intFromBool(game.hasComponent(ent, T));
                }
            }
            return 0;
        }

        fn componentRemoveImpl(id: u64, name: []const u8) i32 {
            const ent = castEntity(id) orelse return -1;
            if (!game.ecs_backend.entityExists(ent)) return -1;
            // Absent-but-known is the documented idempotent 0 — and it
            // must return WITHOUT calling `removeComponent`, which
            // fires `T.onRemove` unconditionally: a remove the entity
            // never had would leak a false hook side effect.
            if (std.mem.eql(u8, name, "Position")) {
                if (!game.hasComponent(ent, core.Position)) return 0;
                game.removeComponent(ent, core.Position);
                return 0;
            }
            // Scene built-ins tear down through the engine's TYPED
            // channels, not bare `removeComponent`: `removeSprite` /
            // `removeShape` untrack the renderer, `removeTilemap` frees
            // the decoded side-table runtime. Same absent-but-known
            // idempotence guard as the registry path (and those typed
            // removes would untrack/backend-remove unconditionally).
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    if (!game.hasComponent(ent, spec.T)) return 0;
                    if (comptime std.mem.eql(u8, spec.name, "Sprite")) {
                        game.removeSprite(ent);
                    } else if (comptime std.mem.eql(u8, spec.name, "Shape")) {
                        game.removeShape(ent);
                    } else if (comptime std.mem.eql(u8, spec.name, "Tilemap")) {
                        game.removeTilemap(ent);
                    } else {
                        // Camera / Image are plain data components; the
                        // generic remove (with its onRemove gate) is the
                        // whole teardown.
                        game.removeComponent(ent, spec.T);
                    }
                    return 0;
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (!game.hasComponent(ent, T)) return 0;
                    game.removeComponent(ent, T);
                    return 0;
                }
            }
            return -1;
        }

        // ── Query ────────────────────────────────────────────────

        fn queryImpl(names_json: []const u8, out: []u8) usize {
            // The names array is transient: parse with the game
            // allocator, freed on return.
            const parsed = std.json.parseFromSlice(
                []const []const u8,
                game.allocator,
                names_json,
                .{},
            ) catch return 0;
            defer parsed.deinit();
            const names = parsed.value;
            if (names.len == 0) return writeEmptyArray(out);
            // Comptime-dispatch the FIRST name to a typed view; the
            // rest filter per-entity by name below. Scene built-ins
            // resolve here too (before the registry, same precedence
            // as the component ops) so `has`/`query` agree on the
            // name space.
            if (std.mem.eql(u8, names[0], "Position")) {
                return runQuery(core.Position, names[1..], out);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, names[0], spec.name)) {
                    return runQuery(spec.T, names[1..], out);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, names[0], comp_name)) {
                    return runQuery(Components.getType(comp_name), names[1..], out);
                }
            }
            // Unknown first name: a valid, empty result — not an error.
            // Matches `labelle_component_has`'s "unknown = absent" read
            // of names that simply aren't in this game's registry.
            return writeEmptyArray(out);
        }

        fn runQuery(comptime T: type, rest: []const []const u8, out: []u8) usize {
            // An unknown FILTER name can never match — same empty
            // result as an unknown first name, decided up front so the
            // view isn't walked for nothing.
            for (rest) |rn| {
                if (!nameResolvable(rn)) return writeEmptyArray(out);
            }
            // snprintf-style: write up to the cap, RETURN the bytes the
            // complete result requires. A cap under 2 can't hold even
            // `[]`, so it degrades to a pure sizing pass (writes
            // nothing) — the NULL/cap-0 probe the export documents.
            var writing = out.len >= 2;
            // Reserve the closing `]` so id truncation can never eat
            // the byte that keeps the JSON valid (digest pattern).
            const body = if (writing) out[0 .. out.len - 1] else out;
            var cur: usize = 0;
            if (writing) appendLit(body, &cur, "[") catch unreachable;
            var required: usize = 2; // the brackets, matches present or not
            var first = true;
            var v = game.ecs_backend.view(.{T}, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                const matches = blk: {
                    for (rest) |rn| {
                        if (!hasByName(ent, rn)) break :blk false;
                    }
                    break :blk true;
                };
                if (!matches) continue;
                const id = entityId(ent);
                required += idJsonLen(id, first);
                if (writing) {
                    const mark = cur;
                    writeIdJson(body, &cur, id, first) catch {
                        // Doesn't fit — roll back this id (and its
                        // comma); the `]` below keeps the truncated
                        // list valid JSON. Keep ITERATING though: the
                        // remaining ids still count toward `required`,
                        // which is what lets the caller detect the
                        // truncation and retry right-sized.
                        cur = mark;
                        writing = false;
                    };
                }
                first = false;
            }
            if (out.len >= 2) out[cur] = ']';
            return required;
        }

        /// Serialized length of one id in the result array — its digits
        /// plus the separating comma — WITHOUT writing it: this is how
        /// the past-the-cap ids contribute to the required size
        /// cheaply.
        fn idJsonLen(id: u64, first: bool) usize {
            var digits: usize = 1;
            var v = id;
            while (v >= 10) : (v /= 10) digits += 1;
            return digits + @intFromBool(!first);
        }

        fn writeIdJson(buf: []u8, cur: *usize, id: u64, first: bool) error{NoSpace}!void {
            if (!first) try appendLit(buf, cur, ",");
            try appendFmt(buf, cur, "{d}", .{id});
        }

        /// Runtime component name → "is it dispatchable at all".
        fn nameResolvable(name: []const u8) bool {
            if (std.mem.eql(u8, name, "Position")) return true;
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) return true;
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) return true;
            }
            return false;
        }

        /// Runtime component name → hasComponent on the resolved type.
        fn hasByName(ent: Entity, name: []const u8) bool {
            if (std.mem.eql(u8, name, "Position")) {
                return game.hasComponent(ent, core.Position);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    return game.hasComponent(ent, spec.T);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    return game.hasComponent(ent, Components.getType(comp_name));
                }
            }
            return false;
        }

        /// Runtime component name → "may this component ride the f32 batch
        /// stream". False when the resolved type carries ANY int-typed
        /// field: i64/u64 values would silently corrupt through the f32
        /// coercion (24-bit mantissa), so the batch path refuses them
        /// outright (`batch_int_refused` / -2) — the packed per-entity
        /// codec carries ints losslessly instead. f32/f64 and bool fields
        /// are fine; non-scalar fields are skipped by the codec and don't
        /// disqualify. Unknown names are vacuously eligible — the
        /// resolvability checks own that outcome.
        fn nameBatchEligible(name: []const u8) bool {
            if (std.mem.eql(u8, name, "Position")) {
                return comptime batchEligible(core.Position);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    return comptime batchEligible(spec.T);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    return comptime batchEligible(Components.getType(comp_name));
                }
            }
            return true;
        }

        // ── Batched query codec ──────────────────────────────────
        //
        // The whole-query fast path: one `_batch_get` and one `_batch_set`
        // per tick move ALL matching entities' scalar component data across
        // the boundary as a flat f32 buffer, instead of 4 per-entity FFI
        // crossings (get_into ×2 + set_from ×2). Both re-resolve the query
        // the same way (`queryImpl`'s view-on-first-name, filter-the-rest),
        // so get and set walk the SAME entities in the SAME order — the
        // positional f32 layout depends on that order agreeing.

        fn componentBatchGetImpl(names_json: []const u8, out: []u8) usize {
            return batchGetDispatch(false, names_json, out);
        }

        /// The id-tagged twin (v1.4): the identical walk, each row
        /// prefixed with the entity's u64 id.
        fn componentBatchGetIdsImpl(names_json: []const u8, out: []u8) usize {
            return batchGetDispatch(true, names_json, out);
        }

        fn batchGetDispatch(comptime with_ids: bool, names_json: []const u8, out: []u8) usize {
            const parsed = std.json.parseFromSlice(
                []const []const u8,
                game.allocator,
                names_json,
                .{},
            ) catch return 0;
            defer parsed.deinit();
            const names = parsed.value;
            if (names.len == 0) return 0;
            if (std.mem.eql(u8, names[0], "Position")) {
                return runBatchGet(core.Position, with_ids, names, out);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, names[0], spec.name)) {
                    return runBatchGet(spec.T, with_ids, names, out);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, names[0], comp_name)) {
                    return runBatchGet(Components.getType(comp_name), with_ids, names, out);
                }
            }
            // Unknown first name → an empty (count-0) result, not an error —
            // mirrors queryImpl's unknown-name handling.
            return writeBatchCount0(out);
        }

        fn runBatchGet(comptime ViewT: type, comptime with_ids: bool, names: []const []const u8, out: []u8) usize {
            // Int-typed fields cannot ride the f32 stream without silent
            // corruption — refuse the whole batch before any other outcome
            // (see `batch_int_refused`).
            for (names) |nm| {
                if (!nameBatchEligible(nm)) return batch_int_refused;
            }
            // An unknown FILTER name can never match — empty result, decided
            // before the view walk (queryImpl's precedent).
            for (names[1..]) |rn| {
                if (!nameResolvable(rn)) return writeBatchCount0(out);
            }
            var count: u32 = 0;
            var pos: usize = 4; // reserve the u32 count header
            var v = game.ecs_backend.view(.{ViewT}, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                const matches = blk: {
                    for (names[1..]) |rn| {
                        if (!hasByName(ent, rn)) break :blk false;
                    }
                    break :blk true;
                };
                if (!matches) continue;
                count += 1;
                // The id-tagged variant leads each row with the entity's
                // u64 id (little-endian, `batch_id_row_prefix` bytes) —
                // what `_batch_set_ids` matches rows by.
                if (comptime with_ids) {
                    if (pos + 8 <= out.len) {
                        std.mem.writeInt(u64, out[pos..][0..8], entityId(ent), .little);
                    }
                    pos += 8;
                }
                // Each named component's scalar fields as f32, in name order
                // then struct-declaration field order. `pos` advances even
                // past the cap so the return is the full required size —
                // the binding grows and retries (snprintf-style).
                for (names) |nm| writeEntityFloats(ent, nm, out, &pos);
            }
            if (out.len >= 4) std.mem.writeInt(u32, out[0..4], count, .little);
            return pos;
        }

        /// Write one entity's component's scalar fields as raw f32 (runtime
        /// name → comptime type dispatch, same name space as the component
        /// ops). The query guaranteed the component is present; a null read
        /// is defended as zero fields.
        fn writeEntityFloats(ent: Entity, name: []const u8, out: []u8, pos: *usize) void {
            if (std.mem.eql(u8, name, "Position")) {
                if (game.getComponent(ent, core.Position)) |cmp| {
                    packFloatsInto(core.Position, cmp.*, out, pos);
                }
                return;
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    if (game.getComponent(ent, spec.T)) |cmp| {
                        packFloatsInto(spec.T, cmp.*, out, pos);
                    }
                    return;
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (game.getComponent(ent, T)) |cmp| {
                        packFloatsInto(T, cmp.*, out, pos);
                    }
                    return;
                }
            }
        }

        fn componentBatchSetImpl(names_json: []const u8, buf: []const u8) i32 {
            const parsed = std.json.parseFromSlice(
                []const []const u8,
                game.allocator,
                names_json,
                .{},
            ) catch return -1;
            defer parsed.deinit();
            const names = parsed.value;
            if (names.len == 0) return -1;
            if (std.mem.eql(u8, names[0], "Position")) {
                return runBatchSet(core.Position, names, buf);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, names[0], spec.name)) {
                    return runBatchSet(spec.T, names, buf);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, names[0], comp_name)) {
                    return runBatchSet(Components.getType(comp_name), names, buf);
                }
            }
            return -1;
        }

        fn runBatchSet(comptime ViewT: type, names: []const []const u8, buf: []const u8) i32 {
            // Same int-field refusal as the get side, as -2 in this i32
            // return (see `batch_int_refused`).
            for (names) |nm| {
                if (!nameBatchEligible(nm)) return -2;
            }
            for (names[1..]) |rn| {
                if (!nameResolvable(rn)) return -1;
            }
            // PREFLIGHT — the positional-coupling guard, decided BEFORE any
            // write: walk the re-resolved query once, summing the stream
            // bytes its entities require, and refuse on any disagreement
            // with the incoming buffer (spawn/destroy since the paired get,
            // or a caller-mis-sized buffer). A refused batch_set performs
            // NO writes — there is no partial-commit-then-refuse, so the
            // documented "re-run batch_get and recompute" retry can never
            // double-apply a prefix.
            var expected: usize = 0;
            {
                var pre = game.ecs_backend.view(.{ViewT}, .{});
                defer pre.deinit();
                while (pre.next()) |ent| {
                    const matches = blk: {
                        for (names[1..]) |rn| {
                            if (!hasByName(ent, rn)) break :blk false;
                        }
                        break :blk true;
                    };
                    if (!matches) continue;
                    for (names) |nm| expected += nameStreamBytes(nm);
                }
            }
            if (expected != buf.len) return -1;
            // APPLY — the same walk again (same view construction, so the
            // order agrees with the preflight and with batch_get).
            var pos: usize = 0; // set buffer has NO header — pure f32 stream
            var v = game.ecs_backend.view(.{ViewT}, .{});
            defer v.deinit();
            while (v.next()) |ent| {
                const matches = blk: {
                    for (names[1..]) |rn| {
                        if (!hasByName(ent, rn)) break :blk false;
                    }
                    break :blk true;
                };
                if (!matches) continue;
                for (names) |nm| {
                    // ZERO-WIDTH components contribute no stream bytes —
                    // they are query FILTERS (all their fields are
                    // non-scalar, e.g. string-only), so there is nothing
                    // to write back: skip the apply entirely rather than
                    // RMW-re-apply the unchanged value, which would fire
                    // onSet hooks and dirty-tracking for no data (#782).
                    // The preflight above already sized them at 0.
                    if (nameStreamBytes(nm) == 0) continue;
                    if (!applyEntityFloats(ent, nm, buf, &pos)) return -1;
                }
            }
            // Belt on top of the preflight: the apply consumed exactly the
            // stream the preflight sized.
            if (pos != buf.len) return -1;
            return 0;
        }

        /// The id-tagged batch write (v1.4, #783): `buf` is rows of
        /// `[u64 id][stride × f32]` (the exact layout `_batch_get_ids`
        /// emitted, minus the count header), applied BY ID — no view
        /// walk, no positional trust. Per row: resolve the embedded id;
        /// a row whose entity is dead/unknown — or no longer carries
        /// every named component at row START (it left the query since
        /// the get) — is SKIPPED whole, its floats consumed; live
        /// matching rows apply through the same RMW channels as the
        /// positional set (`applyEntityFloats`).
        ///
        /// RECYCLED-ID SAFETY (#788 review): the embedded id is the
        /// FULL backend entity handle, not a bare index — on the
        /// production zig-ecs adapter `Entity = u32` packs index +
        /// generation (version), and `entityExists` is the adapter's
        /// generational `valid()`. So a row carrying a STALE handle
        /// whose slot was recycled to a new entity fails the
        /// `entityExists` gate (the new occupant has a different
        /// generation) and is skipped — it can never write to the new
        /// occupant. Matching-by-full-handle IS the generational match;
        /// the only residual is a backend that reuses the identical
        /// index+generation (generation wrap, or a non-generational
        /// handle), which the entityExists + per-name presence gate
        /// still degrades to a same-entity write rather than a
        /// cross-entity one.
        ///
        /// PARTIAL-COMMIT SAFETY (#788 review): a multi-component row's
        /// components are RESOLVED (presence-checked) up front, and before
        /// EACH component's apply both the ENTITY's liveness
        /// (`entityExists`) and the COMPONENT's presence (`hasByName`) are
        /// re-checked. So if an earlier component's onSet hook, mid-row:
        ///   - REMOVES a later named component (entity still alive) — that
        ///     component is skipped (its floats consumed to keep the
        ///     stream aligned); the row's other still-present components
        ///     still land, the removed one stays removed (the hook wins);
        ///   - DESTROYS the whole entity — the rest of the row is skipped
        ///     (no apply touches the dead entity); nothing it held
        ///     persists, so there is no half-written entity.
        /// Both are expected SKIPS, not errors. A false from
        /// `applyEntityFloats` AFTER those two checks pass is a genuine
        /// apply failure (a built-in scene-apply rejection) and is
        /// surfaced as -1, never masked as success. Rows are independent;
        /// `pos` re-anchors at each row boundary. The positional
        /// preflight's place is taken by a SHAPE check: `buf.len` must be
        /// a whole number of rows.
        fn componentBatchSetIdsImpl(names_json: []const u8, buf: []const u8) i32 {
            const parsed = std.json.parseFromSlice(
                []const []const u8,
                game.allocator,
                names_json,
                .{},
            ) catch return -1;
            defer parsed.deinit();
            const names = parsed.value;
            if (names.len == 0) return -1;
            // Same refusal ladder as the positional set: int-carrying
            // components -2, unresolvable names -1 (ANY name here — with
            // no view dispatch the first name has no special role).
            for (names) |nm| {
                if (!nameBatchEligible(nm)) return -2;
            }
            for (names) |nm| {
                if (!nameResolvable(nm)) return -1;
            }
            var stride: usize = 0;
            for (names) |nm| stride += nameStreamBytes(nm);
            const row_size = batch_id_row_prefix + stride;
            if (buf.len % row_size != 0) return -1;
            var pos: usize = 0;
            while (pos < buf.len) {
                const id = std.mem.readInt(u64, buf[pos..][0..8], .little);
                pos += batch_id_row_prefix;
                const row_end = pos + stride;
                // Re-anchoring at the row boundary is what keeps rows
                // independent: skipped rows and mid-row hook effects
                // alike leave the NEXT row's floats aligned.
                defer pos = row_end;
                const ent = castEntity(id) orelse continue;
                // Generational entityExists gate (see the recycled-id
                // note above): a stale/recycled handle skips here.
                if (!game.ecs_backend.entityExists(ent)) continue; // vanished → skip
                // Resolve the WHOLE row up front: an entity that no
                // longer carries every named component left the query
                // since the get — skip the whole row atomically (no
                // component of it is applied).
                const still_matches = blk: {
                    for (names) |nm| {
                        if (!hasByName(ent, nm)) break :blk false;
                    }
                    break :blk true;
                };
                if (!still_matches) continue; // left the query → skip
                for (names) |nm| {
                    const nb = nameStreamBytes(nm);
                    // Zero-width components are filters — no data, no
                    // re-apply (#782, same skip as the positional set).
                    if (nb == 0) continue;
                    // LIVENESS recheck (#788 review): an earlier
                    // component's onSet hook may have DESTROYED the whole
                    // entity mid-row (not just removed a sibling). Applying
                    // a later component to a dead entity is unsafe on a
                    // backend whose lookups don't gate on liveness — stop
                    // the row here (the defer realigns pos to the next
                    // row). The entity is gone, so nothing it held is
                    // half-written; this is an expected skip, NOT an error.
                    if (!game.ecs_backend.entityExists(ent)) break;
                    // PRESENCE recheck: an earlier sibling's onSet hook may
                    // have removed just THIS component (entity still alive).
                    // Skip it — advancing past its floats so the remaining
                    // siblings stay aligned — while the row's still-present
                    // components still land (the removed one stays removed;
                    // the hook's intent wins). This is what makes a
                    // multi-component row all-or-each, never half-written.
                    if (!hasByName(ent, nm)) {
                        pos += nb;
                        continue;
                    }
                    // Entity live AND component present, so a false here is
                    // a REAL apply failure (a built-in scene-apply rejection,
                    // or — impossible given the row-size validation — a
                    // truncated stream), NOT a vanished-skip. Surface it as
                    // -1 rather than masking a genuine failure as success.
                    if (!applyEntityFloats(ent, nm, buf, &pos)) return -1;
                }
            }
            return 0;
        }

        /// Stream bytes one component contributes per entity (its scalar
        /// fields × 4) — runtime name → comptime `streamBytes` dispatch,
        /// the sizing mirror of `writeEntityFloats`/`applyEntityFloats`.
        /// Unknown names contribute nothing (they also emit nothing).
        fn nameStreamBytes(name: []const u8) usize {
            if (std.mem.eql(u8, name, "Position")) {
                return comptime streamBytes(core.Position);
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    return comptime streamBytes(spec.T);
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    return comptime streamBytes(Components.getType(comp_name));
                }
            }
            return 0;
        }

        /// Apply one entity's component's scalar fields from the f32 stream
        /// — READ-MODIFY-WRITE (get/set symmetry: everything `batch_get`
        /// emits is writable). The existing component is copied, ONLY the
        /// batch-eligible scalar fields are overwritten by the mirror walk
        /// (`readFloatsFrom` — same dispatch and field layout as
        /// `writeEntityFloats`), and the mutated copy applies through the
        /// same channels as the per-entity paths: `setPosition` for
        /// Position, `setComponent` for registry components (non-scalar
        /// fields — strings, optionals, nested structs — are PRESERVED
        /// from the existing value, and no default-constructibility is
        /// required), and the scene-loader apply fns for built-ins (the
        /// mutated copy is serialized with the SAME serializer the JSON
        /// get uses and routed through `setBuiltinComponent`, so e.g. a
        /// batched Camera zoom write is indistinguishable from a scene
        /// author's). Returns false (refuse -1) on a missing component
        /// (the entity set changed mid-walk) or an exhausted stream.
        fn applyEntityFloats(ent: Entity, name: []const u8, buf: []const u8, pos: *usize) bool {
            if (std.mem.eql(u8, name, "Position")) {
                var p = (game.getComponent(ent, core.Position) orelse return false).*;
                if (!readFloatsFrom(core.Position, &p, buf, pos)) return false;
                game.setPosition(ent, p);
                return true;
            }
            inline for (builtin_comps) |spec| {
                if (std.mem.eql(u8, name, spec.name)) {
                    var comp = (game.getComponent(ent, spec.T) orelse return false).*;
                    if (!readFloatsFrom(spec.T, &comp, buf, pos)) return false;
                    // Serialize the MUTATED copy exactly as the JSON get
                    // serializes this built-in (Camera's tag as a string,
                    // renderer handles omitted), then route it through the
                    // scene apply machinery — the per-entity set's path.
                    var jbuf: [4096]u8 = undefined;
                    const n = if (comptime std.mem.eql(u8, spec.name, "Camera"))
                        stringifyInto(.{
                            .zoom = comp.zoom,
                            .viewport = comp.viewport,
                            .tag = comp.tagSlice(),
                        }, &jbuf)
                    else
                        stringifyFilteredInto(comp, &jbuf);
                    if (n == 0 or n > jbuf.len) return false;
                    return setBuiltinComponent(spec.name, ent, jbuf[0..n]) == 0;
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    var comp = (game.getComponent(ent, T) orelse return false).*;
                    if (!readFloatsFrom(T, &comp, buf, pos)) return false;
                    game.setComponent(ent, comp);
                    return true;
                }
            }
            return true;
        }

        // ── Events ───────────────────────────────────────────────

        fn eventEmitImpl(name: []const u8, json: []const u8) i32 {
            // Event-less game: the union check folds the whole body to
            // `-1` at comptime (the documented `GameEvents` gate).
            if (comptime !gameHasEventsUnion(G)) return -1;
            const fields = comptime @typeInfo(G.GameEvents).@"union".fields;
            inline for (fields) |f| {
                if (std.mem.eql(u8, name, f.name)) {
                    if (comptime f.type == void) {
                        // No payload struct exists for std.json to
                        // validate against, so the accept set is pinned
                        // explicitly (and documented in the export doc
                        // + header): empty — NULL/len-0 arrives here as
                        // "{}" via the export's default — or the exact
                        // bytes "{}" or "null". Anything else is the
                        // contract's parse failure: -1, nothing
                        // buffered.
                        if (!std.mem.eql(u8, json, "{}") and !std.mem.eql(u8, json, "null"))
                            return -1;
                        game.emit(@unionInit(G.GameEvents, f.name, {}));
                        return 0;
                    }
                    // Payload slices live in the ACTIVE emit arena,
                    // which stays untouched through this frame's
                    // dispatch and is recycled one flip later (module
                    // doc, "Payload memory"). `alloc_always`, never the
                    // slice default alloc_if_needed: the event sits
                    // buffered until dispatchEvents long after this
                    // call returns, so an unescaped string field must
                    // be COPIED into the arena, not borrowed from the
                    // caller's transient json.
                    const arena = if (emit_arenas[emit_active]) |*a| a.allocator() else return -1;
                    const payload = std.json.parseFromSliceLeaky(
                        f.type,
                        arena,
                        json,
                        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
                    ) catch return -1;
                    game.emit(@unionInit(G.GameEvents, f.name, payload));
                    return 0;
                }
            }
            return -1;
        }

        // ── Scene / log / time ───────────────────────────────────

        fn sceneChangeImpl(name: []const u8) i32 {
            // Validate BEFORE calling setScene: the engine tears the
            // current scene down before it discovers an unknown target
            // (mirrors editor_api.setSceneImpl — a typo'd script
            // request must not nuke the running scene).
            if (game.scenes.get(name) == null and game.jsonc_scenes.get(name) == null)
                return -1;
            game.setScene(name) catch return -1;
            // `setScene` DEFERS while the target's asset manifest is
            // still loading; queue the change so the game loop's
            // retrier commits it once the assets are ready.
            if (game.pending_scene_assets != null) game.queueSceneChange(name);
            return 0;
        }

        fn logImpl(msg: []const u8) void {
            game.log.info("[script] {s}", .{msg});
        }

        fn timeDtImpl() f32 {
            // Reconstruct the tick's scaled dt from state the game
            // already keeps: `tick()` records the REAL dt into the
            // frame_profiler ring every frame (newest at index-1) and
            // scales by `time_scale` for scripts; a paused game skips
            // script work entirely, so scripts observe dt 0.
            if (game.isPaused()) return 0;
            const fp = &game.frame_profiler;
            if (fp.count == 0) return 0;
            const n = fp.frame_times.len;
            const last = fp.frame_times[(fp.index + n - 1) % n];
            return last * game.time_scale;
        }

        // ── Input ────────────────────────────────────────────────
        //
        // Straight through the game's static `InputInterface` — the same
        // path `game.isKeyDown`/`getMouse` take (the `input_mixin` just
        // adds the `KeyboardKey` enum conversion the C surface skips, so
        // the raw integer code goes to the backend unmodified).

        fn inputKeyDownImpl(key: u32) bool {
            return G.Input.isKeyDown(key);
        }

        fn inputKeyPressedImpl(key: u32) bool {
            return G.Input.isKeyPressed(key);
        }

        fn inputMouseImpl() core.Position {
            return .{ .x = G.Input.getMouseX(), .y = G.Input.getMouseY() };
        }

        // ── Plugin commands ──────────────────────────────────────

        /// Straight through the game's `editorPluginCommandOut` mixin —
        /// the very dispatch the `editor_plugin_command*` bridge exports
        /// use, NOT a reimplementation: the routing/handler-channel/
        /// response decisions live in `game/editor_command_mixin.zig`
        /// alone. Every GameConfig-built Game carries the decl; the
        /// `@hasDecl` belt keeps a minimal duck-typed stand-in compiling
        /// (it degrades to unroutable) — the same belt editor_api's
        /// impls wear. A game whose merged `GameEvents` never consumed
        /// `engine__editor_plugin_command` folds to unroutable INSIDE
        /// the mixin (the zero-cost no-handler gate).
        ///
        /// The dispatch lands in PER-CALL stack storage, never the
        /// module `response_store` directly: a handler may itself issue
        /// a nested `labelle_plugin_call` (the mixin gives it its own
        /// response window), and two in-flight dispatches sharing one
        /// buffer would let the inner response scribble over the outer
        /// one's bytes while the outer window still reports its
        /// original length — a corrupted outer response (review finding
        /// on PR #760). One `max_response_len` frame per nesting level
        /// is the bounded, cheap price (4 KiB; depth is the game's own
        /// handler-recursion depth).
        ///
        /// The module store is PUBLISHED at completion, on every
        /// outcome — responded → copied in, dispatched/unroutable →
        /// cleared — so under nesting the inner call publishes first
        /// and the outer call, completing last, overwrites or clears
        /// it: a later `labelle_plugin_response_fetch` always reads the
        /// most-recently-COMPLETED (i.e. outermost) call's outcome. The
        /// return is already the export's wire value (sentinel / 0 /
        /// required size).
        fn pluginCallImpl(plugin: []const u8, command: []const u8, params_json: []const u8) usize {
            if (comptime !@hasDecl(G, "editorPluginCommandOut")) return plugin_call_unroutable;
            var buf: [plugin_command.max_response_len]u8 = undefined;
            switch (game.editorPluginCommandOut(plugin, command, params_json, &buf)) {
                .unroutable => {
                    response_len = null;
                    return plugin_call_unroutable;
                },
                .dispatched => {
                    response_len = null;
                    return 0;
                },
                .responded => |r| {
                    // `r.bytes` aliases this call's stack frame —
                    // publish a copy. Never 0 bytes (the mixin folds
                    // empty responses to `.dispatched`) and never over
                    // the cap (`buf` IS the cap; the mixin truncates at
                    // `out.len`).
                    @memcpy(response_store[0..r.bytes.len], r.bytes);
                    response_len = r.bytes.len;
                    return r.bytes.len;
                },
            }
        }

        // ── Helpers ──────────────────────────────────────────────

        /// Deserialize-side allocations for components (slice fields)
        /// share the spawned data's lifetime: the nested-entity arena,
        /// freed atomically on scene change — the identical convention
        /// `jsonc/component_apply.zig` documents. Pointer-free
        /// components never touch it (std.json allocates nothing for
        /// scalar/enum/bool fields), keeping per-tick `Position` sets
        /// allocation-free.
        fn componentAlloc() std.mem.Allocator {
            return game.active_world.nested_entity_arena.allocator();
        }

        /// Serialize `value` with the get's required-size semantics:
        /// the return is the bytes the COMPLETE JSON needs, and `out`
        /// is written only when all of it fits — ALL-OR-NOTHING, a
        /// truncated JSON object prefix being useless (unlike the
        /// query's id-list prefix). A counting pass sizes first so an
        /// over-cap value never scribbles a partial write into `out`
        /// (the canary the contract tests pin); gets are game-logic
        /// scale, so the doubled serialization is irrelevant.
        fn stringifyInto(value: anytype, out: []u8) usize {
            var counting: std.Io.Writer.Discarding = .init(&.{});
            // A discarding writer cannot fail; catch is belt.
            std.json.Stringify.value(value, .{}, &counting.writer) catch return 0;
            const required: usize = @intCast(counting.fullCount());
            if (required <= out.len) {
                var w = std.Io.Writer.fixed(out);
                // Counted to fit — unreachable, but 0 (absent) beats a
                // lying required if it ever fires.
                std.json.Stringify.value(value, .{}, &w) catch return 0;
            }
            return required;
        }

        /// `stringifyInto` for the scene built-ins: streams the struct
        /// as a JSON object, omitting fields `std.json` can't round-trip
        /// as AUTHORED data (see `jsonRoundTrips` — e.g. gfx
        /// `Sprite.texture`, a renderer handle the next set re-derives
        /// from `sprite_name`). The registry path keeps whole-struct
        /// `stringifyInto`; only built-ins carry renderer handles.
        /// Same required-size / all-or-nothing semantics.
        fn stringifyFilteredInto(comp: anytype, out: []u8) usize {
            var counting: std.Io.Writer.Discarding = .init(&.{});
            writeFilteredJson(comp, &counting.writer) catch return 0;
            const required: usize = @intCast(counting.fullCount());
            if (required <= out.len) {
                var w = std.Io.Writer.fixed(out);
                writeFilteredJson(comp, &w) catch return 0;
            }
            return required;
        }

        fn writeFilteredJson(comp: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
            var jw: std.json.Stringify = .{ .writer = w };
            try jw.beginObject();
            inline for (@typeInfo(@TypeOf(comp)).@"struct".fields) |f| {
                if (comptime jsonRoundTrips(f.type)) {
                    try jw.objectField(f.name);
                    try jw.write(@field(comp, f.name));
                }
            }
            try jw.endObject();
        }

        /// PACKED codec — `packInto` writes `value`'s scalar fields as the
        /// self-describing little-endian record the binding decodes:
        ///
        ///   [u8 field_count]                (0xFF = "not packable")
        ///   repeat: [u8 name_len][name][u8 type_tag][value bytes]
        ///   type_tag: 0=f32(4B) 1=i64(8B) 2=bool(1B) 3=u64(8B)
        ///             4=f64(8B, SET-side only — since v1.3)
        /// GET emits only tags 0..3; the binding may SET tag 4 for a
        /// float that would lose precision through f32's mantissa (a
        /// Float destined for an int field past 2^24) — the host coerces
        /// it at full f64 precision. A pre-tag-4 host reads tag 4 as an
        /// unknown tag and refuses (-1), the binding then falls back to
        /// JSON (which carries the f64 faithfully).
        ///
        /// Same required-size / all-or-nothing contract as `stringifyInto`
        /// (a counting pass sizes first). A struct with ANY non-scalar
        /// field — or a non-struct type — writes a single 0xFF byte and
        /// returns 1: the binding sees the sentinel and falls back to JSON.
        fn packInto(value: anytype, out: []u8) usize {
            const T = @TypeOf(value);
            if (comptime !isPackableStruct(T)) {
                if (out.len >= 1) out[0] = 0xFF;
                return 1;
            }
            const fields = @typeInfo(T).@"struct".fields;
            // Count-then-write: size the whole record so an over-cap value
            // never scribbles a partial write (the get's all-or-nothing).
            var required: usize = 1; // field_count byte
            inline for (fields) |f| {
                required += 1 + f.name.len + comptime packedFieldValueSize(f.type);
            }
            if (required > out.len) return required;
            var pos: usize = 0;
            out[pos] = @intCast(fields.len);
            pos += 1;
            inline for (fields) |f| {
                out[pos] = @intCast(f.name.len);
                pos += 1;
                @memcpy(out[pos..][0..f.name.len], f.name);
                pos += f.name.len;
                pos += writePackedValue(f.type, @field(value, f.name), out[pos..]);
            }
            return required;
        }

        /// Decode a packed record into `ptr.*` (already default-init),
        /// matching each field name to a struct field and COERCING the
        /// tagged value into that field's actual scalar type. Unknown
        /// names / non-scalar target fields are skipped. Returns false —
        /// the set refuses with -1 and the binding falls back to JSON —
        /// on a malformed record (a truncated field) or on a value the
        /// target field cannot represent (out-of-range int, NaN/Inf into
        /// an int field): script-supplied bytes must never panic the
        /// host, and must not be silently clamped either.
        fn applyPacked(comptime T: type, ptr: *T, buf: []const u8) bool {
            if (buf.len < 1) return false;
            const field_count = buf[0];
            var pos: usize = 1;
            var i: usize = 0;
            while (i < field_count) : (i += 1) {
                if (pos >= buf.len) return false;
                const name_len = buf[pos];
                pos += 1;
                if (pos + name_len > buf.len) return false;
                const fname = buf[pos..][0..name_len];
                pos += name_len;
                if (pos >= buf.len) return false;
                const tag = buf[pos];
                pos += 1;
                const val_size = packedTagSize(tag) orelse return false;
                if (pos + val_size > buf.len) return false;
                const val_bytes = buf[pos..][0..val_size];
                pos += val_size;
                inline for (@typeInfo(T).@"struct".fields) |f| {
                    if (comptime isPackableScalar(f.type)) {
                        if (std.mem.eql(u8, fname, f.name)) {
                            @field(ptr.*, f.name) =
                                coercePacked(f.type, tag, val_bytes) orelse return false;
                        }
                    }
                }
            }
            // Trailing bytes past the declared field records are a
            // malformed buffer (e.g. a zero-count header ahead of field
            // data) — refuse, don't half-accept.
            if (pos != buf.len) return false;
            return true;
        }

        // ── Packed codec helpers (comptime-pure, Holder-nested) ──────

        /// A field/component type the packed codec can carry: f32, any int
        /// ≤ 64 bits, or bool. f64 is deliberately NOT packable — the wire
        /// has only an f32 tag, so packing an f64 field would silently
        /// truncate its precision; such components take the 0xFF/JSON path,
        /// which carries f64 faithfully.
        fn isPackableScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => |fl| fl.bits == 32,
        .int => |i| i.bits <= 64,
        .bool => true,
        else => false,
    };
}

/// A struct every field of which is a packable scalar (zero-field structs
/// pack as an empty record — vacuously true) — AND that fits the wire's
/// u8 headers, decided entirely at comptime: `field_count` is a u8 with
/// 0xFF reserved as the "not packable" sentinel (so ≥ 255 fields cannot
/// be represented), and each `name_len` is a u8 (so a > 255-byte field
/// name cannot be). A struct beyond either limit simply takes the 0xFF
/// sentinel / JSON path — never a runtime `@intCast` panic in `packInto`.
fn isPackableStruct(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len >= 255) return false;
    inline for (fields) |f| {
        if (f.name.len > 255) return false;
        if (!isPackableScalar(f.type)) return false;
    }
    return true;
}

/// Additionally require default values so `var comp: T = .{}` compiles for
/// the packed SET path (REPLACE semantics start from defaults).
fn packableStruct(comptime T: type) bool {
    if (!isPackableStruct(T)) return false;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null) return false;
    }
    return true;
}

/// Bytes one field occupies in the record: tag byte + payload.
fn packedFieldValueSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .float => 1 + 4, // tag + f32
        .int => 1 + 8, // tag + i64/u64
        .bool => 1 + 1, // tag + byte
        else => unreachable,
    };
}

/// Payload byte count for a wire type_tag (null = unknown tag).
fn packedTagSize(tag: u8) ?usize {
    return switch (tag) {
        0 => 4, // f32
        1 => 8, // i64
        2 => 1, // bool
        3 => 8, // u64
        4 => 8, // f64 — SET-side only (since v1.3): full-precision floats
        // so a script Float destined for an int field lands exactly past
        // f32's 24-bit mantissa. GET never emits it (f64 *fields* stay
        // non-packable / 0xFF). An unknown tag stays null → applyPacked
        // refuses (-1) and the binding falls back to JSON.
        else => null,
    };
}

/// Write one field's [tag][value] slot; returns bytes written.
fn writePackedValue(comptime T: type, val: T, out: []u8) usize {
    switch (@typeInfo(T)) {
        .float => {
            out[0] = 0;
            const f: f32 = @floatCast(val);
            std.mem.writeInt(u32, out[1..][0..4], @bitCast(f), .little);
            return 5;
        },
        .int => |i| {
            if (i.signedness == .signed) {
                out[0] = 1;
                std.mem.writeInt(i64, out[1..][0..8], @intCast(val), .little);
            } else {
                out[0] = 3;
                std.mem.writeInt(u64, out[1..][0..8], @intCast(val), .little);
            }
            return 9;
        },
        .bool => {
            out[0] = 2;
            out[1] = @intFromBool(val);
            return 2;
        },
        else => unreachable,
    }
}

/// Truncating float→int with REFUSAL (null) on NaN/Inf/out-of-range —
/// the packed SET's safe cast. `@intFromFloat` panics on any of those,
/// and the value is SCRIPT-SUPPLIED, so the host must refuse instead
/// (never clamp/zero: a silently altered value is a corruption). The
/// bounds are the exact powers of two 2^bits / ±2^(bits-1) — always
/// representable in f64, unlike maxInt(T) itself, whose f64 rounding
/// would re-admit the panicking boundary value for 64-bit targets.
fn safeFloatToInt(comptime T: type, f: f64) ?T {
    if (!std.math.isFinite(f)) return null;
    const t: f64 = @trunc(f);
    const info = @typeInfo(T).int;
    // Degenerate 0-bit ints hold only 0 (and i0's bits-1 would underflow
    // the shift below).
    if (comptime info.bits == 0) return if (t == 0) @intFromFloat(t) else null;
    const upper: f64 = comptime blk: {
        const b: u7 = if (info.signedness == .signed) info.bits - 1 else info.bits;
        break :blk @floatFromInt(@as(u128, 1) << b);
    };
    const lower: f64 = if (comptime info.signedness == .signed) -upper else 0;
    if (t < lower or t >= upper) return null;
    return @intFromFloat(t);
}

/// Coerce a tagged packed value into `T` (the target field's real type):
/// floats via @floatCast, ints via `std.math.cast` — EXCEPT the 64-bit
/// bitcast pair (an i64 tag into a u64 field and vice versa are
/// two's-complement `@bitCast`, the documented lossless round trip for
/// signed-only bindings) — and a bool tag lands in an int/float field as
/// 0/1 (the mirror of the write side's widening). Returns null — the
/// whole set REFUSES with -1 and the binding falls back to JSON — when
/// the script value cannot represent itself in the field (out-of-range
/// int into a narrower target, NaN/Inf/out-of-range float into an int
/// field): the value is script-supplied, so the host must never panic on
/// it, and must not silently clamp/zero it either — the JSON path
/// surfaces the value faithfully (or refuses it visibly).
///
/// BOOL-FIELD RULE (asymmetric on purpose): a bool field accepts ONLY
/// the bool tag (2). Every NUMERIC tag (f32/i64/u64/f64) targeting a
/// bool field is a type error — a script value of the wrong kind
/// mis-addressing the field (e.g. `alive = 16_777_217.0`) — and REFUSES
/// (null → -1), so the JSON path surfaces the real value or its parse
/// error instead of silently collapsing it to true/false (which would
/// discard the value entirely). The reverse — a bool tag WIDENING into a
/// number field (true/false → 1/0) — stays allowed: it is total,
/// lossless and unambiguous, the documented write-side mirror.
/// Narrowing a number to a bool is none of those, hence the asymmetry.
fn coercePacked(comptime T: type, tag: u8, bytes: []const u8) ?T {
    return switch (@typeInfo(T)) {
        .float => switch (tag) {
            0 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little)))),
            // Int→float is total: may round (past 2^24/2^53) but can
            // never trap, and rounding is inherent to a float target.
            1 => @floatFromInt(std.mem.readInt(i64, bytes[0..8], .little)),
            2 => if (bytes[0] != 0) 1 else 0,
            3 => @floatFromInt(std.mem.readInt(u64, bytes[0..8], .little)),
            // f64 tag (SET-side, since v1.3): @floatCast narrows to the
            // field's real float width (f32 fields aren't packable-f64,
            // but an f32-declared field receiving an f64 tag narrows the
            // same way JSON would parse-then-narrow — a defined
            // conversion).
            4 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little)))),
            else => null,
        },
        .int => |ti| switch (tag) {
            0 => safeFloatToInt(T, @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little)))),
            // 64-BIT BITCAST PAIR (documented in the header): a 64-bit int
            // field accepts the OTHER 64-bit tag via two's-complement
            // @bitCast. This is what makes the round trip lossless for a
            // binding whose only integer is signed 64-bit (mruby): GET
            // emits a u64 field as tag 3, the binding bitcasts it into its
            // signed Integer, SET re-emits tag 1, and the host bitcasts it
            // back — bit-exact even with bit 63 set. Narrower targets keep
            // the range-checked refusal.
            1 => blk: {
                const v = std.mem.readInt(i64, bytes[0..8], .little);
                if (comptime ti.signedness == .unsigned and ti.bits == 64) {
                    break :blk @as(T, @bitCast(v));
                }
                break :blk std.math.cast(T, v);
            },
            2 => std.math.cast(T, @intFromBool(bytes[0] != 0)),
            3 => blk: {
                const v = std.mem.readInt(u64, bytes[0..8], .little);
                if (comptime ti.signedness == .signed and ti.bits == 64) {
                    break :blk @as(T, @bitCast(v));
                }
                break :blk std.math.cast(T, v);
            },
            // f64 tag (SET-side, since v1.3): the whole point — a float
            // beyond f32's 24-bit mantissa reaches an int field EXACTLY
            // (16_777_217.0 no longer rounds), refusing (null) only on
            // NaN/Inf/out-of-range, never clamping.
            4 => safeFloatToInt(T, @as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little)))),
            else => null,
        },
        // A bool field accepts ONLY the bool tag — every numeric tag
        // (0/1/3/4) is type confusion and refuses (see the fn doc's
        // BOOL-FIELD RULE). No silent number→bool collapse in EITHER
        // direction; the JSON fallback surfaces the real value/error.
        .bool => switch (tag) {
            2 => bytes[0] != 0,
            else => null,
        },
        else => unreachable,
    };
}

// ── Batched f32 codec helpers (comptime-pure, positional) ────────────
//
// Unlike the packed codec these are NAMELESS/positional: the batch buffer
// carries no field names or tags, only raw little-endian f32, so get and
// set must agree on field COUNT and ORDER purely by walking the same struct
// the same way. Both iterate `@typeInfo(T).@"struct".fields` (declaration
// order), emitting/consuming one f32 per scalar field and skipping
// non-scalar fields identically. Int-carrying components never reach these
// helpers — `batchEligible` refuses them upstream (`batch_int_refused`).
// The write/skip int arms stay total (`@floatFromInt` cannot trap), but
// the READ side refuses int fields outright: an `@intFromFloat` there
// could panic the host on a NaN/Inf/out-of-range script float, and no
// reachable path needs it.

/// A component type the BATCH codec accepts: no int-typed fields. Ints
/// cannot survive the positional f32 stream (silent precision loss past
/// 2^24), so components carrying them are refused rather than corrupted
/// — use the per-entity packed codec (lossless i64/u64 tags) for those.
/// f32/f64 and bool fields ride as f32 (bool as 0/1); non-scalar fields
/// are skipped by both stream directions and don't disqualify.
fn batchEligible(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return true;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (@typeInfo(f.type) == .int) return false;
    }
    return true;
}

/// Empty batched result: the 4-byte `[u32 count = 0]` header alone,
/// written only when it fits. Distinct from the 0 not-bound/malformed
/// sentinel (queryImpl's `writeEmptyArray` analog).
fn writeBatchCount0(out: []u8) usize {
    if (out.len >= 4) std.mem.writeInt(u32, out[0..4], 0, .little);
    return 4;
}

/// Write each scalar field of `value` as one raw little-endian f32 at
/// `pos.*`, advancing `pos.*` by 4 per field. Int fields coerce via
/// `@floatFromInt`, bool via 0/1; non-scalar fields are skipped (they
/// contribute no float — get and set skip them identically). `pos.*`
/// advances even past the cap so the caller's required-size return is
/// exact (snprintf-style); the write itself is guarded by room.
fn packFloatsInto(comptime T: type, value: T, out: []u8, pos: *usize) void {
    if (comptime @typeInfo(T) != .@"struct") return;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const maybe: ?f32 = switch (@typeInfo(f.type)) {
            .float => @floatCast(@field(value, f.name)),
            .int => @floatFromInt(@field(value, f.name)),
            .bool => if (@field(value, f.name)) @as(f32, 1) else @as(f32, 0),
            else => null,
        };
        if (maybe) |fv| {
            if (pos.* + 4 <= out.len) {
                std.mem.writeInt(u32, out[pos.*..][0..4], @bitCast(fv), .little);
            }
            pos.* += 4;
        }
    }
}

/// Read each scalar field of `ptr.*` from the f32 stream at `pos.*`
/// (float via `@floatCast` — NaN/Inf land unchanged in a float field,
/// which is defined and faithful; bool via `!= 0`, where NaN reads as
/// true since NaN != 0), advancing 4 per field. Non-scalar fields are
/// skipped (no bytes consumed — the write side skipped them too).
/// Returns false if the buffer runs out mid-layout — or on an int field:
/// int-carrying components are refused upstream by `batchEligible`
/// before any entity walk, so that arm is unreachable through the batch
/// exports, and it is kept as a REFUSAL rather than an `@intFromFloat`
/// so no caller — present or future — can panic the host on a
/// NaN/Inf/out-of-range script float.
fn readFloatsFrom(comptime T: type, ptr: *T, buf: []const u8, pos: *usize) bool {
    if (comptime @typeInfo(T) != .@"struct") return true;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        switch (@typeInfo(f.type)) {
            .float, .bool => {
                if (pos.* + 4 > buf.len) return false;
                const fv: f32 = @bitCast(std.mem.readInt(u32, buf[pos.*..][0..4], .little));
                pos.* += 4;
                @field(ptr.*, f.name) = switch (@typeInfo(f.type)) {
                    .float => @floatCast(fv),
                    .bool => fv != 0,
                    else => unreachable,
                };
            },
            .int => return false,
            else => {},
        }
    }
    return true;
}

/// Stream bytes one component type contributes per entity: its scalar
/// (float/int/bool) fields × 4 — the comptime sizing mirror of
/// `packFloatsInto`/`readFloatsFrom`'s walks. Int fields count for
/// totality, though int-carrying components are refused upstream.
fn streamBytes(comptime T: type) usize {
    if (@typeInfo(T) != .@"struct") return 0;
    var n: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        switch (@typeInfo(f.type)) {
            .float, .int, .bool => n += 4,
            else => {},
        }
    }
    return n;
}

        fn castEntity(id: u64) ?Entity {
            if (comptime @typeInfo(Entity) != .int) return null;
            return std.math.cast(Entity, id);
        }

        fn entityId(ent: Entity) u64 {
            const info = @typeInfo(Entity);
            if (comptime info == .int and info.int.signedness == .unsigned and info.int.bits <= 64) {
                return @intCast(ent);
            }
            return 0;
        }
    };
}

/// Empty query result: `[]` requires 2 bytes (the return, per the
/// query's snprintf-style sizing) and is written only when it fits.
fn writeEmptyArray(out: []u8) usize {
    if (out.len >= 2) {
        out[0] = '[';
        out[1] = ']';
    }
    return 2;
}

fn appendLit(buf: []u8, cur: *usize, lit: []const u8) error{NoSpace}!void {
    if (buf.len - cur.* < lit.len) return error.NoSpace;
    @memcpy(buf[cur.*..][0..lit.len], lit);
    cur.* += lit.len;
}

fn appendFmt(buf: []u8, cur: *usize, comptime fmt: []const u8, args: anytype) error{NoSpace}!void {
    const written = std.fmt.bufPrint(buf[cur.*..], fmt, args) catch return error.NoSpace;
    cur.* += written.len;
}
