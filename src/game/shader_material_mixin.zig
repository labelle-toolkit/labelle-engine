const std = @import("std");
const core = @import("labelle-core");
const sm = @import("../shader_material.zig");

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Renderer = Game.RendererType;
    const supported = @hasDecl(Renderer, "createShaderMaterial") and
        @hasDecl(Renderer, "ShaderMaterialDescriptor") and @hasDecl(Renderer, "shaderMaterialSupported") and
        @hasDecl(Renderer, "setShaderParameter") and @hasDecl(Renderer, "setShaderTexture") and
        @hasDecl(Renderer, "destroyShaderMaterial") and @hasField(Game.SpriteComp, "material");
    return struct {
        pub fn shaderMaterial(self: *const Game, entity: Entity) ?sm.contract.Id {
            const record = self.active_world.shader_materials.get(entity) orelse return null;
            return record.id;
        }

        fn clearPending(self: *Game, world: *Game.World, entity: Entity) void {
            const old = world.shader_pending.fetchRemove(entity) orelse return;
            var keys = old.value;
            for (keys.items) |item| freePending(self, item);
            keys.deinit(self.allocator);
        }

        fn freePending(self: *Game, item: sm.Pending) void {
            self.assets.release(item.key);
            self.allocator.free(item.key);
            self.allocator.free(item.name);
        }

        fn cancelPendingBinding(self: *Game, entity: Entity, name: []const u8, keep_key: ?[]const u8) void {
            const pending = self.active_world.shader_pending.getPtr(entity) orelse return;
            for (pending.items, 0..) |held, i| {
                if (!std.mem.eql(u8, held.name, name)) continue;
                if (keep_key) |key| if (std.mem.eql(u8, held.key, key)) return;
                freePending(self, pending.swapRemove(i));
                return;
            }
        }

        fn requestPending(self: *Game, entity: Entity, name: []const u8, key: []const u8) !void {
            cancelPendingBinding(self, entity, name, key);
            const gop = try self.active_world.shader_pending.getOrPut(self.allocator, entity);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |held| if (std.mem.eql(u8, held.name, name)) return;
            const copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(copy);
            const binding = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(binding);
            try gop.value_ptr.ensureUnusedCapacity(self.allocator, 1);
            _ = try self.assets.acquire(key);
            errdefer self.assets.release(key);
            if (self.assets.entries.getPtr(key).?.state == .registered) return error.AssetDecodeNotQueued;
            gop.value_ptr.appendAssumeCapacity(.{ .name = binding, .key = copy });
        }

        fn releaseRecord(self: *Game, world: *Game.World, record: sm.Record) void {
            if (comptime supported) {
                if (record.id != .none) world.renderer.destroyShaderMaterial(record.id);
            }
            for (record.textures[0..record.len]) |binding| {
                if (binding.catalog) |key| {
                    self.assets.release(key);
                    self.allocator.free(key);
                }
                self.allocator.free(binding.name);
            }
        }

        /// Requires a live sprite. Failure preserves the previous material and pins.
        pub fn createShaderMaterial(self: *Game, entity: Entity, desc: sm.Descriptor) anyerror!void {
            if (comptime !supported) return error.Unsupported;
            if (!self.assets.gpu_alive) return error.GpuSurfaceUnavailable;
            if (!self.renderer.shaderMaterialSupported()) return error.Unsupported;
            if (!self.ecs_backend.entityExists(entity)) return error.InvalidEntity;
            const sprite = self.ecs_backend.getComponent(entity, Game.SpriteComp) orelse return error.MissingSprite;
            errdefer |err| if (err != error.TextureNotReady) clearPending(self, self.active_world, entity);
            if (desc.textures.len > sm.contract.MAX_TEXTURES) return error.CapacityExceeded;
            var validation_bindings: [sm.contract.MAX_TEXTURES]sm.contract.TextureBinding = undefined;
            for (desc.textures, 0..) |binding, i| validation_bindings[i] = .{ .name = binding.name, .sampler = binding.sampler };
            try sm.contract.validateDescriptor(.{ .version = desc.version, .label = desc.label, .shaders = desc.shaders, .parameters = desc.parameters, .textures = validation_bindings[0..desc.textures.len], .blend = desc.blend });
            // Drop pins no longer mentioned by a re-authored descriptor.
            if (self.active_world.shader_pending.getPtr(entity)) |pending| {
                var i: usize = 0;
                while (i < pending.items.len) {
                    const key = pending.items[i];
                    var keep = false;
                    for (desc.textures) |binding| switch (binding.texture) {
                        .catalog => |name| {
                            if (std.mem.eql(u8, key.key, name) and std.mem.eql(u8, key.name, binding.name)) {
                                keep = true;
                                break;
                            }
                        },
                        .id => {},
                    };
                    if (keep) {
                        i += 1;
                    } else {
                        freePending(self, key);
                        _ = pending.swapRemove(i);
                    }
                }
            }
            var record: sm.Record = .{ .id = .none };
            errdefer releaseRecord(self, self.active_world, record);
            const RD = Renderer.ShaderMaterialDescriptor;
            const RB = std.meta.Child(@FieldType(RD, "textures"));
            var bindings: [sm.contract.MAX_TEXTURES]RB = undefined;
            for (desc.textures, 0..) |binding, i| {
                const name = try self.allocator.dupe(u8, binding.name);
                record.textures[i] = .{ .name = name };
                record.len += 1;
                const texture = try resolveTexture(self, entity, binding.name, binding.texture, &record.textures[i].catalog);
                bindings[i] = .{ .name = binding.name, .texture = texture, .sampler = binding.sampler };
            }
            try self.active_world.shader_materials.ensureUnusedCapacity(self.allocator, 1);
            record.id = try self.renderer.createShaderMaterial(.{
                .version = desc.version,
                .label = desc.label,
                .shaders = desc.shaders,
                .parameters = desc.parameters,
                .textures = bindings[0..desc.textures.len],
                .blend = desc.blend,
            });
            if (self.active_world.shader_materials.fetchRemove(entity)) |old| releaseRecord(self, self.active_world, old.value);
            self.active_world.shader_materials.putAssumeCapacity(entity, record);
            // Only the shader slot is ours. `Material.shader` takes precedence
            // over a curated `effect` while it is live, but the curated effect
            // must SURVIVE the shader's lifetime: overwriting the whole
            // `Material` here silently drops an authored flash/outline/dissolve
            // and `clearShaderMaterial` (which only resets `.shader`) can never
            // give it back.
            sprite.material.shader = record.id;
            self.renderer.markVisualDirty(entity);
            clearPending(self, self.active_world, entity);
        }

        fn resolveTexture(self: *Game, entity: Entity, name: []const u8, texture: sm.Texture, pin: *?[]const u8) !core.TextureId {
            switch (texture) {
                .id => |id| return id,
                .catalog => |key| {
                    const entry = self.assets.entries.getPtr(key) orelse return error.AssetNotRegistered;
                    if (entry.loader_kind != .image) return error.InvalidTexture;
                    // Hold one pending pin across retries, which starts streaming even
                    // when the scene manifest did not infer this game-owned binding.
                    const resource = entry.resource orelse {
                        if (entry.state == .failed) return error.AssetLoadFailed;
                        try requestPending(self, entity, name, key);
                        return error.TextureNotReady;
                    };
                    const id = switch (resource) {
                        .image => |id| id,
                        else => return error.InvalidTexture,
                    };
                    const copy = try self.allocator.dupe(u8, key);
                    errdefer self.allocator.free(copy);
                    _ = try self.assets.acquire(key);
                    pin.* = copy;
                    return @enumFromInt(id);
                },
            }
        }

        pub fn setShaderParameter(self: *Game, entity: Entity, name: []const u8, values: []const f32) anyerror!void {
            if (comptime !supported) return error.Unsupported;
            // Contract: calls made while the GPU is unavailable report the
            // surface loss, not a handle error — `surfaceLost` has already
            // cleared every runtime id, so `InvalidHandle` here would read as
            // "this entity never had a material".
            if (!self.assets.gpu_alive) return error.GpuSurfaceUnavailable;
            const id = shaderMaterial(self, entity) orelse return error.InvalidHandle;
            self.renderer.setShaderParameter(id, name, values) catch |err| {
                if (err == error.InvalidHandle) clearShaderMaterial(self, entity);
                return @as(anyerror!void, err);
            };
        }

        /// Accepts a catalog key, TextureId, or explicit ShaderTexture union.
        pub fn setShaderTexture(self: *Game, entity: Entity, name: []const u8, source: anytype) anyerror!void {
            if (comptime !supported) return error.Unsupported;
            if (!self.assets.gpu_alive) return error.GpuSurfaceUnavailable;
            const record = self.active_world.shader_materials.getPtr(entity) orelse return error.InvalidHandle;
            const texture: sm.Texture = if (@TypeOf(source) == sm.Texture) source else if (@TypeOf(source) == core.TextureId) .{ .id = source } else .{ .catalog = source };
            var binding: ?*sm.HeldTexture = null;
            for (record.textures[0..record.len]) |*held| {
                if (std.mem.eql(u8, held.name, name)) {
                    binding = held;
                    break;
                }
            }
            const held = binding orelse return error.UnknownTexture;
            cancelPendingBinding(self, entity, name, switch (texture) {
                .catalog => |key| key,
                .id => null,
            });
            errdefer |err| if (err != error.TextureNotReady) cancelPendingBinding(self, entity, name, null);
            var pin: ?[]const u8 = null;
            const id = try resolveTexture(self, entity, name, texture, &pin);
            errdefer if (pin) |key| {
                self.assets.release(key);
                self.allocator.free(key);
            };
            self.renderer.setShaderTexture(record.id, name, id) catch |err| {
                if (err == error.InvalidHandle) clearShaderMaterial(self, entity);
                return @as(anyerror!void, err);
            };
            if (held.catalog) |key| {
                self.assets.release(key);
                self.allocator.free(key);
            }
            held.catalog = pin;
            cancelPendingBinding(self, entity, name, null);
        }

        pub fn clearShaderMaterial(self: *Game, entity: Entity) void {
            clearPending(self, self.active_world, entity);
            const old = self.active_world.shader_materials.fetchRemove(entity) orelse return;
            releaseRecord(self, self.active_world, old.value);
            if (comptime supported) if (self.ecs_backend.entityExists(entity)) if (self.ecs_backend.getComponent(entity, Game.SpriteComp)) |sprite| {
                if (sprite.material.shader == old.value.id) {
                    sprite.material.shader = .none;
                    self.renderer.markVisualDirty(entity);
                }
            };
        }

        /// World-local ownership prevents entity-id collisions across scene worlds.
        pub fn clearWorldShaderMaterials(self: *Game, world: *Game.World) void {
            while (world.shader_pending.count() != 0) {
                var pending = world.shader_pending.keyIterator();
                clearPending(self, world, pending.next().?.*);
            }
            var it = world.shader_materials.iterator();
            while (it.next()) |entry| {
                releaseRecord(self, world, entry.value_ptr.*);
                if (comptime supported) if (world.ecs_backend.entityExists(entry.key_ptr.*)) if (world.ecs_backend.getComponent(entry.key_ptr.*, Game.SpriteComp)) |sprite| {
                    sprite.material.shader = .none;
                    world.renderer.markVisualDirty(entry.key_ptr.*);
                };
            }
            world.shader_materials.clearRetainingCapacity();
            if (comptime @hasDecl(Renderer, "clearShaderMaterials")) world.renderer.clearShaderMaterials();
        }

        pub fn clearAllShaderMaterials(self: *Game) void {
            clearWorldShaderMaterials(self, self.active_world);
            var it = self.worlds.valueIterator();
            while (it.next()) |world| clearWorldShaderMaterials(self, world.*);
        }

        pub fn reapShaderMaterials(self: *Game) void {
            if (comptime !supported) return;
            while (true) {
                var pending = self.active_world.shader_pending.keyIterator();
                var dead: ?Entity = null;
                while (pending.next()) |entity| if (!self.ecs_backend.entityExists(entity.*) or !self.ecs_backend.hasComponent(entity.*, Game.SpriteComp)) {
                    dead = entity.*;
                    break;
                };
                clearPending(self, self.active_world, dead orelse break);
            }
            while (true) {
                var it = self.active_world.shader_materials.iterator();
                var dead: ?Entity = null;
                while (it.next()) |entry| {
                    const entity = entry.key_ptr.*;
                    const sprite = if (self.ecs_backend.entityExists(entity)) self.ecs_backend.getComponent(entity, Game.SpriteComp) else null;
                    if (!self.ecs_backend.entityExists(entity) or sprite == null or sprite.?.material.shader != entry.value_ptr.id) {
                        dead = entity;
                        break;
                    }
                }
                clearShaderMaterial(self, dead orelse break);
            }
        }
    };
}
