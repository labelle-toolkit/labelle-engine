// Dynamic Observer Tests
//
// Tests for the dynamic observer system that allows runtime registration
// of callbacks for component lifecycle events (add/remove).

const std = @import("std");
const ecs = @import("ecs");

// ============================================
// Test State
// ============================================

var add_called: bool = false;
var add_entity_id: u64 = 0;
var add_call_count: u32 = 0;

var remove_called: bool = false;
var remove_entity_id: u64 = 0;
var remove_call_count: u32 = 0;

const ObserverContext = struct {
    add_count: u32 = 0,
    remove_count: u32 = 0,
    last_entity_id: u64 = 0,
};

fn resetState() void {
    add_called = false;
    add_entity_id = 0;
    add_call_count = 0;
    remove_called = false;
    remove_entity_id = 0;
    remove_call_count = 0;
}

// ============================================
// Test Callbacks
// ============================================

fn onAddCallback(ctx: *anyopaque, entity_id: u64) void {
    _ = ctx;
    add_called = true;
    add_entity_id = entity_id;
    add_call_count += 1;
}

fn onRemoveCallback(ctx: *anyopaque, entity_id: u64) void {
    _ = ctx;
    remove_called = true;
    remove_entity_id = entity_id;
    remove_call_count += 1;
}

fn contextAddCallback(ctx: *anyopaque, entity_id: u64) void {
    const observer_ctx: *ObserverContext = @ptrCast(@alignCast(ctx));
    observer_ctx.add_count += 1;
    observer_ctx.last_entity_id = entity_id;
}

fn contextRemoveCallback(ctx: *anyopaque, entity_id: u64) void {
    const observer_ctx: *ObserverContext = @ptrCast(@alignCast(ctx));
    observer_ctx.remove_count += 1;
    observer_ctx.last_entity_id = entity_id;
}

// ============================================
// Test Components
// ============================================

const TestComponent = struct {
    value: i32 = 0,
};

const AnotherComponent = struct {
    data: f32 = 0.0,
};

// ============================================
// Tests
// ============================================

test "initObservers and deinitObservers don't crash" {
    ecs.initObservers(std.testing.allocator);
    ecs.deinitObservers();
}

test "observer is called when component is added" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var dummy_ctx: u8 = 0;
    try registry.observeAdd(TestComponent, &dummy_ctx, onAddCallback);

    const entity = registry.createEntity();
    registry.addComponent(entity, TestComponent{ .value = 42 });

    try std.testing.expect(add_called);
    try std.testing.expectEqual(@as(u32, 1), add_call_count);
}

test "observer is called for each entity" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var dummy_ctx: u8 = 0;
    try registry.observeAdd(TestComponent, &dummy_ctx, onAddCallback);

    _ = registry.createEntity();
    const e1 = registry.createEntity();
    const e2 = registry.createEntity();
    const e3 = registry.createEntity();

    registry.addComponent(e1, TestComponent{});
    registry.addComponent(e2, TestComponent{});
    registry.addComponent(e3, TestComponent{});

    try std.testing.expectEqual(@as(u32, 3), add_call_count);
}

test "remove observer is called when component is removed" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var dummy_ctx: u8 = 0;
    try registry.observeRemove(TestComponent, &dummy_ctx, onRemoveCallback);

    const entity = registry.createEntity();
    registry.addComponent(entity, TestComponent{ .value = 10 });

    try std.testing.expect(!remove_called);

    registry.removeComponent(entity, TestComponent);

    try std.testing.expect(remove_called);
    try std.testing.expectEqual(@as(u32, 1), remove_call_count);
}

test "remove observer is called when entity is destroyed" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var dummy_ctx: u8 = 0;
    try registry.observeRemove(TestComponent, &dummy_ctx, onRemoveCallback);

    const entity = registry.createEntity();
    registry.addComponent(entity, TestComponent{});

    registry.destroyEntity(entity);

    try std.testing.expect(remove_called);
}

test "observer receives context pointer correctly" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var ctx = ObserverContext{};
    try registry.observeAdd(TestComponent, &ctx, contextAddCallback);

    const entity = registry.createEntity();
    registry.addComponent(entity, TestComponent{ .value = 99 });

    try std.testing.expectEqual(@as(u32, 1), ctx.add_count);
}

test "multiple observers can be registered for same component" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var ctx1 = ObserverContext{};
    var ctx2 = ObserverContext{};

    try registry.observeAdd(TestComponent, &ctx1, contextAddCallback);
    try registry.observeAdd(TestComponent, &ctx2, contextAddCallback);

    const entity = registry.createEntity();
    registry.addComponent(entity, TestComponent{});

    // Both observers should be called
    try std.testing.expectEqual(@as(u32, 1), ctx1.add_count);
    try std.testing.expectEqual(@as(u32, 1), ctx2.add_count);
}

test "unobserveAdd removes observer" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var ctx = ObserverContext{};
    try registry.observeAdd(TestComponent, &ctx, contextAddCallback);

    // Verify observer works
    const entity1 = registry.createEntity();
    registry.addComponent(entity1, TestComponent{});
    try std.testing.expectEqual(@as(u32, 1), ctx.add_count);

    // Unregister
    registry.unobserveAdd(TestComponent, &ctx);

    // Verify observer no longer called
    const entity2 = registry.createEntity();
    registry.addComponent(entity2, TestComponent{});
    try std.testing.expectEqual(@as(u32, 1), ctx.add_count); // Still 1, not 2
}

test "unobserveRemove removes observer" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);

    var ctx = ObserverContext{};
    try registry.observeRemove(TestComponent, &ctx, contextRemoveCallback);

    // Verify observer works
    const entity1 = registry.createEntity();
    registry.addComponent(entity1, TestComponent{});
    registry.removeComponent(entity1, TestComponent);
    try std.testing.expectEqual(@as(u32, 1), ctx.remove_count);

    // Unregister
    registry.unobserveRemove(TestComponent, &ctx);

    // Verify observer no longer called
    const entity2 = registry.createEntity();
    registry.addComponent(entity2, TestComponent{});
    registry.removeComponent(entity2, TestComponent);
    try std.testing.expectEqual(@as(u32, 1), ctx.remove_count); // Still 1, not 2
}

test "different component types have independent observers" {
    resetState();

    ecs.initObservers(std.testing.allocator);
    defer ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    ecs.registerComponentCallbacks(&registry, TestComponent);
    ecs.registerComponentCallbacks(&registry, AnotherComponent);

    var ctx1 = ObserverContext{};
    var ctx2 = ObserverContext{};

    try registry.observeAdd(TestComponent, &ctx1, contextAddCallback);
    try registry.observeAdd(AnotherComponent, &ctx2, contextAddCallback);

    const entity = registry.createEntity();
    registry.addComponent(entity, TestComponent{});

    // Only TestComponent observer should be called
    try std.testing.expectEqual(@as(u32, 1), ctx1.add_count);
    try std.testing.expectEqual(@as(u32, 0), ctx2.add_count);

    registry.addComponent(entity, AnotherComponent{});

    // Now both should have been called once
    try std.testing.expectEqual(@as(u32, 1), ctx1.add_count);
    try std.testing.expectEqual(@as(u32, 1), ctx2.add_count);
}

test "observeAdd returns error if observers not initialized" {
    resetState();

    // Ensure observers are NOT initialized
    ecs.deinitObservers();

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy_ctx: u8 = 0;
    const result = registry.observeAdd(TestComponent, &dummy_ctx, onAddCallback);

    try std.testing.expect(result == error.ObserversNotInitialized);
}

test "ObserverCallback type is exported" {
    // Verify the type is accessible
    const cb: ecs.ObserverCallback = onAddCallback;
    _ = cb;
}

// ============================================
// Iteration Safety Tests
// ============================================

var entities_processed: u32 = 0;
var destroy_registry_ptr: ?*ecs.Registry = null;
var entity_to_destroy: ?ecs.Entity = null;

fn destroyDuringIterationCallback(entity: ecs.Entity, _: *TestComponent) void {
    entities_processed += 1;

    // On first entity, destroy another entity
    if (entities_processed == 1) {
        if (destroy_registry_ptr) |reg| {
            if (entity_to_destroy) |to_destroy| {
                if (!std.meta.eql(entity, to_destroy)) {
                    reg.destroyEntity(to_destroy);
                }
            }
        }
    }
}

test "WARNING: destroying entity during query iteration is unsafe" {
    // This test documents the UNSAFE behavior of destroying entities during iteration.
    // Both zig_ecs and zflecs can exhibit undefined behavior when structural changes
    // happen during iteration.
    //
    // SAFE PATTERNS:
    // 1. Collect entities to destroy in a list, destroy after iteration
    // 2. Use a "marked for destruction" component, process separately
    // 3. In zflecs: use systems (which defer structural changes)
    //
    // UNSAFE (what this test demonstrates):
    // - Calling registry.destroy() inside query.each() callback

    entities_processed = 0;

    var registry = ecs.Registry.init(std.testing.allocator);
    defer registry.deinit();

    destroy_registry_ptr = &registry;

    // Create 5 entities with TestComponent
    var entities: [5]ecs.Entity = undefined;
    for (&entities) |*e| {
        e.* = registry.createEntity();
        registry.addComponent(e.*, TestComponent{ .value = 1 });
    }

    // We'll try to destroy entity[3] while iterating
    entity_to_destroy = entities[3];

    // This iteration is UNSAFE - behavior is undefined
    // We can't reliably test the outcome because it depends on:
    // - Internal storage order (sparse sets use swap-and-pop)
    // - Which entity we're on when we destroy
    // - Backend implementation details

    // The test passes if it doesn't crash, but the behavior is undefined.
    // DO NOT rely on any specific outcome from this pattern.
    var query = registry.query(.{TestComponent});
    query.each(destroyDuringIterationCallback);

    // We can only verify it didn't crash - actual entity count is undefined
    // Could be 4 (skipped one) or 5 (processed already-destroyed) or crash
    try std.testing.expect(entities_processed >= 1); // At least one was processed

    // Clean up
    destroy_registry_ptr = null;
    entity_to_destroy = null;
}
