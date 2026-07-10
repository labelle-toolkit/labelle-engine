//! First-class command-buffer facility — deferred world-mutation staging
//! with conflict detection, parameterized over a game-supplied `Command`
//! type (labelle-engine#615).
//!
//! ## Why this lives in the engine
//!
//! A command buffer is a *runtime* mechanism: scripts push commands
//! during a frame instead of mutating the world directly, then at a
//! safe end-of-frame sync point the runtime detects conflicts (two
//! commands mutating the same entity in one frame) and applies/clears.
//! Only the runtime knows when "end of frame" is, so the facility
//! belongs next to the scheduler — not in `labelle-core`, which is the
//! zero-dependency contract layer that *runs nothing*.
//!
//! This graduates a mechanism that previously lived per-game in
//! flying-platform's vendored `libs/command_buffer` plugin. That
//! version hard-coded a game-domain `Command` union (`assign_work`,
//! `begin_wander`, …); the engine can't own those verbs and stay
//! game-agnostic. So — exactly like `labelle-core`'s `Ecs(Backend)`
//! comptime-trait — the engine provides the MECHANISM and the game
//! supplies the `Command` TYPE plus a small contract the engine
//! validates at comptime.
//!
//! ## The contract a game `Command` must satisfy
//!
//! ```zig
//! const Command = union(enum) {
//!     assign: struct { worker: u64, station: u64 },
//!     complete: struct { worker: u64 },
//!
//!     /// The entity keys this command would mutate. Fixed-size array;
//!     /// unused slots are `null`. The element (`Key`) and arity (`N`)
//!     /// are inferred from this signature.
//!     pub fn writeKeys(self: Command) [2]?u64 { ... }
//!
//!     /// True for commands that *release* an entity back to idle.
//!     pub fn releasesWorker(self: Command) bool { ... }
//!
//!     /// True for commands that *acquire* an entity into a new job.
//!     pub fn acquiresWorker(self: Command) bool { ... }
//! };
//!
//! var buf = engine.CommandBuffer(Command).init(allocator);
//! defer buf.deinit();
//! try buf.push(.{ .assign = .{ .worker = 1, .station = 2 } });
//! const report = buf.detectConflicts();
//! buf.apply(&world, applyOne); // deferred apply, then clears
//! ```

const std = @import("std");

/// Build a command-buffer type over a game-supplied `Command`.
///
/// `Command` must satisfy the comptime contract (validated below):
///   - `writeKeys(self) [N]?Key` — the entity keys this command mutates.
///   - `releasesWorker(self) bool`
///   - `acquiresWorker(self) bool`
///
/// The engine owns growable storage, `push`/`clear`/`apply`, and the
/// conflict detector. The game owns the `Command` type and its methods.
pub fn CommandBuffer(comptime Command: type) type {
    comptime validateCommandContract(Command);

    const Key = CommandKey(Command);
    const key_count = commandKeyCount(Command);

    return struct {
        const Self = @This();

        /// The entity-key type inferred from `Command.writeKeys`.
        pub const KeyType = Key;
        /// The number of write-key slots per command.
        pub const key_slots = key_count;

        /// A pair of commands that conflict because they both target the
        /// same entity key within a single frame.
        pub const Conflict = struct {
            /// Index of the first command in the buffer.
            cmd_a: usize,
            /// Index of the second command in the buffer.
            cmd_b: usize,
            /// The entity key both commands would mutate.
            entity: Key,
        };

        /// Result of conflict detection — a fixed-capacity list of
        /// conflicts so detection stays allocation-free.
        pub const ConflictReport = struct {
            conflicts: [MAX_CONFLICTS]Conflict = undefined,
            len: usize = 0,
            /// Set when more conflicts were found than `MAX_CONFLICTS`
            /// could hold.
            overflow: bool = false,

            pub const MAX_CONFLICTS = 32;

            pub fn slice(self: *const ConflictReport) []const Conflict {
                return self.conflicts[0..self.len];
            }

            /// True when no conflicting command pairs were detected.
            pub fn isEmpty(self: *const ConflictReport) bool {
                return self.len == 0 and !self.overflow;
            }
        };

        /// Growable command storage, owned and freed by the engine (not
        /// a game ECS component). `clear` retains capacity so the steady
        /// state is allocation-free.
        commands: std.ArrayListUnmanaged(Command) = .empty,
        allocator: std.mem.Allocator,

        /// Create an empty buffer. The buffer owns its storage; call
        /// `deinit` to free it.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Free the buffer's growable storage.
        pub fn deinit(self: *Self) void {
            self.commands.deinit(self.allocator);
            self.* = undefined;
        }

        /// Stage a command for deferred apply. Grows storage on demand,
        /// so a push only fails on OOM (`error.OutOfMemory`).
        pub fn push(self: *Self, cmd: Command) !void {
            try self.commands.append(self.allocator, cmd);
        }

        /// Number of commands staged so far this frame.
        pub fn count(self: *const Self) usize {
            return self.commands.items.len;
        }

        /// The staged commands as a read-only slice.
        pub fn slice(self: *const Self) []const Command {
            return self.commands.items;
        }

        /// Reset the buffer for the next frame, retaining capacity.
        pub fn clear(self: *Self) void {
            self.commands.clearRetainingCapacity();
        }

        /// Scan all pairs of staged commands and report conflicts where
        /// two commands share a write-key (both would mutate the same
        /// entity). See `detectConflictsSlice` for the release-before-
        /// acquire handoff exemption.
        pub fn detectConflicts(self: *const Self) ConflictReport {
            return detectConflictsSlice(self.commands.items);
        }

        /// Deferred apply: invoke `applyFn(ctx, cmd)` for each staged
        /// command in push order, then clear the buffer for the next
        /// frame. This is the "safe sync point" the runtime drives at
        /// end-of-frame — commands are applied in a single controlled
        /// pass rather than mid-frame from scattered scripts.
        pub fn apply(
            self: *Self,
            ctx: anytype,
            comptime applyFn: fn (@TypeOf(ctx), Command) void,
        ) void {
            for (self.commands.items) |cmd| applyFn(ctx, cmd);
            self.clear();
        }

        /// Conflict detection over an arbitrary command slice —
        /// capacity- and allocation-independent. `writeKeys` is computed
        /// in-loop rather than precomputed; at realistic per-frame
        /// command counts the O(N^2) compare dominates anyway, and this
        /// keeps the routine allocation-free.
        ///
        /// One pattern is deliberately *not* a conflict: an entity
        /// released back to idle and re-acquired into a new job within
        /// the same frame (an ordered handoff — the acquire wins). The
        /// detector exempts release-before-acquire pairs so it only
        /// flags genuine races (two acquires on one entity, two items
        /// into one slot). Acquire-before-release is *not* exempt — that
        /// ordering is suspect and stays reported. Relaxing this
        /// exemption would hide genuine double-acquire races.
        pub fn detectConflictsSlice(cmds: []const Command) ConflictReport {
            var report = ConflictReport{};
            for (0..cmds.len) |i| {
                const ki = cmds[i].writeKeys();
                for ((i + 1)..cmds.len) |j| {
                    if (keysOverlap(ki, cmds[j].writeKeys())) |entity| {
                        if (cmds[i].releasesWorker() and cmds[j].acquiresWorker()) continue;
                        if (report.len < ConflictReport.MAX_CONFLICTS) {
                            report.conflicts[report.len] = .{ .cmd_a = i, .cmd_b = j, .entity = entity };
                            report.len += 1;
                        } else {
                            // Report is full and we've found one more
                            // conflict that can't be stored — flag overflow
                            // and stop. Continuing the O(N^2) sweep is wasted
                            // work: nothing further can change (`overflow` is
                            // already the terminal state).
                            report.overflow = true;
                            return report;
                        }
                    }
                }
            }
            return report;
        }

        /// Check whether two write-key sets share any entity key.
        /// Returns the first overlapping key, or null.
        fn keysOverlap(a: [key_count]?Key, b: [key_count]?Key) ?Key {
            for (a) |ka| {
                if (ka) |id_a| {
                    for (b) |kb| {
                        if (kb) |id_b| {
                            if (id_a == id_b) return id_a;
                        }
                    }
                }
            }
            return null;
        }
    };
}

/// Comptime type of the entity key a `Command` mutates — the element of
/// the optional array returned by `Command.writeKeys` (`[N]?Key` → `Key`).
pub fn CommandKey(comptime Command: type) type {
    const ret = @typeInfo(@TypeOf(Command.writeKeys)).@"fn".return_type.?;
    const arr = @typeInfo(ret).array;
    return @typeInfo(arr.child).optional.child;
}

/// Comptime arity of a `Command`'s write-key array (`[N]?Key` → `N`).
pub fn commandKeyCount(comptime Command: type) usize {
    const ret = @typeInfo(@TypeOf(Command.writeKeys)).@"fn".return_type.?;
    return @typeInfo(ret).array.len;
}

/// Validate at comptime that `Command` satisfies the buffer's contract,
/// emitting a readable `@compileError` when it doesn't. Mirrors the
/// trait-checking `labelle-core`'s `Ecs(Backend)` performs on its
/// backend.
pub fn validateCommandContract(comptime Command: type) void {
    if (!@hasDecl(Command, "writeKeys"))
        @compileError("CommandBuffer: `" ++ @typeName(Command) ++
            "` must declare `pub fn writeKeys(self) [N]?Key`");
    if (!@hasDecl(Command, "releasesWorker"))
        @compileError("CommandBuffer: `" ++ @typeName(Command) ++
            "` must declare `pub fn releasesWorker(self) bool`");
    if (!@hasDecl(Command, "acquiresWorker"))
        @compileError("CommandBuffer: `" ++ @typeName(Command) ++
            "` must declare `pub fn acquiresWorker(self) bool`");

    // Each contract decl must be a *function*. Accessing `.@"fn"` on a
    // non-function `@typeInfo` panics with an obscure "inactive union
    // field" error, so gate on the tag first and emit a clear message
    // naming the offending decl.
    requireFnDecl(Command, "writeKeys");
    requireFnDecl(Command, "releasesWorker");
    requireFnDecl(Command, "acquiresWorker");

    const ret = @typeInfo(@TypeOf(Command.writeKeys)).@"fn".return_type orelse
        @compileError("CommandBuffer: `writeKeys` must return `[N]?Key`");
    const ret_info = @typeInfo(ret);
    if (ret_info != .array)
        @compileError("CommandBuffer: `writeKeys` must return an array `[N]?Key`, got `" ++
            @typeName(ret) ++ "`");
    if (@typeInfo(ret_info.array.child) != .optional)
        @compileError("CommandBuffer: `writeKeys` array elements must be optional `?Key`");

    const RelRet = @typeInfo(@TypeOf(Command.releasesWorker)).@"fn".return_type;
    if (RelRet != bool)
        @compileError("CommandBuffer: `releasesWorker` must return `bool`");
    const AcqRet = @typeInfo(@TypeOf(Command.acquiresWorker)).@"fn".return_type;
    if (AcqRet != bool)
        @compileError("CommandBuffer: `acquiresWorker` must return `bool`");
}

/// Assert that `Command.<name>` is a function, with a readable
/// `@compileError` (naming the decl) when a game declares it as a const,
/// field, or other non-function value — otherwise the subsequent
/// `.@"fn"` access panics on an inactive union field.
fn requireFnDecl(comptime Command: type, comptime name: []const u8) void {
    if (@typeInfo(@TypeOf(@field(Command, name))) != .@"fn")
        @compileError("CommandBuffer: `" ++ @typeName(Command) ++ "." ++ name ++
            "` must be a function (`pub fn " ++ name ++ "(self) ...`), not a const/field");
}
