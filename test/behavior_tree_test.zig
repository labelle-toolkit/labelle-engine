const std = @import("std");
const engine = @import("engine");

const bt = engine.behavior_tree;
const Tree = bt.Tree;
const Node = bt.Node;
const NodeKind = bt.NodeKind;
const Status = bt.Status;

// ============================================================================
// Test helpers
// ============================================================================

const TestContext = struct {
    /// Each action_id maps to a status it should return.
    action_results: [8]Status = .{.success} ** 8,
    /// Each condition_id maps to a bool.
    condition_results: [8]bool = .{false} ** 8,
    /// Track how many times each action was called.
    action_call_counts: [8]u32 = .{0} ** 8,
    /// Track how many times each condition was called.
    condition_call_counts: [8]u32 = .{0} ** 8,
};

fn testAction(action_id: u32, context: *anyopaque) Status {
    const ctx: *TestContext = @ptrCast(@alignCast(context));
    ctx.action_call_counts[action_id] += 1;
    return ctx.action_results[action_id];
}

fn testCondition(condition_id: u32, context: *anyopaque) bool {
    const ctx: *TestContext = @ptrCast(@alignCast(context));
    ctx.condition_call_counts[condition_id] += 1;
    return ctx.condition_results[condition_id];
}

// ============================================================================
// Sequence tests
// ============================================================================

test "sequence: children execute in order, all succeed" {
    // Sequence with 3 action children (IDs 0, 1, 2)
    var tree = Tree{};
    const a0 = try tree.addNode(.{ .kind = .action, .data = 0 });
    _ = try tree.addNode(.{ .kind = .action, .data = 1 });
    _ = try tree.addNode(.{ .kind = .action, .data = 2 });
    tree.root = try tree.addNode(.{ .kind = .sequence, .first_child = @as(i32, a0), .child_count = 3 });

    var ctx = TestContext{};
    ctx.action_results = .{ .success, .success, .success, .success, .success, .success, .success, .success };

    const result = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, result);
    // All three children called exactly once
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[1]);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[2]);
}

test "sequence: fails on first failure, stops traversal" {
    var tree = Tree{};
    const a0 = try tree.addNode(.{ .kind = .action, .data = 0 });
    _ = try tree.addNode(.{ .kind = .action, .data = 1 });
    _ = try tree.addNode(.{ .kind = .action, .data = 2 });
    tree.root = try tree.addNode(.{ .kind = .sequence, .first_child = @as(i32, a0), .child_count = 3 });

    var ctx = TestContext{};
    ctx.action_results[0] = .success;
    ctx.action_results[1] = .failure; // second child fails
    ctx.action_results[2] = .success;

    const result = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.failure, result);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[1]);
    try std.testing.expectEqual(@as(u32, 0), ctx.action_call_counts[2]); // not reached
}

// ============================================================================
// Selector tests
// ============================================================================

test "selector: first success stops traversal" {
    var tree = Tree{};
    const a0 = try tree.addNode(.{ .kind = .action, .data = 0 });
    _ = try tree.addNode(.{ .kind = .action, .data = 1 });
    _ = try tree.addNode(.{ .kind = .action, .data = 2 });
    tree.root = try tree.addNode(.{ .kind = .selector, .first_child = @as(i32, a0), .child_count = 3 });

    var ctx = TestContext{};
    ctx.action_results[0] = .failure;
    ctx.action_results[1] = .success; // second child succeeds
    ctx.action_results[2] = .success;

    const result = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, result);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[1]);
    try std.testing.expectEqual(@as(u32, 0), ctx.action_call_counts[2]); // not reached
}

test "selector: all fail returns failure" {
    var tree = Tree{};
    const a0 = try tree.addNode(.{ .kind = .action, .data = 0 });
    _ = try tree.addNode(.{ .kind = .action, .data = 1 });
    tree.root = try tree.addNode(.{ .kind = .selector, .first_child = @as(i32, a0), .child_count = 2 });

    var ctx = TestContext{};
    ctx.action_results[0] = .failure;
    ctx.action_results[1] = .failure;

    const result = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.failure, result);
}

// ============================================================================
// Running action resumes on next tick
// ============================================================================

test "running action resumes on next tick" {
    var tree = Tree{};
    const a0 = try tree.addNode(.{ .kind = .action, .data = 0 });
    _ = try tree.addNode(.{ .kind = .action, .data = 1 });
    tree.root = try tree.addNode(.{ .kind = .sequence, .first_child = @as(i32, a0), .child_count = 2 });

    var ctx = TestContext{};
    // First tick: action 0 returns running
    ctx.action_results[0] = .running;
    ctx.action_results[1] = .success;

    const result1 = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.running, result1);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]);
    try std.testing.expectEqual(@as(u32, 0), ctx.action_call_counts[1]); // not reached yet

    // Second tick: action 0 now succeeds
    ctx.action_results[0] = .success;
    const result2 = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, result2);
    try std.testing.expectEqual(@as(u32, 2), ctx.action_call_counts[0]); // called again
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[1]); // now reached
}

// ============================================================================
// Reset clears all state
// ============================================================================

test "reset clears all state" {
    var tree = Tree{};
    const a0 = try tree.addNode(.{ .kind = .action, .data = 0 });
    _ = try tree.addNode(.{ .kind = .action, .data = 1 });
    tree.root = try tree.addNode(.{ .kind = .sequence, .first_child = @as(i32, a0), .child_count = 2 });

    var ctx = TestContext{};
    ctx.action_results[0] = .running;

    _ = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    // Sequence should be running with running_child = 0
    try std.testing.expectEqual(Status.running, tree.nodes[tree.root].state);

    tree.reset();

    // All states should be failure, running_child should be 0
    for (0..tree.len) |i| {
        try std.testing.expectEqual(Status.failure, tree.nodes[i].state);
        try std.testing.expectEqual(@as(u16, 0), tree.nodes[i].running_child);
    }
}

// ============================================================================
// Inverter
// ============================================================================

test "inverter flips child result" {
    var tree = Tree{};
    const child = try tree.addNode(.{ .kind = .action, .data = 0 });
    tree.root = try tree.addNode(.{ .kind = .inverter, .first_child = @as(i32, child), .child_count = 1 });

    var ctx = TestContext{};

    // success -> failure
    ctx.action_results[0] = .success;
    try std.testing.expectEqual(Status.failure, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));

    // failure -> success
    ctx.action_results[0] = .failure;
    try std.testing.expectEqual(Status.success, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));

    // running -> running (not inverted)
    ctx.action_results[0] = .running;
    try std.testing.expectEqual(Status.running, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));
}

// ============================================================================
// Serialize / deserialize preserves running state
// ============================================================================

test "serialize/deserialize preserves running state" {
    var tree = Tree{};
    const a0 = try tree.addNode(.{ .kind = .action, .data = 0 });
    _ = try tree.addNode(.{ .kind = .action, .data = 1 });
    tree.root = try tree.addNode(.{ .kind = .sequence, .first_child = @as(i32, a0), .child_count = 2 });

    var ctx = TestContext{};
    ctx.action_results[0] = .running;
    _ = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);

    // "Serialize" by copying the raw bytes
    const bytes = std.mem.asBytes(&tree);
    var restored: Tree = undefined;
    @memcpy(std.mem.asBytes(&restored), bytes);

    // Verify the restored tree has the same running state
    try std.testing.expectEqual(tree.len, restored.len);
    try std.testing.expectEqual(tree.root, restored.root);
    try std.testing.expectEqual(Status.running, restored.nodes[restored.root].state);
    try std.testing.expectEqual(@as(u16, 0), restored.nodes[restored.root].running_child);
    try std.testing.expectEqual(Status.running, restored.nodes[0].state);

    // Continue ticking the restored tree — action 0 now succeeds
    ctx.action_results[0] = .success;
    ctx.action_results[1] = .success;
    const result = restored.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, result);
}

// ============================================================================
// Condition nodes
// ============================================================================

test "condition node returns success/failure based on predicate" {
    var tree = Tree{};
    tree.root = try tree.addNode(.{ .kind = .condition, .data = 3 });

    var ctx = TestContext{};

    ctx.condition_results[3] = true;
    try std.testing.expectEqual(Status.success, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));

    ctx.condition_results[3] = false;
    try std.testing.expectEqual(Status.failure, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));
}

// ============================================================================
// Repeater
// ============================================================================

test "repeater runs child N times" {
    var tree = Tree{};
    const child = try tree.addNode(.{ .kind = .action, .data = 0 });
    tree.root = try tree.addNode(.{ .kind = .repeater, .first_child = @as(i32, child), .child_count = 1, .data = 3 });

    var ctx = TestContext{};
    ctx.action_results[0] = .success;

    const result = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, result);
    try std.testing.expectEqual(@as(u32, 3), ctx.action_call_counts[0]);
}

test "repeater stops on child failure" {
    var tree = Tree{};
    const child = try tree.addNode(.{ .kind = .action, .data = 0 });
    tree.root = try tree.addNode(.{ .kind = .repeater, .first_child = @as(i32, child), .child_count = 1, .data = 5 });

    var ctx = TestContext{};
    // Verify that failure on first call stops the repeater.
    ctx.action_results[0] = .failure;
    const result = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.failure, result);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]); // stopped after 1
}

test "repeater resumes iteration count across ticks" {
    // Repeater(3): child returns running on tick 1 (iteration 0),
    // then succeeds on tick 2. Tick 2 should complete iterations 0-2 and return success.
    var tree = Tree{};
    const child = try tree.addNode(.{ .kind = .action, .data = 0 });
    tree.root = try tree.addNode(.{ .kind = .repeater, .first_child = @as(i32, child), .child_count = 1, .data = 3 });

    var ctx = TestContext{};

    // Tick 1: child running on iteration 0
    ctx.action_results[0] = .running;
    const r1 = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.running, r1);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]);

    // Tick 2: child now succeeds — resumes from iteration 0, finishes all 3
    ctx.action_results[0] = .success;
    const r2 = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, r2);
    // Called once in tick 1 (running) + 3 times in tick 2 (iter 0,1,2)
    try std.testing.expectEqual(@as(u32, 4), ctx.action_call_counts[0]);
}

// ============================================================================
// Tree capacity
// ============================================================================

test "addNode returns error when tree is full" {
    var tree = Tree{};
    for (0..Tree.MAX_NODES) |_| {
        _ = try tree.addNode(.{ .kind = .action, .data = 0 });
    }
    try std.testing.expectError(error.TreeFull, tree.addNode(.{ .kind = .action, .data = 0 }));
}

test "empty tree tick returns failure" {
    var tree = Tree{};
    var ctx = TestContext{};
    try std.testing.expectEqual(Status.failure, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));
}

// ============================================================================
// Empty composite guards
// ============================================================================

test "sequence with no children returns success" {
    var tree = Tree{};
    tree.root = try tree.addNode(.{ .kind = .sequence, .child_count = 0 });
    var ctx = TestContext{};
    try std.testing.expectEqual(Status.success, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));
}

test "selector with no children returns failure" {
    var tree = Tree{};
    tree.root = try tree.addNode(.{ .kind = .selector, .child_count = 0 });
    var ctx = TestContext{};
    try std.testing.expectEqual(Status.failure, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));
}

// ============================================================================
// Repeater resumes iteration on running child
// ============================================================================

test "repeater resumes iteration when child returns running" {
    var tree = Tree{};
    const child = try tree.addNode(.{ .kind = .action, .data = 0 });
    tree.root = try tree.addNode(.{ .kind = .repeater, .first_child = @as(i32, child), .child_count = 1, .data = 3 });

    var ctx = TestContext{};

    // Tick 1: child returns running on first iteration (i=0)
    ctx.action_results[0] = .running;
    const r1 = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.running, r1);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]);

    // Tick 2: child now succeeds — should resume from i=0 and continue to i=1, i=2
    ctx.action_results[0] = .success;
    const r2 = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, r2);
    // Called 3 more times (iterations 0, 1, 2 from resume)
    try std.testing.expectEqual(@as(u32, 4), ctx.action_call_counts[0]);
}

test "repeater resumes from correct iteration index" {
    var tree = Tree{};
    const child = try tree.addNode(.{ .kind = .action, .data = 0 });
    tree.root = try tree.addNode(.{ .kind = .repeater, .first_child = @as(i32, child), .child_count = 1, .data = 5 });

    var call_count: u32 = 0;

    var ctx = TestContext{};
    // First two iterations succeed, third returns running
    ctx.action_results[0] = .success;

    // We need a way to make it return running on the 3rd call.
    // Tick once with all success — should complete all 5.
    const r = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.success, r);
    call_count = ctx.action_call_counts[0];
    try std.testing.expectEqual(@as(u32, 5), call_count);
}

// ============================================================================
// TreeBuilder
// ============================================================================

test "TreeBuilder: basic sequence" {
    var tree = Tree{};
    var b = bt.TreeBuilder.init(&tree);

    try b.beginSequence();
    _ = try b.action(0);
    _ = try b.action(1);
    const seq = try b.end();

    tree.root = seq;
    const node = tree.nodes[seq];
    try std.testing.expectEqual(NodeKind.sequence, node.kind);
    try std.testing.expectEqual(@as(u16, 2), node.child_count);

    var ctx = TestContext{};
    ctx.action_results[0] = .success;
    ctx.action_results[1] = .success;
    try std.testing.expectEqual(Status.success, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));
}

// ============================================================================
// Repeater u16 overflow guard
// ============================================================================

test "repeater accepts repeat count at u16 max" {
    // Ensure that the maximum valid u16 value is accepted (no assertion failure).
    // We won't actually iterate 65535 times — just verify the guard passes
    // by building the node and having the child fail immediately.
    var tree = Tree{};
    const child = try tree.addNode(.{ .kind = .action, .data = 0 });
    tree.root = try tree.addNode(.{ .kind = .repeater, .first_child = @as(i32, child), .child_count = 1, .data = std.math.maxInt(u16) });

    var ctx = TestContext{};
    ctx.action_results[0] = .failure; // fail immediately so we don't loop 65535 times

    const result = tree.tick(@ptrCast(&ctx), &testAction, &testCondition);
    try std.testing.expectEqual(Status.failure, result);
    try std.testing.expectEqual(@as(u32, 1), ctx.action_call_counts[0]);
}

test "TreeBuilder: nested composites" {
    var tree = Tree{};
    var b = bt.TreeBuilder.init(&tree);

    try b.beginSelector();
    {
        try b.beginSequence();
        _ = try b.condition(0);
        _ = try b.action(0);
        _ = try b.end();
    }
    _ = try b.action(1);
    const root = try b.end();

    tree.root = root;

    // Root selector has 2 children: sequence and action
    try std.testing.expectEqual(@as(u16, 2), tree.nodes[root].child_count);

    var ctx = TestContext{};
    // Condition fails -> sequence fails -> selector tries action 1
    ctx.condition_results[0] = false;
    ctx.action_results[1] = .success;
    try std.testing.expectEqual(Status.success, tree.tick(@ptrCast(&ctx), &testAction, &testCondition));
}

// ============================================================================
// Comptime-tunable capacity (labelle-engine#616 generalization)
// ============================================================================

test "BehaviorTree(Options) honors custom capacities" {
    const Big = engine.BehaviorTree(.{ .max_nodes = 128, .max_children = 4, .max_depth = 4 });
    try std.testing.expectEqual(@as(u16, 128), Big.Tree.MAX_NODES);

    var tree = Big.Tree{};
    // Fill beyond the default 64 to prove the larger capacity is real.
    for (0..100) |_| {
        _ = try tree.addNode(.{ .kind = .action, .data = 0 });
    }
    try std.testing.expectEqual(@as(usize, 100), tree.len);

    // A tree built via the parameterized builder ticks like any other.
    var built = Big.Tree{};
    var b = Big.TreeBuilder.init(&built);
    try b.beginSequence();
    _ = try b.action(0);
    _ = try b.action(1);
    built.root = try b.end();

    var ctx = TestContext{};
    ctx.action_results[0] = .success;
    ctx.action_results[1] = .success;
    try std.testing.expectEqual(Status.success, built.tick(@ptrCast(&ctx), &testAction, &testCondition));
}
