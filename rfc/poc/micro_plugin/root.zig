const std = @import("std");
const core = @import("core");

/// Micro Inventory Plugin — demonstrates the full plugin pattern using core.
///
/// Split hook ownership (Option C):
/// - Plugin owns out-dispatcher (emits notifications to the game)
/// - Game owns in-dispatcher (sends commands to the plugin)
/// - BoundReceiver bridges both: handles in-events AND emits out-events
/// - No self-reference, no fixPointers, no circular dependencies
///
/// Depends ONLY on core. Never imports engine.
pub fn InventoryPlugin(comptime EcsType: type, comptime Item: type) type {
    const Ctx = core.PluginContext(.{ .EcsType = EcsType });
    const Entity = Ctx.Entity;

    return struct {
        ecs: EcsType,
        allocator: std.mem.Allocator,
        // Track total items across all inventories
        total_items: u32 = 0,

        const Self = @This();

        // ================================================================
        // Domain types — plugin-specific, not in core
        // ================================================================

        pub const Slot = struct {
            item: Item,
            quantity: u32,
        };

        /// ECS component — attached to entities that have an inventory.
        pub const Inventory = struct {
            slots: [max_slots]Slot = undefined,
            len: u32 = 0,
            capacity: u32,

            const max_slots = 16;

            pub fn init(capacity: u32) Inventory {
                return .{ .capacity = @min(capacity, max_slots) };
            }

            pub fn itemCount(self: *const Inventory) u32 {
                var count: u32 = 0;
                for (self.slots[0..self.len]) |slot| {
                    count += slot.quantity;
                }
                return count;
            }

            pub fn hasItem(self: *const Inventory, item: Item) bool {
                for (self.slots[0..self.len]) |slot| {
                    if (slot.item == item) return true;
                }
                return false;
            }

            pub fn getQuantity(self: *const Inventory, item: Item) u32 {
                for (self.slots[0..self.len]) |slot| {
                    if (slot.item == item) return slot.quantity;
                }
                return 0;
            }
        };

        // ================================================================
        // Hook payloads — plugin-specific, built on core patterns
        // ================================================================

        /// Events the game sends to this plugin (in: game -> plugin)
        pub const InPayload = union(enum) {
            add_item: struct { entity_id: Entity, item: Item, quantity: u32 },
            remove_item: struct { entity_id: Entity, item: Item, quantity: u32 },
            clear_inventory: struct { entity_id: Entity },
        };

        /// Events this plugin emits to the game (out: plugin -> game)
        pub const OutPayload = union(enum) {
            item_added: struct { entity_id: Entity, item: Item, quantity: u32, new_total: u32 },
            item_removed: struct { entity_id: Entity, item: Item, quantity: u32, new_total: u32 },
            inventory_full: struct { entity_id: Entity, item: Item },
            inventory_cleared: struct { entity_id: Entity, items_removed: u32 },
        };

        // ================================================================
        // Plugin receiver — simple, no notifications (for basic tests)
        // ================================================================

        pub const PluginReceiver = struct {
            plugin: *Self,

            pub fn add_item(self: @This(), p: anytype) void {
                _ = self.plugin.addItem(p.entity_id, p.item, p.quantity);
            }

            pub fn remove_item(self: @This(), p: anytype) void {
                _ = self.plugin.removeItem(p.entity_id, p.item, p.quantity);
            }

            pub fn clear_inventory(self: @This(), p: anytype) void {
                _ = self.plugin.clearInventory(p.entity_id);
            }
        };

        // ================================================================
        // Bound receiver — handles in-events AND emits out-events
        // Split ownership: plugin owns out, game owns in
        // ================================================================

        pub fn BoundReceiver(comptime GameReceiver: type) type {
            const OutDispatcher = core.HookDispatcher(OutPayload, GameReceiver, .{});

            return struct {
                plugin: *Self,
                out: OutDispatcher,

                pub fn add_item(self: @This(), p: anytype) void {
                    const result = self.plugin.addItem(p.entity_id, p.item, p.quantity);
                    if (result) |added| {
                        if (added) {
                            const inv = self.plugin.getInventory(p.entity_id).?;
                            self.out.emit(.{ .item_added = .{
                                .entity_id = p.entity_id,
                                .item = p.item,
                                .quantity = p.quantity,
                                .new_total = inv.itemCount(),
                            } });
                        } else {
                            self.out.emit(.{ .inventory_full = .{
                                .entity_id = p.entity_id,
                                .item = p.item,
                            } });
                        }
                    }
                }

                pub fn remove_item(self: @This(), p: anytype) void {
                    const removed = self.plugin.removeItem(p.entity_id, p.item, p.quantity);
                    if (removed) |qty| {
                        if (qty > 0) {
                            const inv = self.plugin.getInventory(p.entity_id).?;
                            self.out.emit(.{ .item_removed = .{
                                .entity_id = p.entity_id,
                                .item = p.item,
                                .quantity = qty,
                                .new_total = inv.itemCount(),
                            } });
                        }
                    }
                }

                pub fn clear_inventory(self: @This(), p: anytype) void {
                    const count = self.plugin.clearInventory(p.entity_id);
                    if (count) |items_removed| {
                        self.out.emit(.{ .inventory_cleared = .{
                            .entity_id = p.entity_id,
                            .items_removed = items_removed,
                        } });
                    }
                }
            };
        }

        // ================================================================
        // Hook type generators — split ownership
        // ================================================================

        /// In-dispatcher: game -> BoundReceiver -> plugin + out-emit
        pub fn InHooks(comptime GameReceiver: type) type {
            return core.HookDispatcher(InPayload, BoundReceiver(GameReceiver), .{});
        }

        /// Out-dispatcher: plugin -> GameReceiver (for direct use)
        pub fn OutHooks(comptime GameReceiver: type) type {
            return core.HookDispatcher(OutPayload, GameReceiver, .{});
        }

        // ================================================================
        // Engine lifecycle receiver — responds to engine hooks
        // ================================================================

        pub const LifecycleReceiver = struct {
            plugin: *Self,

            pub fn entity_destroyed(self: @This(), info: core.EntityInfo(Entity)) void {
                // Auto-cleanup: remove inventory component when entity is destroyed
                if (self.plugin.ecs.has(info.entity_id, Inventory)) {
                    self.plugin.ecs.remove(info.entity_id, Inventory);
                }
            }
        };

        // ================================================================
        // API
        // ================================================================

        pub fn init(allocator: std.mem.Allocator, ecs: EcsType) Self {
            return .{
                .ecs = ecs,
                .allocator = allocator,
            };
        }

        pub fn pluginReceiver(self: *Self) PluginReceiver {
            return .{ .plugin = self };
        }

        pub fn lifecycleReceiver(self: *Self) LifecycleReceiver {
            return .{ .plugin = self };
        }

        /// Register an entity with an inventory via ECS.
        pub fn registerEntity(self: Self, entity: Entity, capacity: u32) void {
            self.ecs.add(entity, Inventory.init(capacity));
        }

        /// Check if an entity has an inventory.
        pub fn hasInventory(self: Self, entity: Entity) bool {
            return self.ecs.has(entity, Inventory);
        }

        /// Get an entity's inventory.
        pub fn getInventory(self: Self, entity: Entity) ?*Inventory {
            return self.ecs.get(entity, Inventory);
        }

        // ================================================================
        // Internal logic — returns results for BoundReceiver to emit
        // ================================================================

        /// Add item. Returns null if no inventory, true if added/stacked, false if full.
        fn addItem(self: *Self, entity_id: Entity, item: Item, quantity: u32) ?bool {
            const inv = self.ecs.get(entity_id, Inventory) orelse return null;

            // Check if item already exists in a slot
            for (inv.slots[0..inv.len]) |*slot| {
                if (slot.item == item) {
                    slot.quantity += quantity;
                    self.total_items += quantity;
                    return true;
                }
            }

            // Try to add a new slot
            if (inv.len >= inv.capacity) {
                return false;
            }

            inv.slots[inv.len] = .{ .item = item, .quantity = quantity };
            inv.len += 1;
            self.total_items += quantity;
            return true;
        }

        /// Remove item. Returns null if no inventory, otherwise quantity actually removed.
        fn removeItem(self: *Self, entity_id: Entity, item: Item, quantity: u32) ?u32 {
            const inv = self.ecs.get(entity_id, Inventory) orelse return null;

            for (inv.slots[0..inv.len]) |*slot| {
                if (slot.item == item) {
                    const removed = @min(slot.quantity, quantity);
                    slot.quantity -= removed;
                    self.total_items -= removed;
                    return removed;
                }
            }
            return 0;
        }

        /// Clear inventory. Returns null if no inventory, otherwise total items removed.
        fn clearInventory(self: *Self, entity_id: Entity) ?u32 {
            const inv = self.ecs.get(entity_id, Inventory) orelse return null;
            const count = inv.itemCount();
            self.total_items -= count;
            inv.len = 0;
            return count;
        }
    };
}
