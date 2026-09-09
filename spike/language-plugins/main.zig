//! Language-plugins spike host (RFC-LANGUAGE-PLUGINS, engine#237).
//!
//! One toy world behind the Script Runtime Contract (contract/contract.h,
//! exported below as flat C symbols), driven by the SAME behavior script
//! written in two languages from the two integration families:
//!
//!   - Lua  (embedded-VM family)     — scripts/behavior.lua in a Lua 5.4
//!     VM embedded here via hand-declared C externs (no @cImport).
//!   - Rust (native-compiled family) — rust/src/lib.rs built as a
//!     staticlib and linked into this binary, calling the same symbols.
//!
//! Each language runs init + 5 ticks against a fresh world; the host
//! snapshots both worlds and REQUIRES them identical. That equivalence —
//! one contract, two families, same result — is the spike's claim.
//!
//! POC shortcuts (fine here, not for the real plugin): fixed-size world
//! arrays, JSON stored as opaque strings, main-thread only, no queries.

const std = @import("std");

// ── Toy world ───────────────────────────────────────────────────────────

const MAX_ENTITIES = 64;
const MAX_COMPONENTS = 8;
const NAME_CAP = 32;
const JSON_CAP = 192;
const MAX_EVENTS = 32;

const Component = struct {
    name: [NAME_CAP]u8 = undefined,
    name_len: usize = 0,
    json: [JSON_CAP]u8 = undefined,
    json_len: usize = 0,
};

const Entity = struct {
    id: u64 = 0,
    alive: bool = false,
    comps: [MAX_COMPONENTS]Component = undefined,
    comp_count: usize = 0,
};

const Event = struct {
    text: [NAME_CAP + JSON_CAP]u8 = undefined,
    len: usize = 0,
};

const World = struct {
    next_id: u64 = 1,
    entities: [MAX_ENTITIES]Entity = undefined,
    entity_count: usize = 0,
    events: [MAX_EVENTS]Event = undefined,
    event_count: usize = 0,
    // Receive side: the script's subscriptions + FIFO inbox it drains
    // via labelle_event_poll (one script per world in this POC).
    subs: [8]Event = undefined,
    sub_count: usize = 0,
    inbox: [MAX_EVENTS]Event = undefined,
    inbox_head: usize = 0,
    inbox_count: usize = 0,
    dt: f32 = 1.0 / 60.0,

    fn reset(self: *World) void {
        self.* = .{};
    }

    fn find(self: *World, id: u64) ?*Entity {
        for (self.entities[0..self.entity_count]) |*e| {
            if (e.alive and e.id == id) return e;
        }
        return null;
    }

    /// Deterministic dump for cross-language comparison: entities in id
    /// order, components in insertion order (both scripts insert in the
    /// same order by construction).
    fn snapshot(self: *World, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        for (self.entities[0..self.entity_count]) |*e| {
            if (!e.alive) continue;
            w.print("entity {d}:", .{e.id}) catch break;
            for (e.comps[0..e.comp_count]) |*c| {
                w.print(" {s}={s}", .{ c.name[0..c.name_len], c.json[0..c.json_len] }) catch break;
            }
            w.print("\n", .{}) catch break;
        }
        for (self.events[0..self.event_count]) |*ev| {
            w.print("event {s}\n", .{ev.text[0..ev.len]}) catch break;
        }
        return w.buffered();
    }
};

var world: World = .{};

// ── Contract exports (contract/contract.h) ─────────────────────────────

export fn labelle_entity_create() u64 {
    if (world.entity_count >= MAX_ENTITIES) return 0;
    const e = &world.entities[world.entity_count];
    e.* = .{ .id = world.next_id, .alive = true };
    world.next_id += 1;
    world.entity_count += 1;
    return e.id;
}

export fn labelle_entity_destroy(id: u64) void {
    if (world.find(id)) |e| e.alive = false;
}

export fn labelle_component_set(id: u64, name: [*]const u8, name_len: usize, json: [*]const u8, json_len: usize) void {
    const e = world.find(id) orelse return;
    const n = name[0..@min(name_len, NAME_CAP)];
    const j = json[0..@min(json_len, JSON_CAP)];
    // Update-in-place when the component exists (the common per-tick path).
    for (e.comps[0..e.comp_count]) |*c| {
        if (std.mem.eql(u8, c.name[0..c.name_len], n)) {
            @memcpy(c.json[0..j.len], j);
            c.json_len = j.len;
            return;
        }
    }
    if (e.comp_count >= MAX_COMPONENTS) return;
    const c = &e.comps[e.comp_count];
    @memcpy(c.name[0..n.len], n);
    c.name_len = n.len;
    @memcpy(c.json[0..j.len], j);
    c.json_len = j.len;
    e.comp_count += 1;
}

export fn labelle_component_get(id: u64, name: [*]const u8, name_len: usize, out: [*]u8, out_cap: usize) usize {
    const e = world.find(id) orelse return 0;
    const n = name[0..@min(name_len, NAME_CAP)];
    for (e.comps[0..e.comp_count]) |*c| {
        if (std.mem.eql(u8, c.name[0..c.name_len], n)) {
            const len = @min(c.json_len, out_cap);
            @memcpy(out[0..len], c.json[0..len]);
            return len;
        }
    }
    return 0;
}

export fn labelle_component_has(id: u64, name: [*]const u8, name_len: usize) c_int {
    const e = world.find(id) orelse return 0;
    const n = name[0..@min(name_len, NAME_CAP)];
    for (e.comps[0..e.comp_count]) |*c| {
        if (std.mem.eql(u8, c.name[0..c.name_len], n)) return 1;
    }
    return 0;
}

export fn labelle_event_emit(name: [*]const u8, name_len: usize, json: [*]const u8, json_len: usize) void {
    if (world.event_count >= MAX_EVENTS) return;
    const ev = &world.events[world.event_count];
    var w = std.Io.Writer.fixed(&ev.text);
    w.print("{s} {s}", .{ name[0..name_len], json[0..json_len] }) catch {};
    ev.len = w.buffered().len;
    world.event_count += 1;
}

export fn labelle_event_subscribe(name: [*]const u8, name_len: usize) void {
    if (world.sub_count >= world.subs.len) return;
    const s = &world.subs[world.sub_count];
    const n = name[0..@min(name_len, s.text.len)];
    @memcpy(s.text[0..n.len], n);
    s.len = n.len;
    world.sub_count += 1;
}

export fn labelle_event_poll(out: [*]u8, out_cap: usize) usize {
    if (world.inbox_count == 0) return 0;
    const ev = &world.inbox[world.inbox_head];
    world.inbox_head = (world.inbox_head + 1) % MAX_EVENTS;
    world.inbox_count -= 1;
    const len = @min(ev.len, out_cap);
    @memcpy(out[0..len], ev.text[0..len]);
    return len;
}

export fn labelle_time_dt() f32 {
    return world.dt;
}

/// Host-side emit toward scripts: queued into the inbox only when the
/// script subscribed to the event name (the engine analog: GameEvents
/// dispatch fanning out to language-plugin subscribers).
fn hostEmit(name: []const u8, json: []const u8) void {
    var subscribed = false;
    for (world.subs[0..world.sub_count]) |*s| {
        if (std.mem.eql(u8, s.text[0..s.len], name)) subscribed = true;
    }
    if (!subscribed or world.inbox_count >= MAX_EVENTS) return;
    const slot = (world.inbox_head + world.inbox_count) % MAX_EVENTS;
    const ev = &world.inbox[slot];
    var w = std.Io.Writer.fixed(&ev.text);
    w.print("{s} {s}", .{ name, json }) catch {};
    ev.len = w.buffered().len;
    world.inbox_count += 1;
}

export fn labelle_log(msg: [*]const u8, len: usize) void {
    std.debug.print("  [script] {s}\n", .{msg[0..len]});
}

// ── Lua 5.4 embedding (hand-declared C API — no @cImport) ──────────────

const lua = struct {
    const State = opaque {};
    const CFn = *const fn (?*State) callconv(.c) c_int;
    const MULTRET: c_int = -1;
    // lua_pcall(L,n,r,f) is a macro over lua_pcallk in 5.4.
    extern fn luaL_newstate() ?*State;
    extern fn luaL_openlibs(L: ?*State) void;
    extern fn luaL_loadstring(L: ?*State, s: [*:0]const u8) c_int;
    extern fn lua_pcallk(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*anyopaque) c_int;
    extern fn lua_close(L: ?*State) void;
    extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
    extern fn lua_pushcclosure(L: ?*State, f: CFn, n: c_int) void;
    extern fn lua_setfield(L: ?*State, idx: c_int, k: [*:0]const u8) void;
    extern fn lua_setglobal(L: ?*State, name: [*:0]const u8) void;
    extern fn lua_getglobal(L: ?*State, name: [*:0]const u8) c_int;
    extern fn lua_pushnumber(L: ?*State, n: f64) void;
    extern fn lua_pushinteger(L: ?*State, n: i64) void;
    extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) void;
    extern fn lua_tonumberx(L: ?*State, idx: c_int, isnum: ?*c_int) f64;
    extern fn lua_tointegerx(L: ?*State, idx: c_int, isnum: ?*c_int) i64;
    extern fn lua_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*]const u8;
    extern fn lua_settop(L: ?*State, idx: c_int) void;

    fn pcall(L: ?*State, nargs: c_int, nresults: c_int) c_int {
        return lua_pcallk(L, nargs, nresults, 0, 0, null);
    }
};

// Binding shims: Lua closures → contract symbols. A real labelle-lua
// wraps these in idiomatic sugar (entity:get/set); the spike keeps the
// raw contract visible on purpose.
fn l_entity_create(L: ?*lua.State) callconv(.c) c_int {
    lua.lua_pushinteger(L, @intCast(labelle_entity_create()));
    return 1;
}
fn l_component_set(L: ?*lua.State) callconv(.c) c_int {
    const id: u64 = @intCast(lua.lua_tointegerx(L, 1, null));
    var nlen: usize = 0;
    const n = lua.lua_tolstring(L, 2, &nlen) orelse return 0;
    var jlen: usize = 0;
    const j = lua.lua_tolstring(L, 3, &jlen) orelse return 0;
    labelle_component_set(id, n, nlen, j, jlen);
    return 0;
}
fn l_component_get(L: ?*lua.State) callconv(.c) c_int {
    const id: u64 = @intCast(lua.lua_tointegerx(L, 1, null));
    var nlen: usize = 0;
    const n = lua.lua_tolstring(L, 2, &nlen) orelse return 0;
    var buf: [JSON_CAP]u8 = undefined;
    const len = labelle_component_get(id, n, nlen, &buf, buf.len);
    lua.lua_pushlstring(L, &buf, len);
    return 1;
}
fn l_event_emit(L: ?*lua.State) callconv(.c) c_int {
    var nlen: usize = 0;
    const n = lua.lua_tolstring(L, 1, &nlen) orelse return 0;
    var jlen: usize = 0;
    const j = lua.lua_tolstring(L, 2, &jlen) orelse return 0;
    labelle_event_emit(n, nlen, j, jlen);
    return 0;
}
fn l_log(L: ?*lua.State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.lua_tolstring(L, 1, &len) orelse return 0;
    labelle_log(s, len);
    return 0;
}
fn l_event_subscribe(L: ?*lua.State) callconv(.c) c_int {
    var nlen: usize = 0;
    const n = lua.lua_tolstring(L, 1, &nlen) orelse return 0;
    labelle_event_subscribe(n, nlen);
    return 0;
}
fn l_event_poll(L: ?*lua.State) callconv(.c) c_int {
    var buf: [NAME_CAP + JSON_CAP]u8 = undefined;
    const len = labelle_event_poll(&buf, buf.len);
    lua.lua_pushlstring(L, &buf, len); // "" when the inbox is empty
    return 1;
}

fn runLua(script: [*:0]const u8) !void {
    const L = lua.luaL_newstate() orelse return error.LuaInit;
    defer lua.lua_close(L);
    lua.luaL_openlibs(L);

    // The `labelle` binding table.
    lua.lua_createtable(L, 0, 5);
    lua.lua_pushcclosure(L, l_entity_create, 0);
    lua.lua_setfield(L, -2, "entity_create");
    lua.lua_pushcclosure(L, l_component_set, 0);
    lua.lua_setfield(L, -2, "component_set");
    lua.lua_pushcclosure(L, l_component_get, 0);
    lua.lua_setfield(L, -2, "component_get");
    lua.lua_pushcclosure(L, l_event_emit, 0);
    lua.lua_setfield(L, -2, "event_emit");
    lua.lua_pushcclosure(L, l_log, 0);
    lua.lua_setfield(L, -2, "log");
    lua.lua_pushcclosure(L, l_event_subscribe, 0);
    lua.lua_setfield(L, -2, "event_subscribe");
    lua.lua_pushcclosure(L, l_event_poll, 0);
    lua.lua_setfield(L, -2, "event_poll");
    lua.lua_setglobal(L, "labelle");

    if (lua.luaL_loadstring(L, script) != 0 or lua.pcall(L, 0, lua.MULTRET) != 0) {
        var len: usize = 0;
        const err = lua.lua_tolstring(L, -1, &len);
        std.debug.print("lua error: {s}\n", .{if (err) |e| e[0..len] else "?"});
        return error.LuaScript;
    }

    _ = lua.lua_getglobal(L, "init");
    if (lua.pcall(L, 0, 0) != 0) return error.LuaScript;
    for (0..5) |i| {
        emitTick(i + 1);
        _ = lua.lua_getglobal(L, "update");
        lua.lua_pushnumber(L, world.dt);
        if (lua.pcall(L, 1, 0) != 0) return error.LuaScript;
    }
}

// ── Rust staticlib entry points (rust/src/lib.rs) ──────────────────────

extern fn rust_script_init() void;
extern fn rust_script_update(dt: f32) void;

// ── Crystal object entry points (crystal/script.cr) ────────────────────
// boot = GC.init + Crystal.main_user_code (the embed-as-library seam);
// the object's own `main` is localized away by `ld -r` in build.zig.

extern fn crystal_script_boot() void;
extern fn crystal_script_init() void;
extern fn crystal_script_update(dt: f32) void;

// ── Driver ──────────────────────────────────────────────────────────────

const behavior_lua = @embedFile("scripts/behavior.lua");

/// The host-side event the scripts subscribe to (one per tick).
fn emitTick(n: usize) void {
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"n\":{d}}}", .{n}) catch return;
    hostEmit("tick_started", json);
}

pub fn main() !void {
    var lua_snap_buf: [4096]u8 = undefined;
    var rust_snap_buf: [4096]u8 = undefined;

    std.debug.print("== Lua (embedded-VM family) ==\n", .{});
    world.reset();
    // Null-terminate the embedded script for luaL_loadstring.
    var script_z: [behavior_lua.len + 1]u8 = undefined;
    @memcpy(script_z[0..behavior_lua.len], behavior_lua);
    script_z[behavior_lua.len] = 0;
    try runLua(@ptrCast(&script_z));
    const lua_snap = world.snapshot(&lua_snap_buf);
    std.debug.print("{s}", .{lua_snap});

    std.debug.print("\n== Rust (native-compiled family) ==\n", .{});
    world.reset();
    rust_script_init();
    for (0..5) |i| {
        emitTick(i + 1);
        rust_script_update(world.dt);
    }
    const rust_snap = world.snapshot(&rust_snap_buf);
    std.debug.print("{s}", .{rust_snap});

    std.debug.print("\n== Crystal (native-compiled family) ==\n", .{});
    var crystal_snap_buf: [4096]u8 = undefined;
    crystal_script_boot(); // one-time runtime init (GC + top-level)
    world.reset();
    crystal_script_init();
    for (0..5) |i| {
        emitTick(i + 1);
        crystal_script_update(world.dt);
    }
    const crystal_snap = world.snapshot(&crystal_snap_buf);
    std.debug.print("{s}", .{crystal_snap});

    std.debug.print("\n== verdict ==\n", .{});
    if (std.mem.eql(u8, lua_snap, rust_snap) and std.mem.eql(u8, lua_snap, crystal_snap)) {
        std.debug.print("FAMILIES AGREE: one contract, three languages (Lua VM, Rust, Crystal), identical world state.\n", .{});
    } else {
        std.debug.print("MISMATCH — POC FAILED\n", .{});
        return error.SnapshotMismatch;
    }
}
