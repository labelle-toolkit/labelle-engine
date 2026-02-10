const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const ecs = @import("ecs");
const ComponentPayload = engine.ComponentPayload;

// Test state for tracking callback invocations
var test_on_add_called: bool = false;
var test_on_add_entity_id: u64 = 0;
var test_on_add_call_count: u32 = 0;

var test_on_set_called: bool = false;
var test_on_set_entity_id: u64 = 0;
var test_on_set_call_count: u32 = 0;

var test_on_remove_called: bool = false;
var test_on_remove_entity_id: u64 = 0;
var test_on_remove_call_count: u32 = 0;

/// Dummy game instance for testing callbacks
var test_game_instance: u8 = 0;

fn resetTestState() void {
    test_on_add_called = false;
    test_on_add_entity_id = 0;
    test_on_add_call_count = 0;
    test_on_set_called = false;
    test_on_set_entity_id = 0;
    test_on_set_call_count = 0;
    test_on_remove_called = false;
    test_on_remove_entity_id = 0;
    test_on_remove_call_count = 0;

    // Set up the game pointer for component callbacks
    ecs.setGamePtr(&test_game_instance);
}

// Test component with onAdd callback
const TestHealth = struct {
    amount: i32 = 100,
    max: i32 = 100,

    pub fn onAdd(payload: ComponentPayload) void {
        test_on_add_called = true;
        test_on_add_entity_id = payload.entity_id;
        test_on_add_call_count += 1;
    }
};

// Test component with onSet callback
const TestMana = struct {
    current: i32 = 50,
    max: i32 = 100,

    pub fn onSet(payload: ComponentPayload) void {
        test_on_set_called = true;
        test_on_set_entity_id = payload.entity_id;
        test_on_set_call_count += 1;
    }
};

// Test component with onRemove callback
const TestBuff = struct {
    duration: f32 = 10.0,
    strength: i32 = 5,

    pub fn onRemove(payload: ComponentPayload) void {
        test_on_remove_called = true;
        test_on_remove_entity_id = payload.entity_id;
        test_on_remove_call_count += 1;
    }
};

// Test component with all three callbacks
const TestFullLifecycle = struct {
    value: i32 = 0,

    pub fn onAdd(payload: ComponentPayload) void {
        test_on_add_called = true;
        test_on_add_entity_id = payload.entity_id;
        test_on_add_call_count += 1;
    }

    pub fn onSet(payload: ComponentPayload) void {
        test_on_set_called = true;
        test_on_set_entity_id = payload.entity_id;
        test_on_set_call_count += 1;
    }

    pub fn onRemove(payload: ComponentPayload) void {
        test_on_remove_called = true;
        test_on_remove_entity_id = payload.entity_id;
        test_on_remove_call_count += 1;
    }
};

// Test component without callbacks - should work normally
const PlainComponent = struct {
    value: i32 = 0,
};

// Another component with callback for testing multiple components
var secondary_callback_called: bool = false;

const SecondaryComponent = struct {
    data: f32 = 0.0,

    pub fn onAdd(payload: ComponentPayload) void {
        secondary_callback_called = true;
        _ = payload;
    }
};

test {
    zspec.runAll(@This());
}

/// Dummy game pointer for testing ComponentPayload
var dummy_game: u8 = 0;

pub const COMPONENT_PAYLOAD = struct {
    pub const CREATION = struct {
        test "can create ComponentPayload with entity_id and game_ptr" {
            const payload = ComponentPayload{ .entity_id = 42, .game_ptr = &dummy_game };
            try expect.equal(payload.entity_id, 42);
        }

        test "entity_id can hold large values" {
            const payload = ComponentPayload{ .entity_id = 0xFFFFFFFFFFFFFFFF, .game_ptr = &dummy_game };
            try expect.equal(payload.entity_id, 0xFFFFFFFFFFFFFFFF);
        }

        test "getGame returns the game pointer" {
            const payload = ComponentPayload{ .entity_id = 42, .game_ptr = &dummy_game };
            const game = payload.getGame(u8);
            try expect.equal(game, &dummy_game);
        }
    };
};

pub const ON_ADD_CALLBACK = struct {
    pub const BASIC = struct {
        test "onAdd is called when component with callback is added" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            // Register callbacks for the component type
            ecs.registerComponentCallbacks(&registry, TestHealth);

            const entity = registry.create();
            registry.add(entity, TestHealth{ .amount = 50 });

            try expect.toBeTrue(test_on_add_called);
        }

        test "onAdd receives correct entity id" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestHealth);

            const entity = registry.create();
            registry.add(entity, TestHealth{});

            // Convert entity to u64 for comparison
            const expected_id = engine.entityToU64(entity);
            try expect.equal(test_on_add_entity_id, expected_id);
        }

        test "onAdd is called for each entity" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestHealth);

            const entity1 = registry.create();
            const entity2 = registry.create();
            const entity3 = registry.create();

            registry.add(entity1, TestHealth{});
            registry.add(entity2, TestHealth{});
            registry.add(entity3, TestHealth{});

            try expect.equal(test_on_add_call_count, 3);
        }
    };

    pub const MULTIPLE_COMPONENTS = struct {
        test "different components have independent callbacks" {
            resetTestState();
            secondary_callback_called = false;

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestHealth);
            ecs.registerComponentCallbacks(&registry, SecondaryComponent);

            const entity = registry.create();

            // Add only TestHealth
            registry.add(entity, TestHealth{});
            try expect.toBeTrue(test_on_add_called);
            try expect.toBeFalse(secondary_callback_called);

            // Add SecondaryComponent
            registry.add(entity, SecondaryComponent{});
            try expect.toBeTrue(secondary_callback_called);
        }
    };
};

pub const ON_SET_CALLBACK = struct {
    pub const BASIC = struct {
        test "onSet is called when setComponent is used" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestMana);

            const entity = registry.create();
            registry.add(entity, TestMana{ .current = 50 });

            // Reset to track only the set operation
            test_on_set_called = false;
            test_on_set_call_count = 0;

            // Use setComponent to update - this should trigger onSet
            registry.setComponent(entity, TestMana{ .current = 75, .max = 100 });

            try expect.toBeTrue(test_on_set_called);
            try expect.equal(test_on_set_call_count, 1);
        }

        test "onSet receives correct entity id" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestMana);

            const entity = registry.create();
            registry.add(entity, TestMana{ .current = 50 });

            // Reset state after add
            test_on_set_called = false;
            test_on_set_entity_id = 0;

            // Use setComponent to update
            registry.setComponent(entity, TestMana{ .current = 100, .max = 100 });

            try expect.toBeTrue(test_on_set_called);
            const expected_id = engine.entityToU64(entity);
            try expect.equal(test_on_set_entity_id, expected_id);
        }

        test "onSet is called for each setComponent call" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestMana);

            const entity = registry.create();
            registry.add(entity, TestMana{ .current = 50 });

            // Reset after initial add
            test_on_set_call_count = 0;

            // Multiple setComponent calls
            registry.setComponent(entity, TestMana{ .current = 60, .max = 100 });
            registry.setComponent(entity, TestMana{ .current = 70, .max = 100 });
            registry.setComponent(entity, TestMana{ .current = 80, .max = 100 });

            try expect.equal(test_on_set_call_count, 3);
        }

        test "direct mutation via tryGet does NOT trigger onSet" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestMana);

            const entity = registry.create();
            registry.add(entity, TestMana{ .current = 50 });

            // Reset after add
            test_on_set_called = false;
            test_on_set_call_count = 0;

            // Direct mutation via pointer - should NOT trigger onSet
            if (registry.tryGet(TestMana, entity)) |mana| {
                mana.current = 100;
            }

            // Verify onSet was NOT called (this is the expected behavior)
            try expect.toBeFalse(test_on_set_called);
        }
    };

    pub const SET_COMPONENT_ADD = struct {
        test "setComponent on entity without component triggers onAdd, not onSet" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestFullLifecycle);

            const entity = registry.create();
            // Entity has no TestFullLifecycle component yet

            // setComponent should add it and trigger onAdd
            registry.setComponent(entity, TestFullLifecycle{ .value = 50 });

            // Verify onAdd was called, and onSet was NOT
            try expect.toBeTrue(test_on_add_called);
            try expect.equal(test_on_add_call_count, 1);
            try expect.toBeFalse(test_on_set_called);

            // Verify component was added correctly
            const comp = registry.tryGet(TestFullLifecycle, entity);
            try std.testing.expect(comp != null);
            try expect.equal(comp.?.value, 50);
        }
    };

    pub const ON_SET_NOT_FIRED_ON_INITIAL_ADD = struct {
        test "onSet does NOT fire on initial add via registry.add" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestFullLifecycle);

            const entity = registry.create();

            // Initial add - should trigger onAdd but NOT onSet
            registry.add(entity, TestFullLifecycle{ .value = 42 });

            try expect.toBeTrue(test_on_add_called);
            try expect.equal(test_on_add_call_count, 1);
            try expect.toBeFalse(test_on_set_called);
            try expect.equal(test_on_set_call_count, 0);
        }

        test "onSet does NOT fire on initial add via setComponent" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestFullLifecycle);

            const entity = registry.create();
            // Entity has no component yet

            // setComponent on new entity - should trigger onAdd but NOT onSet
            registry.setComponent(entity, TestFullLifecycle{ .value = 42 });

            try expect.toBeTrue(test_on_add_called);
            try expect.equal(test_on_add_call_count, 1);
            try expect.toBeFalse(test_on_set_called);
            try expect.equal(test_on_set_call_count, 0);

            // Now update the component - THIS should trigger onSet
            registry.setComponent(entity, TestFullLifecycle{ .value = 100 });

            try expect.toBeTrue(test_on_set_called);
            try expect.equal(test_on_set_call_count, 1);
            // onAdd should still be 1 (not fired again)
            try expect.equal(test_on_add_call_count, 1);
        }
    };
};

pub const ON_REMOVE_CALLBACK = struct {
    pub const BASIC = struct {
        test "onRemove is called when component is removed" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestBuff);

            const entity = registry.create();
            registry.add(entity, TestBuff{ .duration = 5.0 });

            try expect.toBeFalse(test_on_remove_called);

            // Remove the component
            registry.remove(TestBuff, entity);

            try expect.toBeTrue(test_on_remove_called);
        }

        test "onRemove receives correct entity id" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestBuff);

            const entity = registry.create();
            registry.add(entity, TestBuff{});

            registry.remove(TestBuff, entity);

            const expected_id = engine.entityToU64(entity);
            try expect.equal(test_on_remove_entity_id, expected_id);
        }

        test "onRemove is called for each entity" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestBuff);

            const entity1 = registry.create();
            const entity2 = registry.create();

            registry.add(entity1, TestBuff{});
            registry.add(entity2, TestBuff{});

            registry.remove(TestBuff, entity1);
            registry.remove(TestBuff, entity2);

            try expect.equal(test_on_remove_call_count, 2);
        }
    };

    pub const ENTITY_DESTROY = struct {
        test "onRemove is called when entity is destroyed" {
            resetTestState();

            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            ecs.registerComponentCallbacks(&registry, TestBuff);

            const entity = registry.create();
            registry.add(entity, TestBuff{});

            try expect.toBeFalse(test_on_remove_called);

            // Destroying entity should trigger onRemove for all components
            registry.destroy(entity);

            try expect.toBeTrue(test_on_remove_called);
        }

        test "isValid returns false after entity is destroyed" {
            var registry = ecs.Registry.init(std.testing.allocator);
            defer registry.deinit();

            const entity = registry.create();
            try expect.toBeTrue(registry.isValid(entity));

            registry.destroy(entity);
            try expect.toBeFalse(registry.isValid(entity));
        }
    };
};

pub const FULL_LIFECYCLE = struct {
    test "all callbacks fire in correct order for full lifecycle" {
        resetTestState();

        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        ecs.registerComponentCallbacks(&registry, TestFullLifecycle);

        const entity = registry.create();

        // 1. Add triggers onAdd
        registry.add(entity, TestFullLifecycle{ .value = 1 });
        try expect.toBeTrue(test_on_add_called);
        try expect.equal(test_on_add_call_count, 1);
        try expect.toBeFalse(test_on_set_called);
        try expect.toBeFalse(test_on_remove_called);

        // 2. Set triggers onSet
        registry.setComponent(entity, TestFullLifecycle{ .value = 2 });
        try expect.toBeTrue(test_on_set_called);
        try expect.equal(test_on_set_call_count, 1);
        try expect.equal(test_on_add_call_count, 1); // onAdd not called again

        // 3. Remove triggers onRemove
        registry.remove(TestFullLifecycle, entity);
        try expect.toBeTrue(test_on_remove_called);
        try expect.equal(test_on_remove_call_count, 1);
    }

    test "component with all callbacks can be registered" {
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        // Should not crash when registering component with all three callbacks
        ecs.registerComponentCallbacks(&registry, TestFullLifecycle);

        const entity = registry.create();
        registry.add(entity, TestFullLifecycle{ .value = 42 });

        const comp = registry.tryGet(TestFullLifecycle, entity);
        try std.testing.expect(comp != null);
        try expect.equal(comp.?.value, 42);
    }
};

pub const COMPONENTS_WITHOUT_CALLBACKS = struct {
    test "components without onAdd work normally" {
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        const entity = registry.create();
        registry.add(entity, PlainComponent{ .value = 42 });

        const comp = registry.tryGet(PlainComponent, entity);
        try std.testing.expect(comp != null);
        try expect.equal(comp.?.value, 42);
    }

    test "registering callbacks for component without onAdd is a no-op" {
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        // This should not crash or error
        ecs.registerComponentCallbacks(&registry, PlainComponent);

        const entity = registry.create();
        registry.add(entity, PlainComponent{ .value = 100 });

        const comp = registry.tryGet(PlainComponent, entity);
        try std.testing.expect(comp != null);
        try expect.equal(comp.?.value, 100);
    }
};

pub const MODULE_EXPORTS = struct {
    test "ComponentPayload is exported from engine" {
        const payload: engine.ComponentPayload = .{ .entity_id = 1, .game_ptr = &dummy_game };
        _ = payload;
    }

    test "registerComponentCallbacks is available via ecs interface" {
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        // Should compile and not crash
        ecs.registerComponentCallbacks(&registry, TestHealth);
    }
};

// View tests only apply to zig_ecs backend (zflecs uses different iteration API)
pub const VIEW_WITH_CALLBACKS = struct {
    // Check if we're using zig_ecs backend (which has view() method)
    const has_view = @hasDecl(ecs.Registry, "view");

    test "single-component view works with components that have callbacks" {
        if (!has_view) return; // Skip for zflecs backend

        resetTestState();

        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        ecs.registerComponentCallbacks(&registry, TestHealth);

        // Create entities with the component
        const entity1 = registry.create();
        const entity2 = registry.create();
        registry.add(entity1, TestHealth{ .amount = 100 });
        registry.add(entity2, TestHealth{ .amount = 50 });

        // Query using single-component view - this was causing the type mismatch
        var view = registry.view(.{TestHealth});
        var count: u32 = 0;
        var found_100: bool = false;
        var found_50: bool = false;
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const health = registry.tryGet(TestHealth, entity);
            try std.testing.expect(health != null);
            // Verify we can access the actual component values
            if (health.?.amount == 100) found_100 = true;
            if (health.?.amount == 50) found_50 = true;
            count += 1;
        }

        try expect.equal(count, 2);
        try expect.toBeTrue(found_100);
        try expect.toBeTrue(found_50);
    }

    test "multi-component view works with components that have callbacks" {
        if (!has_view) return; // Skip for zflecs backend

        resetTestState();

        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        ecs.registerComponentCallbacks(&registry, TestHealth);
        ecs.registerComponentCallbacks(&registry, TestMana);

        // Create entity with both components
        const entity = registry.create();
        registry.add(entity, TestHealth{ .amount = 100 });
        registry.add(entity, TestMana{ .current = 50 });

        // Query using multi-component view
        var view = registry.view(.{ TestHealth, TestMana });
        var count: u32 = 0;
        var iter = view.entityIterator();
        while (iter.next()) |e| {
            // Verify we can access both component values correctly
            const health = registry.tryGet(TestHealth, e);
            const mana = registry.tryGet(TestMana, e);
            try std.testing.expect(health != null);
            try std.testing.expect(mana != null);
            try expect.equal(health.?.amount, 100);
            try expect.equal(mana.?.current, 50);
            count += 1;
        }

        try expect.equal(count, 1);
    }
};
