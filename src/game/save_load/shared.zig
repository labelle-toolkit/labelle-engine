//! Shared helpers for the save/load mixin family — JSON field access,
//! entity/id plumbing, the `(root, local_path)` child walker, and the
//! escape-correct JSON string writer. Split from `save_load_mixin.zig`
//! (>1000-line rule); same `Mixin(Game)` idiom as the siblings.

const std = @import("std");
const core = @import("labelle-core");
const serde = core.serde;

pub fn Shared(comptime Game: type) type {
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

        /// Read a boolean field out of a serialised Parent object,
        /// defaulting to `false` for missing / non-bool values. Kept
        /// local so the save and load sides of the built-in Parent
        /// pathway stay symmetric and the call sites don't repeat the
        /// `switch (v) { .bool => ... }` boilerplate.
        pub fn parentFlag(parent_obj: std.json.ObjectMap, field: []const u8) bool {
            const v = parent_obj.get(field) orelse return false;
            return switch (v) {
                .bool => |b| b,
                else => false,
            };
        }

        /// Safe JSON accessors for the load path. All return `null`
        /// on a tag mismatch rather than panicking via `.object` /
        /// `.integer` tag casts — so a malformed save file (wrong
        /// type, missing field, `null` where an object is expected)
        /// produces a logged warning and a skipped entity, not a
        /// debug-assertion panic or release-mode memory corruption.
        pub fn getComponentsObject(entry: std.json.Value) ?std.json.ObjectMap {
            if (entry != .object) return null;
            const comps_val = entry.object.get("components") orelse return null;
            return switch (comps_val) {
                .object => |o| o,
                else => null,
            };
        }

        pub fn getObjectField(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
            const v = obj.get(name) orelse return null;
            return switch (v) {
                .object => |o| o,
                else => null,
            };
        }

        pub fn getStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
            const v = obj.get(name) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        }

        /// Read a non-negative integer field as `u64` (for entity IDs).
        /// Clamps negative and out-of-range values to `null` so the
        /// caller's `orelse continue` pattern gracefully drops malformed
        /// entries.
        pub fn getU64Field(obj: std.json.ObjectMap, name: []const u8) ?u64 {
            const v = obj.get(name) orelse return null;
            return switch (v) {
                .integer => |i| if (i >= 0) @intCast(i) else null,
                else => null,
            };
        }

        /// Read the top-level `id` of a save entry as `u64`. Missing
        /// or non-integer `id` fields return `null` so the caller can
        /// skip the entry instead of panicking.
        pub fn getSavedId(entry: std.json.Value) ?u64 {
            if (entry != .object) return null;
            return getU64Field(entry.object, "id");
        }

        /// Read a numeric field as `f32`, accepting both `.float` and
        /// `.integer` JSON tags; returns 0 for missing or non-numeric
        /// values. Used for the Position shim in Phase 1a.
        pub fn getNumberField(obj: std.json.ObjectMap, name: []const u8) f32 {
            const v = obj.get(name) orelse return 0;
            return switch (v) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => 0,
            };
        }

        /// Walk a dotted `children[i]...` path from `root` through
        /// `game.getChildren`, returning the entity at the end or
        /// `null` when the path doesn't resolve (missing index,
        /// malformed syntax, root has no children, etc.). Matches the
        /// path format `spawnFromPrefab` (and the scene-bridge
        /// auto-tagger) emit, so save/load Phase 1 can find the
        /// re-spawned child that corresponds to each saved PrefabChild.
        pub fn findChildByLocalPath(self: *Game, root: Entity, local_path: []const u8) ?Entity {
            // Empty path is not valid — `PrefabChild.local_path` is always
            // at least `"children[0]"` when a child was legitimately
            // emitted. An empty string on the saved side indicates a
            // corrupted save, and resolving it to `root` would alias the
            // child's ID onto the root entity in `id_map`, causing Phase 2
            // to apply the child's components on top of the root. Return
            // null so the caller's `orelse` path logs + skips instead.
            if (local_path.len == 0) return null;

            var current: Entity = root;
            var rest = local_path;
            while (rest.len > 0) {
                if (rest[0] == '.') rest = rest[1..];
                const prefix = "children[";
                if (!std.mem.startsWith(u8, rest, prefix)) return null;
                rest = rest[prefix.len..];
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
                const idx = std.fmt.parseInt(usize, rest[0..close], 10) catch return null;
                rest = rest[close + 1 ..];

                const children = self.getChildren(current);
                if (idx >= children.len) return null;
                current = children[idx];
            }
            return current;
        }

        /// Recursively insert `root` and every descendant into `set`.
        /// Used by Phase 1a to record which entities came in through
        /// `spawnFromPrefab` (and were therefore renderer-tracked by
        /// the prefab spawn path) so Step 5 can skip re-tracking them.
        pub fn markSubtreeRendererTracked(
            self: *Game,
            root: Entity,
            set: *std.AutoHashMap(u64, void),
        ) !void {
            try set.put(entityToU64(root), {});
            for (self.getChildren(root)) |child| {
                try markSubtreeRendererTracked(self, child, set);
            }
        }

        /// Write a JSON-escaped string literal (including surrounding
        /// quotes) to `writer`. Used by the built-in save pathway for
        /// components with `[]const u8` fields (PrefabInstance.path,
        /// PrefabInstance.overrides, PrefabChild.local_path) — serde's
        /// `writeComponent` doesn't support string slices, so the save
        /// mixin handles these components as built-ins and needs its
        /// own escape helper.
        pub fn writeJsonString(writer: anytype, s: []const u8) !void {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0x08 => try writer.writeAll("\\b"),
                    0x0c => try writer.writeAll("\\f"),
                    0...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
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
