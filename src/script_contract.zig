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
//! return 0, rc-returning ops return -1, `labelle_component_get` /
//! `labelle_query` / `labelle_event_poll` write nothing and return 0, and
//! the void ops silently ignore. `labelle_contract_version` is pure and
//! works even before `bind`.
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
//! Single-threaded by design (main thread, during the plugin's tick);
//! no atomics.

const std = @import("std");
const core = @import("labelle-core");

/// Contract version consumers compile against. Bump on any ABI or
/// semantic change; language plugins check it via
/// `labelle_contract_version()` at startup and refuse a mismatch.
pub const CONTRACT_VERSION: u32 = 1;

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
/// Subscribed event names (deduped, owned copies).
var subs: std.ArrayList([]u8) = .empty;
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

// ── Type-erased dispatch ────────────────────────────────────────────

const VTable = struct {
    entity_create: *const fn () u64,
    entity_destroy: *const fn (id: u64) void,
    prefab_spawn: *const fn (name: []const u8, params_json: []const u8) u64,
    component_set: *const fn (id: u64, name: []const u8, json: []const u8) i32,
    component_get: *const fn (id: u64, name: []const u8, out: []u8) usize,
    component_has: *const fn (id: u64, name: []const u8) i32,
    component_remove: *const fn (id: u64, name: []const u8) i32,
    query: *const fn (names_json: []const u8, out: []u8) usize,
    event_emit: *const fn (name: []const u8, json: []const u8) i32,
    scene_change: *const fn (name: []const u8) i32,
    log: *const fn (msg: []const u8) void,
    time_dt: *const fn () f32,
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
}

/// Per-frame event tap, called by the generated main AFTER `g.tick(dt)`
/// and BEFORE `g.dispatchEvents()` — see the module doc for why that
/// ordering is load-bearing (dispatch consumes the buffer; the tap only
/// reads it). Walks the frame's buffered `GameEvents`, serializes each
/// SUBSCRIBED one to `"<name> <json>"` (name = union tag, payload via
/// `std.json` reflection), and appends it to the poll FIFO.
///
/// Also the once-per-frame maintenance point: flips the double-buffered
/// `labelle_event_emit` payload arenas and recycles the one holding the
/// PREVIOUS frame's payloads (safe precisely because that frame's
/// `dispatchEvents` already delivered everything referencing it — the
/// module doc's "Payload memory" section spells out the two-arena
/// dance).
///
/// A comptime no-op for games without a `GameEvents` union, and an
/// early-out when nothing is subscribed — an unused tap costs one
/// branch per frame.
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
/// serde seam over the game's OWN `ComponentRegistry` (plus the built-in
/// `Position`, which routes through `setPosition` so render dirty-
/// tracking fires). Unlike `editor_set_component` — deliberately
/// allowlisted to the vetted `"Camera"` — this dispatch is open: the
/// contract is the game's own code calling itself, so it gets the full
/// registry, exactly like the JSONC scene loader.
///
/// REPLACE semantics: the JSON is parsed as the whole component struct
/// (absent fields take the struct's defaults, unknown fields are
/// ignored); there is no merge/patch. `json` may be NULL or empty
/// (`len == 0`), meaning `"{}"` — all defaults. Returns 0 = ok; -1 =
/// unknown component name / unknown-or-dead entity / parse failure /
/// not bound. On -1 the entity is untouched (the parse runs before any
/// mutation).
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
/// (capacity `out_cap`) and return the number of bytes written. 0 =
/// absent component / unknown name / dead entity / not bound / doesn't
/// fit. A NULL `out` is treated as capacity 0 (nothing written, 0
/// returned). Two-call sizing is deliberately avoided (POC decision):
/// script payloads are small — size `out` generously.
pub export fn labelle_component_get(
    id: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const vt = vtable orelse return 0;
    if (name_len == 0 or out_cap == 0) return 0;
    const buf = out orelse return 0;
    return vt.component_get(id, name_ptr[0..name_len], buf[0..out_cap]);
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
/// bound.
pub export fn labelle_component_remove(id: u64, name_ptr: [*]const u8, name_len: usize) i32 {
    const vt = vtable orelse return -1;
    if (name_len == 0) return -1;
    return vt.component_remove(id, name_ptr[0..name_len]);
}

/// Query entity ids by component names. `names_json` is a JSON array of
/// component names (`["CloudDrift","Position"]`); the engine iterates a
/// view on the FIRST name and filters the rest, writing the matching ids
/// as a JSON array (`[3,7,12]`) into `out`. Returns bytes written; 0 =
/// malformed names / not bound / `out_cap` too small for even `[]`.
/// An unknown component name yields the valid empty result `[]`.
///
/// Snapshot semantics: the id list is captured at query time, so
/// spawn/destroy while the script walks it is safe (a per-id
/// `labelle_component_get` on a since-destroyed entity returns 0). When
/// the ids don't all fit, the list is truncated at the last whole id —
/// the output is always valid JSON (same contract as
/// `editor_scene_digest`). A NULL `out` is treated as capacity 0.
pub export fn labelle_query(
    names_json_ptr: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const vt = vtable orelse return 0;
    if (names_json_len == 0 or out_cap == 0) return 0;
    const buf = out orelse return 0;
    return vt.query(names_json_ptr[0..names_json_len], buf[0..out_cap]);
}

/// Emit a game event by name into the buffered event path — the same
/// `game.emit` every Zig script uses, so flows (`OnEvent`), hooks, and
/// other subscribed scripts all see it at this frame's
/// `dispatchEvents`. `name` must be a `GameEvents` union tag; `json` is
/// the variant's payload struct (NULL or empty → `{}`, i.e. all-default
/// fields). Returns 0 = ok; -1 = unknown event name / parse failure /
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

/// Declare interest in event `name` (a `GameEvents` union tag). From the
/// next `drainEvents` on, matching events are queued for
/// `labelle_event_poll`. Duplicate subscriptions are deduped. Pre-bind:
/// a safe no-op (the generated main binds before plugin setup, so no
/// real subscriber exists earlier).
pub export fn labelle_event_subscribe(name_ptr: [*]const u8, name_len: usize) void {
    const alloc = bound_allocator orelse return;
    if (name_len == 0) return;
    const name = name_ptr[0..name_len];
    for (subs.items) |s| {
        if (std.mem.eql(u8, s, name)) return;
    }
    const copy = alloc.dupe(u8, name) catch return;
    subs.append(alloc, copy) catch {
        alloc.free(copy);
    };
}

/// Drain one pending event: copies the next `"<name> <json>"` entry
/// (FIFO — emission order within and across frames) into `out` and
/// returns bytes written; 0 = inbox empty. The entry is consumed even
/// when `out_cap` truncates it (POC-pinned behavior) — size `out`
/// generously. A NULL or zero-capacity `out` is the one exception: it
/// reads (and consumes) nothing and returns 0. Scripts drain in a
/// `while (poll() > 0)` loop once per tick.
pub export fn labelle_event_poll(out: ?[*]u8, out_cap: usize) usize {
    if (inbox_head >= inbox.items.len) return 0;
    const alloc = bound_allocator orelse return 0;
    const buf = out orelse return 0;
    if (out_cap == 0) return 0;
    const entry = inbox.items[inbox_head];
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
        /// author (plus the built-in `Position`, which the bridge also
        /// special-cases). Registries without `getType` (the minimal
        /// `GameWith` shape) are fine: `names()` is empty there, so the
        /// `inline for` bodies that reference `getType` never
        /// instantiate.
        const Components = G.ComponentRegistry;

        var game: GP = undefined;

        const vtable_impl = VTable{
            .entity_create = &entityCreateImpl,
            .entity_destroy = &entityDestroyImpl,
            .prefab_spawn = &prefabSpawnImpl,
            .component_set = &componentSetImpl,
            .component_get = &componentGetImpl,
            .component_has = &componentHasImpl,
            .component_remove = &componentRemoveImpl,
            .query = &queryImpl,
            .event_emit = &eventEmitImpl,
            .scene_change = &sceneChangeImpl,
            .log = &logImpl,
            .time_dt = &timeDtImpl,
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
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    // Slice-bearing fields land in the nested-entity
                    // arena — the scene bridge's exact lifetime
                    // convention (freed atomically on scene change).
                    const comp = std.json.parseFromSliceLeaky(
                        T,
                        componentAlloc(),
                        json,
                        .{ .ignore_unknown_fields = true },
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

        fn componentGetImpl(id: u64, name: []const u8, out: []u8) usize {
            const ent = castEntity(id) orelse return 0;
            if (std.mem.eql(u8, name, "Position")) {
                const pos = game.getComponent(ent, core.Position) orelse return 0;
                return stringifyInto(pos.*, out);
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

        fn componentHasImpl(id: u64, name: []const u8) i32 {
            const ent = castEntity(id) orelse return 0;
            if (std.mem.eql(u8, name, "Position")) {
                return @intFromBool(game.hasComponent(ent, core.Position));
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
            // rest filter per-entity by name below.
            if (std.mem.eql(u8, names[0], "Position")) {
                return runQuery(core.Position, names[1..], out);
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
            if (out.len < 2) return 0;
            // Reserve the closing `]` so id truncation can never eat
            // the byte that keeps the JSON valid (digest pattern).
            const body = out[0 .. out.len - 1];
            var cur: usize = 0;
            appendLit(body, &cur, "[") catch return 0;
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
                const mark = cur;
                writeIdJson(body, &cur, entityId(ent), first) catch {
                    // Doesn't fit — roll back this id (and its comma)
                    // and stop; the `]` below keeps the truncated list
                    // valid JSON.
                    cur = mark;
                    break;
                };
                first = false;
            }
            out[cur] = ']';
            return cur + 1;
        }

        fn writeIdJson(buf: []u8, cur: *usize, id: u64, first: bool) error{NoSpace}!void {
            if (!first) try appendLit(buf, cur, ",");
            try appendFmt(buf, cur, "{d}", .{id});
        }

        /// Runtime component name → "is it dispatchable at all".
        fn nameResolvable(name: []const u8) bool {
            if (std.mem.eql(u8, name, "Position")) return true;
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
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    return game.hasComponent(ent, Components.getType(comp_name));
                }
            }
            return false;
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
                        game.emit(@unionInit(G.GameEvents, f.name, {}));
                        return 0;
                    }
                    // Payload slices live in the ACTIVE emit arena,
                    // which stays untouched through this frame's
                    // dispatch and is recycled one flip later (module
                    // doc, "Payload memory").
                    const arena = if (emit_arenas[emit_active]) |*a| a.allocator() else return -1;
                    const payload = std.json.parseFromSliceLeaky(
                        f.type,
                        arena,
                        json,
                        .{ .ignore_unknown_fields = true },
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

        fn stringifyInto(value: anytype, out: []u8) usize {
            var w = std.Io.Writer.fixed(out);
            // WriteFailed = doesn't fit → 0, per the export's contract.
            std.json.Stringify.value(value, .{}, &w) catch return 0;
            return w.buffered().len;
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

fn writeEmptyArray(out: []u8) usize {
    if (out.len < 2) return 0;
    out[0] = '[';
    out[1] = ']';
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
