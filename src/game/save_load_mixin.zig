//! Save/Load mixin — generic game state serialization.
//!
//! Provides saveGameState/loadGameState methods on the Game struct.
//! Component save behavior is declared via Saveable(...) in labelle-core.
//! No game-specific code — works with any component registry.

const std = @import("std");
const core = @import("labelle-core");
const serde = core.serde;

const SAVE_VERSION: u32 = 2;
const MAX_SAVE_SIZE = 256 * 1024 * 1024; // 256 MB

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Reg = Game.ComponentRegistry;

    return struct {
        fn entityToU64(entity: Entity) u64 {
            return @intCast(entity);
        }

        /// Collect entities from a view into an ArrayList, closing the view after.
        fn collectEntities(comptime T: type, ecs: anytype, allocator: std.mem.Allocator) !std.ArrayList(Entity) {
            var buf: std.ArrayList(Entity) = .{};
            errdefer buf.deinit(allocator);
            var view = ecs.view(.{T}, .{});
            defer view.deinit();
            while (view.next()) |ent| {
                try buf.append(allocator, ent);
            }
            return buf;
        }

        // ─── Save ───────────────────────────────────────────────────

        pub fn saveGameState(self: *Game, filename: []const u8) !void {
            @setEvalBranchQuota(10000);
            const allocator = self.allocator;
            const names = comptime Reg.names();

            // Collect all entities with saveable or marker components
            var entity_set = std.AutoHashMap(u64, void).init(allocator);
            defer entity_set.deinit();
            var entity_list: std.ArrayList(u64) = .{};
            defer entity_list.deinit(allocator);

            inline for (names) |name| {
                const T = Reg.getType(name);
                if (comptime core.getSavePolicy(T)) |policy| {
                    if (policy == .saveable or policy == .marker) {
                        var entities = try collectEntities(T, &self.active_world.ecs_backend, allocator);
                        defer entities.deinit(allocator);
                        for (entities.items) |entity| {
                            const id = entityToU64(entity);
                            if (!entity_set.contains(id)) {
                                try entity_set.put(id, {});
                                try entity_list.append(allocator, id);
                            }
                        }
                    }
                }
            }

            var aw: std.ArrayList(u8) = .{};
            defer aw.deinit(allocator);
            const writer = aw.writer(allocator);

            try std.fmt.format(writer, "{{\n  \"version\": {d},\n  \"entities\": [\n", .{SAVE_VERSION});

            for (entity_list.items, 0..) |id, idx| {
                const entity: Entity = @intCast(id);

                if (idx > 0) try writer.writeAll(",\n");
                try writer.writeAll("    {\n");
                try std.fmt.format(writer, "      \"id\": {d}", .{id});

                // Components (saveable + marker — includes Position)
                try writer.writeAll(",\n      \"components\": {");
                var first_comp = true;
                inline for (names) |name| {
                    const T = Reg.getType(name);
                    if (comptime core.getSavePolicy(T)) |policy| {
                        if (policy == .saveable or policy == .marker) {
                            if (self.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                                if (!first_comp) try writer.writeAll(",");
                                try writer.writeAll("\n        \"");
                                try writer.writeAll(comptime serde.componentName(T));
                                try writer.writeAll("\": ");
                                try serde.writeComponent(T, comp, writer, serde.autoSkipField);
                                first_comp = false;
                            }
                        }
                    }
                }
                try writer.writeAll("\n      }");

                // Ref arrays — collect all ref array fields across components into one JSON object
                var has_ref_arrays = false;
                inline for (names) |name| {
                    const T = Reg.getType(name);
                    if (comptime serde.hasRefArrayFields(T)) {
                        if (self.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                            if (!has_ref_arrays) {
                                try writer.writeAll(",\n      \"ref_arrays\": {");
                                has_ref_arrays = true;
                            } else {
                                try writer.writeAll(",");
                            }
                            try serde.writeRefArrayFields(T, comp, writer);
                        }
                    }
                }
                if (has_ref_arrays) {
                    try writer.writeAll("}");
                }

                try writer.writeAll("\n    }");
            }

            try writer.writeAll("\n  ]\n}\n");

            const cwd = std.fs.cwd();
            const file = try cwd.createFile(filename, .{});
            defer file.close();
            try file.writeAll(aw.items);
        }

        // ─── Load ───────────────────────────────────────────────────

        pub fn loadGameState(self: *Game, filename: []const u8) !void {
            @setEvalBranchQuota(10000);
            const allocator = self.allocator;
            const names = comptime Reg.names();

            const cwd = std.fs.cwd();
            const json = try cwd.readFileAlloc(allocator, filename, MAX_SAVE_SIZE);
            defer allocator.free(json);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
            defer parsed.deinit();

            const root = parsed.value.object;

            const version = (root.get("version") orelse return error.MissingField).integer;
            if (version != SAVE_VERSION) {
                return error.UnsupportedVersion;
            }

            const entities_json = (root.get("entities") orelse return error.MissingField).array;

            // Step 1: Clear scene tracking and destroy all entities atomically
            self.clearActiveSceneEntities();
            self.resetEcsBackend();

            // Step 2: Create new entities and build ID map
            var id_map = std.AutoHashMap(u64, u64).init(allocator);
            defer id_map.deinit();

            for (entities_json.items) |entry| {
                const obj = entry.object;
                const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
                const new_entity = self.createEntity();
                try id_map.put(saved_id, entityToU64(new_entity));
            }

            // Step 3: Restore components (includes Position)
            for (entities_json.items) |entry| {
                const obj = entry.object;
                const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);

                const components = (obj.get("components") orelse continue).object;

                inline for (names) |name| {
                    const T = Reg.getType(name);
                    if (comptime core.getSavePolicy(T)) |policy| {
                        if (policy == .saveable or policy == .marker) {
                            const comp_name = comptime serde.componentName(T);
                            if (components.get(comp_name)) |comp_val| {
                                if (serde.readComponent(T, comp_val, serde.autoSkipField)) |restored| {
                                    var comp = restored;
                                    serde.remapEntityRefs(T, &comp, &id_map);
                                    self.active_world.ecs_backend.addComponent(entity, comp);
                                } else |_| {}
                            }
                        }
                    }
                }
            }

            // Step 4: Restore ref arrays ([]const u64 slices)
            const arena = self.active_world.nested_entity_arena.allocator();

            for (entities_json.items) |entry| {
                const obj = entry.object;
                const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);

                if (obj.get("ref_arrays")) |ref_arrays_val| {
                    const ref_obj = ref_arrays_val.object;
                    inline for (names) |name| {
                        const T = Reg.getType(name);
                        if (comptime serde.hasRefArrayFields(T)) {
                            if (self.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                                try serde.readRefArrays(T, comp, ref_obj, &id_map, arena);
                            }
                        }
                    }
                }
            }

            // Step 5: Register entities with scene
            for (entities_json.items) |entry| {
                const obj = entry.object;
                const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);
                self.addEntityToActiveScene(entity);
            }

            // Step 6: Post-load cleanup

            // 6a: Component-level postLoad hooks
            inline for (names) |name| {
                const T = Reg.getType(name);
                if (comptime core.hasPostLoad(T)) {
                    var entities = try collectEntities(T, &self.active_world.ecs_backend, allocator);
                    defer entities.deinit(allocator);
                    for (entities.items) |ent| {
                        if (self.active_world.ecs_backend.getComponent(ent, T)) |comp| {
                            comp.postLoad(self, ent);
                        }
                    }
                }
            }

            // 6b: post_load_add markers
            inline for (names) |name| {
                const T = Reg.getType(name);
                const markers = comptime core.getPostLoadMarkers(T);
                if (markers.len > 0) {
                    var entities = try collectEntities(T, &self.active_world.ecs_backend, allocator);
                    defer entities.deinit(allocator);
                    for (entities.items) |ent| {
                        inline for (markers) |Marker| {
                            if (!self.active_world.ecs_backend.hasComponent(ent, Marker)) {
                                self.active_world.ecs_backend.addComponent(ent, Marker{});
                            }
                        }
                    }
                }
            }

            // 6c: post_load_create entities
            inline for (names) |name| {
                const T = Reg.getType(name);
                if (comptime core.getPostLoadCreate(T)) {
                    const ent = self.createEntity();
                    self.active_world.ecs_backend.addComponent(ent, T{});
                    self.addEntityToActiveScene(ent);
                }
            }
        }
    };
}
