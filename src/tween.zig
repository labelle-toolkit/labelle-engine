/// Tween — central fire-and-forget motion records (#669).
///
/// Motion lives as plain structs in a dense array owned by one
/// `TweenSystem`, stepped once per frame by `tween_tick.zig` — NOT as
/// per-entity ECS components, NOT as per-node objects. This mirrors the
/// Godot 4 tween rewrite (tweens are references processed centrally, not
/// nodes) and LitMotion's data-oriented dispatcher (flat arrays + handle
/// indirection for O(1) cancel without fragmenting storage).
///
/// A tween is a flat list of `Step`s, each with a `start_offset` (seconds
/// from tween start) and `duration`. Steps run sequentially by default;
/// `.join()` makes the next step start at the same offset as the previous
/// one (DOTween's Join — parallel grouping without a group object). This
/// flat-list-with-offsets model is simpler than nested parallel groups.
///
/// ## Zig has no closures
/// Bindings are a function pointer + `*anyopaque` context, never a
/// captured lambda. The caller guarantees `ctx` outlives the tween, or
/// binds an entity (`.bindEntity`) so the tween is killed the frame the
/// entity dies (`tween_tick` checks liveness). Never store pointers into
/// ECS component storage across frames — archetype moves invalidate them;
/// re-fetch through the entity handle inside the apply function.
///
/// ## Save/load
/// Tweens are transient by design and are NEVER serialized. Game state
/// re-derives them on load (Godot's model).
///
/// The pure data + storage + builder live here; the per-frame step
/// function is `tween_tick.zig` (the repo's "one type + one tick fn,
/// paired" pattern, like `sprite_animation` + `sprite_animation_tick`).

const std = @import("std");
const easing = @import("easing.zig");

/// Max steps per tween. Overflow is asserted, not silently dropped — bump
/// this if a real tween needs more (a Vec2 move is 2 steps via `.join()`).
pub const max_steps = 16;

/// Stable reference to a tween slot. `generation` guards against acting on
/// a slot that was killed and reused (stale handles are silently ignored).
pub const TweenHandle = struct { index: u32, generation: u32 };

pub const StepKind = enum(u8) {
    /// Interpolate a value and write it via `apply`.
    property,
    /// Timed wait; contributes only to `total_duration`.
    interval,
    /// Invoke `call` once when the step is reached.
    callback,
    /// Same runtime shape as `property` (interpolate → `apply`); kept a
    /// distinct kind for authoring clarity (call a method with a value).
    method,
};

pub const Step = struct {
    kind: StepKind,
    /// Seconds from tween start. Computed by the builder (append = end of
    /// previous; join = start of previous).
    start_offset: f32 = 0,
    /// Seconds. 0 for callbacks (and any instant property).
    duration: f32 = 0,
    curve: easing.Curve = .linear,
    placement: easing.Placement = .out,
    from: f32 = 0,
    to: f32 = 0,
    /// property/method: `apply(ctx, value)`.
    apply: ?*const fn (ctx: *anyopaque, value: f32) void = null,
    /// callback: `call(ctx)`.
    call: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,
};

pub const Tween = struct {
    steps: [max_steps]Step = undefined,
    /// Per-step "already finalized/fired" bits. Reset on each loop.
    fired: [max_steps]bool = [_]bool{false} ** max_steps,
    step_count: u8 = 0,
    elapsed: f32 = 0,
    /// max over steps of `start_offset + duration`; precomputed by the builder.
    total_duration: f32 = 0,
    /// Opt-in despawn safety: `tween_tick` kills the tween the frame this
    /// entity stops existing in the ECS backend. `null` = unbound.
    bound_entity: ?u64 = null,
    /// Total loops to run; 0 = infinite.
    loops: u16 = 1,
    loops_done: u16 = 0,
    alive: bool = false,
    generation: u32 = 0,
};

pub const TweenSystem = struct {
    allocator: std.mem.Allocator,
    /// Dense slot storage; slots are reused via `free_list`, never removed,
    /// so live `TweenHandle` indices stay valid (generation guards reuse).
    tweens: std.ArrayList(Tween) = .empty,
    free_list: std.ArrayList(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) TweenSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TweenSystem) void {
        self.tweens.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.* = undefined;
    }

    /// Pre-allocate storage so `create()` never allocates mid-game
    /// (LitMotion's EnsureStorageCapacity). With this called at boot,
    /// running N simultaneous tweens is allocation-free.
    pub fn ensureCapacity(self: *TweenSystem, n: usize) !void {
        try self.tweens.ensureTotalCapacity(self.allocator, n);
        try self.free_list.ensureTotalCapacity(self.allocator, n);
    }

    /// Number of currently-alive tweens (O(n); for tests/telemetry).
    pub fn aliveCount(self: *const TweenSystem) usize {
        var c: usize = 0;
        for (self.tweens.items) |t| {
            if (t.alive) c += 1;
        }
        return c;
    }

    /// Resolve a handle to its live tween, or null if the slot is dead or
    /// the handle is stale (generation mismatch).
    pub fn get(self: *TweenSystem, handle: TweenHandle) ?*Tween {
        if (handle.index >= self.tweens.items.len) return null;
        const t = &self.tweens.items[handle.index];
        if (t.generation != handle.generation or !t.alive) return null;
        return t;
    }

    /// Begin a fire-and-forget tween. Reuses a free slot or appends one.
    /// Returns a value-semantics builder; chain steps then let it drop —
    /// the tween is live from this frame. On the (rare, pre-`ensureCapacity`)
    /// OOM path the returned builder is inert (its methods no-op), so a
    /// dropped tween simply never runs — fire-and-forget stays infallible.
    pub fn create(self: *TweenSystem) TweenBuilder {
        if (self.free_list.pop()) |slot| {
            const t = &self.tweens.items[slot];
            const gen = t.generation +% 1;
            t.* = .{ .generation = gen, .alive = true };
            return .{ .system = self, .handle = .{ .index = slot, .generation = gen } };
        }
        const index: u32 = @intCast(self.tweens.items.len);
        self.tweens.append(self.allocator, .{ .generation = 0, .alive = true }) catch {
            return .{ .system = self, .handle = .{ .index = 0, .generation = 0 }, .valid = false };
        };
        return .{ .system = self, .handle = .{ .index = index, .generation = 0 } };
    }

    /// Stop a tween now. Stale/already-dead handles are silently ignored.
    /// Its remaining callbacks never fire.
    pub fn kill(self: *TweenSystem, handle: TweenHandle) void {
        const t = self.get(handle) orelse return;
        t.alive = false;
        self.free_list.append(self.allocator, handle.index) catch {};
    }

    /// Kill every live tween (e.g. on scene teardown).
    pub fn killAll(self: *TweenSystem) void {
        for (self.tweens.items, 0..) |*t, i| {
            if (t.alive) {
                t.alive = false;
                self.free_list.append(self.allocator, @intCast(i)) catch {};
            }
        }
    }
};

/// Value-semantics cursor over a tween being built. Each method returns a
/// fresh builder so chaining threads `join_next` correctly; the tween data
/// itself lives in the `TweenSystem` (reached via `handle`), so copying the
/// builder is cheap and lifetime-free.
pub const TweenBuilder = struct {
    system: *TweenSystem,
    handle: TweenHandle,
    join_next: bool = false,
    valid: bool = true,

    fn tween(self: TweenBuilder) ?*Tween {
        if (!self.valid) return null;
        return self.system.get(self.handle);
    }

    fn addStep(self: TweenBuilder, step: Step) TweenBuilder {
        const t = self.tween() orelse return self;
        std.debug.assert(t.step_count < max_steps); // bump max_steps if this fires
        if (t.step_count >= max_steps) return self;

        var s = step;
        if (t.step_count == 0) {
            s.start_offset = 0;
        } else {
            const prev = t.steps[t.step_count - 1];
            s.start_offset = if (self.join_next) prev.start_offset else prev.start_offset + prev.duration;
        }
        t.steps[t.step_count] = s;
        t.step_count += 1;
        t.total_duration = @max(t.total_duration, s.start_offset + s.duration);
        return .{ .system = self.system, .handle = self.handle, .valid = self.valid };
    }

    /// Animate `apply(ctx, v)` from `from` to `to` over `duration` seconds.
    pub fn property(
        self: TweenBuilder,
        ctx: *anyopaque,
        apply: *const fn (ctx: *anyopaque, value: f32) void,
        from: f32,
        to: f32,
        duration: f32,
    ) TweenBuilder {
        return self.addStep(.{ .kind = .property, .duration = duration, .from = from, .to = to, .apply = apply, .ctx = ctx });
    }

    /// Like `property` but tagged `.method` (call a method with an
    /// interpolated argument). Identical runtime behavior.
    pub fn method(
        self: TweenBuilder,
        ctx: *anyopaque,
        apply: *const fn (ctx: *anyopaque, value: f32) void,
        from: f32,
        to: f32,
        duration: f32,
    ) TweenBuilder {
        return self.addStep(.{ .kind = .method, .duration = duration, .from = from, .to = to, .apply = apply, .ctx = ctx });
    }

    /// Timed wait.
    pub fn interval(self: TweenBuilder, duration: f32) TweenBuilder {
        return self.addStep(.{ .kind = .interval, .duration = duration });
    }

    /// Invoke `call(ctx)` once when reached.
    pub fn callback(self: TweenBuilder, ctx: *anyopaque, call: *const fn (ctx: *anyopaque) void) TweenBuilder {
        return self.addStep(.{ .kind = .callback, .duration = 0, .call = call, .ctx = ctx });
    }

    /// Set the easing of the most-recently-added step.
    pub fn ease(self: TweenBuilder, curve: easing.Curve, placement: easing.Placement) TweenBuilder {
        const t = self.tween() orelse return self;
        if (t.step_count > 0) {
            t.steps[t.step_count - 1].curve = curve;
            t.steps[t.step_count - 1].placement = placement;
        }
        return self;
    }

    /// Make the NEXT added step start at the same offset as the previous
    /// step (parallel with it) instead of after it.
    pub fn join(self: TweenBuilder) TweenBuilder {
        return .{ .system = self.system, .handle = self.handle, .join_next = true, .valid = self.valid };
    }

    /// Kill the tween the frame `entity` stops existing in the ECS backend.
    pub fn bindEntity(self: TweenBuilder, entity: u64) TweenBuilder {
        if (self.tween()) |t| t.bound_entity = entity;
        return self;
    }

    /// Loop count; 0 = infinite. Default 1.
    pub fn loops(self: TweenBuilder, n: u16) TweenBuilder {
        if (self.tween()) |t| t.loops = n;
        return self;
    }
};
