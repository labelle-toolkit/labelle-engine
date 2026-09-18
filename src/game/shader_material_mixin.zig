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

        /// Drops the entity's request for `name` (unless it is exactly
        /// `keep_key`) WITHOUT touching the map itself, so a caller holding
        /// a `getOrPut` pointer into it stays valid.
        fn removePendingBinding(self: *Game, entity: Entity, name: []const u8, keep_key: ?[]const u8) void {
            const pending = self.active_world.shader_pending.getPtr(entity) orelse return;
            for (pending.items, 0..) |held, i| {
                if (!std.mem.eql(u8, held.name, name)) continue;
                if (keep_key) |key| if (std.mem.eql(u8, held.key, key)) return;
                freePending(self, pending.swapRemove(i));
                return;
            }
        }

        fn cancelPendingBinding(self: *Game, entity: Entity, name: []const u8, keep_key: ?[]const u8) void {
            removePendingBinding(self, entity, name, keep_key);
            pruneEmptyPending(self, entity);
        }

        /// An entity with no live request owns no map entry: `count()` is
        /// what `World.deinit` asserts on and what "nothing pending" means.
        fn pruneEmptyPending(self: *Game, entity: Entity) void {
            const pending = self.active_world.shader_pending.getPtr(entity) orelse return;
            if (pending.items.len != 0) return;
            var list = self.active_world.shader_pending.fetchRemove(entity).?.value;
            list.deinit(self.allocator);
        }

        /// Stage-before-commit for PENDING pins: the replacement request is
        /// fully secured (copies made, reference acquired, decode confirmed
        /// queued) before the same-name request it supersedes is released,
        /// so a failure here drops nothing the entity already held.
        fn requestPending(self: *Game, entity: Entity, name: []const u8, key: []const u8) !void {
            if (self.active_world.shader_pending.getPtr(entity)) |pending| {
                for (pending.items) |held| if (std.mem.eql(u8, held.name, name) and std.mem.eql(u8, held.key, key)) return;
            }
            const copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(copy);
            const binding = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(binding);
            const gop = try self.active_world.shader_pending.getOrPut(self.allocator, entity);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            errdefer pruneEmptyPending(self, entity);
            try gop.value_ptr.ensureUnusedCapacity(self.allocator, 1);
            _ = try self.assets.acquire(key);
            errdefer self.assets.release(key);
            if (self.assets.entries.getPtr(key).?.state == .registered) return error.AssetDecodeNotQueued;
            // Secured: NOW retire the superseded same-name request (a
            // different key by construction — the exact pair returned above).
            // Non-pruning on purpose: `gop.value_ptr` must stay valid.
            removePendingBinding(self, entity, name, null);
            gop.value_ptr.appendAssumeCapacity(.{ .name = binding, .key = copy });
        }

        /// How a runtime material is retired — the split labelle-gfx encodes
        /// as `TextureInfo.gpu_resident` and `invalidateShaderMaterials`.
        pub const Retire = enum {
            /// The context is alive: free the backend resource.
            destroy,
            /// The context is GONE (surface loss): forget the id, never call
            /// the backend destructor — destroying on a stale context is UB,
            /// and after re-init the dead handle would free whatever the
            /// backend recycled into that slot.
            invalidate,
        };

        fn releaseRecord(self: *Game, world: *Game.World, record: sm.Record, retire: Retire) void {
            if (comptime supported) {
                if (retire == .destroy) retireId(self, world, record.id);
            }
            for (record.textures[0..record.len]) |binding| {
                if (binding.catalog) |key| {
                    self.assets.release(key);
                    self.allocator.free(key);
                }
                self.allocator.free(binding.name);
            }
        }

        // ── Deferred destruction (#883) ──────────────────────────────
        //
        // `tick` runs `renderer.sync` BEFORE `active_scene_update_fn`, so a
        // material replaced or cleared during that update has ALREADY been
        // cached for the `render()` that follows. Destroying the backend
        // material there and then made that render submit a dead id — one
        // frame drawn through the plain-sprite fallback, the kind of
        // visual glitch that reads as "the shader stuttered" and never
        // reproduces on demand (a fixed-time golden never catches it
        // either: goldens sample after a sync).
        //
        // The retire list is the conventional answer for a renderer with a
        // cached draw list, and it was chosen over "resync the entity
        // inline on change" for two reasons: it puts no sync work on the
        // update path (and needs no care with the world/renderer split),
        // and it covers the curated `setMaterial` path — which clears the
        // shader slot through `clearShaderMaterial` — for free.
        //
        // Lifetime is bounded to exactly ONE frame: `tick` flushes the
        // list immediately after the next `renderer.sync`, at which point
        // no cached draw can still reference the id. A world teardown
        // flushes what is left while the renderer is alive, so deferral
        // never turns into a leak.

        /// Queue `id` for destruction after the next `renderer.sync`.
        fn retireId(self: *Game, world: *Game.World, id: sm.contract.Id) void {
            if (comptime !supported) return;
            if (id == .none) return;
            world.shader_retire.append(self.allocator, id) catch {
                // Out of memory for a one-pointer append: destroy now.
                // A one-frame fallback flash beats leaking the material.
                world.renderer.destroyShaderMaterial(id);
            };
        }

        /// Destroy everything retired since the last flush. Called from
        /// `tick` right after `renderer.sync` — the point at which the
        /// renderer's cached draw list can no longer name any of these
        /// ids.
        pub fn flushRetiredShaderMaterials(self: *Game) void {
            if (comptime !supported) return;
            flushWorldRetired(self.active_world);
            var it = self.worlds.valueIterator();
            while (it.next()) |world| flushWorldRetired(world.*);
        }

        fn flushWorldRetired(world: *Game.World) void {
            if (comptime !supported) return;
            for (world.shader_retire.items) |id| {
                if (id != .none) world.renderer.destroyShaderMaterial(id);
            }
            world.shader_retire.clearRetainingCapacity();
        }

        /// Forget the queue WITHOUT destroying — for the whole-context
        /// retirements (`clearShaderMaterials` / `invalidateShaderMaterials`)
        /// that have already dropped every backend material. Destroying a
        /// queued id afterwards would be a double free (or a free on a
        /// dead context).
        fn dropWorldRetired(world: *Game.World) void {
            world.shader_retire.clearRetainingCapacity();
        }

        /// Requires a live sprite. Failure preserves the previous material and
        /// pins: NOTHING the entity already holds — the committed record or
        /// any pending request, mentioned by the new descriptor or not — is
        /// released until the replacement has been validated, resolved and
        /// created. On commit every pending request is swept (the committed
        /// pins own the textures from then on); `TextureNotReady` keeps the
        /// request it just made so the retry finds the asset still streaming.
        pub fn createShaderMaterial(self: *Game, entity: Entity, desc: sm.Descriptor) anyerror!void {
            if (comptime !supported) return error.Unsupported;
            if (!self.assets.gpu_alive) return error.GpuSurfaceUnavailable;
            if (!self.renderer.shaderMaterialSupported()) return error.Unsupported;
            if (!self.ecs_backend.entityExists(entity)) return error.InvalidEntity;
            const sprite = self.ecs_backend.getComponent(entity, Game.SpriteComp) orelse return error.MissingSprite;
            if (desc.textures.len > sm.contract.MAX_TEXTURES) return error.CapacityExceeded;
            var validation_bindings: [sm.contract.MAX_TEXTURES]sm.contract.TextureBinding = undefined;
            for (desc.textures, 0..) |binding, i| validation_bindings[i] = .{ .name = binding.name, .sampler = binding.sampler };
            try sm.contract.validateDescriptor(.{ .version = desc.version, .label = desc.label, .shaders = desc.shaders, .parameters = desc.parameters, .textures = validation_bindings[0..desc.textures.len], .blend = desc.blend });
            var record: sm.Record = .{ .id = .none };
            errdefer releaseRecord(self, self.active_world, record, .destroy);
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
            if (self.active_world.shader_materials.fetchRemove(entity)) |old| releaseRecord(self, self.active_world, old.value, .destroy);
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
            // The request this binding may already hold is left alone until the
            // replacement commits: `requestPending` supersedes it only once its
            // own request is secured, and the cancel below runs after the
            // backend accepted the texture. A hard failure therefore drops
            // nothing.
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
            releaseRecord(self, self.active_world, old.value, .destroy);
            if (comptime supported) if (self.ecs_backend.entityExists(entity)) if (self.ecs_backend.getComponent(entity, Game.SpriteComp)) |sprite| {
                if (sprite.material.shader == old.value.id) {
                    sprite.material.shader = .none;
                    self.renderer.markVisualDirty(entity);
                }
            };
        }

        /// World-local ownership prevents entity-id collisions across scene worlds.
        pub fn clearWorldShaderMaterials(self: *Game, world: *Game.World) void {
            _ = retireWorldShaderMaterials(self, world, .destroy);
        }

        /// Returns how many committed materials were retired.
        fn retireWorldShaderMaterials(self: *Game, world: *Game.World, retire: Retire) usize {
            while (world.shader_pending.count() != 0) {
                var pending = world.shader_pending.keyIterator();
                clearPending(self, world, pending.next().?.*);
            }
            const retired = world.shader_materials.count();
            var it = world.shader_materials.iterator();
            while (it.next()) |entry| {
                releaseRecord(self, world, entry.value_ptr.*, retire);
                if (comptime supported) if (world.ecs_backend.entityExists(entry.key_ptr.*)) if (world.ecs_backend.getComponent(entry.key_ptr.*, Game.SpriteComp)) |sprite| {
                    sprite.material.shader = .none;
                    world.renderer.markVisualDirty(entry.key_ptr.*);
                };
            }
            world.shader_materials.clearRetainingCapacity();
            switch (retire) {
                .destroy => if (comptime @hasDecl(Renderer, "clearShaderMaterials")) {
                    // Whole-context clear: every backend material is gone,
                    // including the ids this pass just retired (#883).
                    // Forget them rather than double-destroying.
                    world.renderer.clearShaderMaterials();
                    dropWorldRetired(world);
                },
                // The whole-context counterpart of `clearShaderMaterials`
                // (labelle-gfx#361): a material with NO texture bindings is
                // invisible to gfx's per-texture invalidation, so this is the
                // only way it is retired on surface loss. A renderer that
                // predates the seam only offers the destroying clear, which
                // gfx documents as "call before context teardown" — the best
                // that renderer can do, and no worse than before.
                .invalidate => {
                    if (comptime @hasDecl(Renderer, "invalidateShaderMaterials")) {
                        world.renderer.invalidateShaderMaterials();
                    } else if (comptime @hasDecl(Renderer, "clearShaderMaterials")) {
                        world.renderer.clearShaderMaterials();
                    }
                    // The context is gone (or every material was just
                    // dropped): a queued destroy would run the backend
                    // destructor on a stale handle. Forget instead.
                    dropWorldRetired(world);
                },
            }
            return retired;
        }

        pub fn clearAllShaderMaterials(self: *Game) void {
            clearWorldShaderMaterials(self, self.active_world);
            var it = self.worlds.valueIterator();
            while (it.next()) |world| clearWorldShaderMaterials(self, world.*);
        }

        /// Surface loss: forget every world's runtime materials WITHOUT a
        /// backend destroy, release their catalog pins, and put every bound
        /// sprite back on the plain draw path. The engine retains no
        /// descriptor (they are borrowed for the create call), so it cannot
        /// recreate; the game does, from its own definitions, after
        /// `surfaceRestored`. Returns the count for the caller's diagnostic.
        pub fn invalidateAllShaderMaterials(self: *Game) usize {
            var n = retireWorldShaderMaterials(self, self.active_world, .invalidate);
            var it = self.worlds.valueIterator();
            while (it.next()) |world| n += retireWorldShaderMaterials(self, world.*, .invalidate);
            return n;
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
