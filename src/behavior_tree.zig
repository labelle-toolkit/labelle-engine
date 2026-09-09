// Behavior Tree — a game-agnostic AI facility for labelle-engine.
//
// A flat-array (not pointer-based) behavior-tree interpreter. Because the
// whole tree — topology *and* runtime state — lives in a single fixed-size
// array, a `Tree` value is trivially serializable for save/load: copy the
// bytes and you have the AI's exact resume point.
//
// The interpreter is domain-agnostic. It knows how to run composites
// (sequence / selector / inverter / repeater) but nothing about what an
// "action" or "condition" *means*. The game supplies that via two function
// pointers plus an opaque `context` — the same parameterization shape used by
// `Ecs(Backend)` in labelle-core and the `CommandBuffer(Command)` facility:
// mechanism in the engine, domain verbs in the callbacks.
//
// Promoted from flying-platform-labelle's in-tree `behavior_tree` plugin
// (labelle-engine#616). Capacities that were hardcoded constants there
// (`MAX_NODES` / `MAX_CHILDREN` / `MAX_DEPTH`) are comptime-tunable here via
// `BehaviorTree(Options)`; the module-level `Tree` / `TreeBuilder` aliases
// keep the original defaults for callers that don't care.

const std = @import("std");

// ============================================================================
// Domain-agnostic vocabulary (capacity-independent)
// ============================================================================

pub const Status = enum(u8) {
    success,
    failure,
    running,
};

/// Node kinds — each serializable as an enum tag.
pub const NodeKind = enum(u8) {
    sequence, // Run children in order, fail on first failure
    selector, // Try children in order, succeed on first success
    condition, // Check a predicate
    action, // Execute a behavior
    inverter, // Invert child result
    repeater, // Repeat child N times or until failure
};

pub const Node = struct {
    kind: NodeKind,
    /// Index of first child in the node array (-1 = leaf)
    first_child: i32 = -1,
    /// Number of children
    child_count: u16 = 0,
    /// Node-specific data (action ID, condition ID, repeat count, etc.)
    data: u32 = 0,
    /// Runtime state — this is what gets saved
    state: Status = .failure,
    /// For running nodes: which child is currently active
    running_child: u16 = 0,
};

/// Called for action nodes. `data` field identifies which action.
pub const ActionFn = *const fn (action_id: u32, context: *anyopaque) Status;
/// Called for condition nodes. `data` field identifies which condition.
pub const ConditionFn = *const fn (condition_id: u32, context: *anyopaque) bool;

// ============================================================================
// Capacity parameterization
// ============================================================================

/// Comptime-tunable capacity limits. Defaults mirror the original
/// flying-platform facility so existing trees fit unchanged.
pub const Options = struct {
    /// Max total nodes in a tree (topology + inline runtime state).
    max_nodes: u16 = 64,
    /// Max *direct* children per composite (not total descendants).
    max_children: u8 = 32,
    /// Max nesting depth of open composite scopes in `TreeBuilder`.
    max_depth: u8 = 16,
};

/// Build a behavior-tree facility with the given capacities. Returns a
/// namespace exposing `Tree` and `TreeBuilder` bound to `opts`.
///
///     const BT = engine.BehaviorTree(.{ .max_nodes = 128 });
///     var tree = BT.Tree{};
pub fn BehaviorTree(comptime opts: Options) type {
    comptime std.debug.assert(opts.max_nodes >= 1);
    comptime std.debug.assert(opts.max_children >= 1);
    comptime std.debug.assert(opts.max_depth >= 1);

    return struct {
        const Facility = @This();

        pub const options = opts;

        pub const Tree = struct {
            nodes: [MAX_NODES]Node = undefined,
            len: usize = 0,
            /// Index of the root node. Set after building the tree.
            root: u16 = 0,

            const Self = @This();
            pub const MAX_NODES = opts.max_nodes;

            /// Append a node to the tree. Returns its index.
            pub fn addNode(self: *Self, node: Node) error{TreeFull}!u16 {
                if (self.len >= MAX_NODES) return error.TreeFull;
                const idx: u16 = @intCast(self.len);
                self.nodes[idx] = node;
                self.len += 1;
                return idx;
            }

            /// Tick the tree from the root node, returning the root's status.
            pub fn tick(self: *Self, context: *anyopaque, action_fn: ActionFn, condition_fn: ConditionFn) Status {
                if (self.len == 0) return .failure;
                return self.tickNode(self.root, context, action_fn, condition_fn);
            }

            /// Clear all runtime state (status + running_child) on every node.
            pub fn reset(self: *Self) void {
                for (0..self.len) |i| {
                    self.nodes[i].state = .failure;
                    self.nodes[i].running_child = 0;
                }
            }

            // ----------------------------------------------------------------
            // Internal tick logic
            // ----------------------------------------------------------------

            fn tickNode(self: *Self, idx: u16, context: *anyopaque, action_fn: ActionFn, condition_fn: ConditionFn) Status {
                const node = &self.nodes[idx];
                const result: Status = switch (node.kind) {
                    .sequence => self.tickSequence(node, context, action_fn, condition_fn),
                    .selector => self.tickSelector(node, context, action_fn, condition_fn),
                    .action => action_fn(node.data, context),
                    .condition => if (condition_fn(node.data, context)) .success else .failure,
                    .inverter => self.tickInverter(node, context, action_fn, condition_fn),
                    .repeater => self.tickRepeater(node, context, action_fn, condition_fn),
                };
                node.state = result;
                return result;
            }

            fn tickSequence(self: *Self, node: *Node, context: *anyopaque, action_fn: ActionFn, condition_fn: ConditionFn) Status {
                // A negative first_child is the leaf sentinel; combined with a
                // zero child_count it means "no children". Guard it explicitly
                // so a malformed/hand-built node can't panic the @intCast below.
                if (node.child_count == 0 or node.first_child < 0) return .success;
                const first: u16 = @intCast(node.first_child);
                const start: u16 = if (node.state == .running) node.running_child else 0;

                var i: u16 = start;
                while (i < node.child_count) : (i += 1) {
                    const child_idx = first + i;
                    const child_status = self.tickNode(child_idx, context, action_fn, condition_fn);
                    switch (child_status) {
                        .running => {
                            node.running_child = i;
                            return .running;
                        },
                        .failure => {
                            node.running_child = 0;
                            return .failure;
                        },
                        .success => {},
                    }
                }
                node.running_child = 0;
                return .success;
            }

            fn tickSelector(self: *Self, node: *Node, context: *anyopaque, action_fn: ActionFn, condition_fn: ConditionFn) Status {
                // See tickSequence: guard the negative-first_child sentinel.
                if (node.child_count == 0 or node.first_child < 0) return .failure;
                const first: u16 = @intCast(node.first_child);
                const start: u16 = if (node.state == .running) node.running_child else 0;

                var i: u16 = start;
                while (i < node.child_count) : (i += 1) {
                    const child_idx = first + i;
                    const child_status = self.tickNode(child_idx, context, action_fn, condition_fn);
                    switch (child_status) {
                        .running => {
                            node.running_child = i;
                            return .running;
                        },
                        .success => {
                            node.running_child = 0;
                            return .success;
                        },
                        .failure => {},
                    }
                }
                node.running_child = 0;
                return .failure;
            }

            fn tickInverter(self: *Self, node: *Node, context: *anyopaque, action_fn: ActionFn, condition_fn: ConditionFn) Status {
                if (node.first_child < 0 or node.child_count == 0) return .failure;
                const child_idx: u16 = @intCast(node.first_child);
                const child_status = self.tickNode(child_idx, context, action_fn, condition_fn);
                return switch (child_status) {
                    .success => .failure,
                    .failure => .success,
                    .running => .running,
                };
            }

            fn tickRepeater(self: *Self, node: *Node, context: *anyopaque, action_fn: ActionFn, condition_fn: ConditionFn) Status {
                if (node.first_child < 0 or node.child_count == 0) return .failure;
                const child_idx: u16 = @intCast(node.first_child);
                // running_child is u16, so the resumable iteration index must
                // fit in u16. Clamp rather than assert (asserts compile out in
                // release, turning an over-large count into UB on the @intCast
                // below). A count above 65535 simply saturates at 65535.
                const repeat_count: u32 = @min(node.data, std.math.maxInt(u16));
                // Resume from the iteration that was running on the previous tick.
                const start: u32 = if (node.state == .running) node.running_child else 0;

                var i: u32 = start;
                while (i < repeat_count) : (i += 1) {
                    const child_status = self.tickNode(child_idx, context, action_fn, condition_fn);
                    switch (child_status) {
                        .running => {
                            node.running_child = @intCast(i);
                            return .running;
                        },
                        .failure => {
                            node.running_child = 0;
                            return .failure;
                        },
                        .success => {},
                    }
                }
                node.running_child = 0;
                return .success;
            }
        };

        // ====================================================================
        // TreeBuilder — ergonomic helper for constructing trees
        // ====================================================================

        /// A stack-based builder that automatically manages contiguous child
        /// layout.
        ///
        /// Children of a composite MUST be contiguous in the nodes array for
        /// the tick logic (`first_child + i`) to work. With nested composites,
        /// a reserve-first strategy interleaves subtree nodes between siblings,
        /// breaking this invariant.  For example, `Selector(Sequence(A), B)`
        /// would produce `[Sel, Seq, A, B]` — Selector sees children at
        /// indices 1 and 2, but index 2 is `A` (child of Sequence), not `B`.
        ///
        /// Instead, each scope buffers its direct children in a temporary
        /// array. When `end()` is called, the composite node is appended to the
        /// tree followed by copies of its buffered direct children —
        /// guaranteeing contiguity.  Nested composites that were already
        /// finalized via their own `end()` call are stored in the buffer as
        /// "redirect" nodes whose `first_child` points to the real composite's
        /// index in the tree. The copy pass writes these redirect nodes into
        /// the contiguous child slots so the parent's `first_child + i`
        /// resolves correctly.
        pub const TreeBuilder = struct {
            tree: *Facility.Tree,
            /// Stack of open composite scopes.
            scope_stack: [MAX_DEPTH]Scope = undefined,
            depth: u8 = 0,

            const SelfBuilder = @This();
            const MAX_DEPTH = opts.max_depth;
            /// Max direct children per composite (not total descendants).
            const MAX_CHILDREN = opts.max_children;

            const Scope = struct {
                kind: NodeKind,
                /// Buffered direct children, copied into the tree on `end()`.
                /// Leaf nodes are stored with their full data.
                /// Already-finalized composites are stored with `first_child`
                /// pointing to their real index in the tree (a redirect).
                children: [MAX_CHILDREN]Node = undefined,
                /// Number of direct children buffered so far.
                child_count: u8 = 0,
            };

            pub fn init(tree: *Facility.Tree) SelfBuilder {
                return .{ .tree = tree };
            }

            /// Open a sequence composite scope.
            pub fn beginSequence(self: *SelfBuilder) error{TreeFull}!void {
                return self.beginComposite(.sequence);
            }

            /// Open a selector composite scope.
            pub fn beginSelector(self: *SelfBuilder) error{TreeFull}!void {
                return self.beginComposite(.selector);
            }

            /// Close the current composite scope. Appends the composite node
            /// followed by contiguous copies of its direct children, then
            /// returns the composite's index in the tree.
            pub fn end(self: *SelfBuilder) error{TreeFull}!u16 {
                std.debug.assert(self.depth > 0);
                self.depth -= 1;
                const scope = self.scope_stack[self.depth];

                // Append the composite node first with a placeholder first_child.
                const composite_idx = try self.tree.addNode(.{
                    .kind = scope.kind,
                    .first_child = -1,
                    .child_count = @as(u16, scope.child_count),
                });

                // Children start right after the composite in the array.
                self.tree.nodes[composite_idx].first_child = @as(i32, @intCast(self.tree.len));

                // Copy buffered direct children into contiguous slots.
                for (0..scope.child_count) |i| {
                    _ = try self.tree.addNode(scope.children[i]);
                }

                // Register the finalized composite with the parent scope.
                if (self.depth > 0) {
                    const parent = &self.scope_stack[self.depth - 1];
                    // Too many direct children is a data/config constraint, not
                    // a programmer bug — surface it as error.TreeFull.
                    if (parent.child_count >= MAX_CHILDREN) return error.TreeFull;
                    // Store a copy of the composite node so tick can find it
                    // via the parent's first_child + i offset.
                    parent.children[parent.child_count] = self.tree.nodes[composite_idx];
                    parent.child_count += 1;
                }

                return composite_idx;
            }

            /// Add a condition leaf to the current composite.
            pub fn condition(self: *SelfBuilder, id: u32) error{TreeFull}!u16 {
                return self.addLeaf(.condition, id);
            }

            /// Add an action leaf to the current composite.
            pub fn action(self: *SelfBuilder, id: u32) error{TreeFull}!u16 {
                return self.addLeaf(.action, id);
            }

            // ----------------------------------------------------------------
            // Internal helpers
            // ----------------------------------------------------------------

            fn beginComposite(self: *SelfBuilder, kind: NodeKind) error{TreeFull}!void {
                // Exceeding the nesting depth is a data/config constraint, not
                // a programmer bug — surface it as error.TreeFull.
                if (self.depth >= MAX_DEPTH) return error.TreeFull;
                self.scope_stack[self.depth] = .{ .kind = kind };
                self.depth += 1;
            }

            fn addLeaf(self: *SelfBuilder, kind: NodeKind, data: u32) error{TreeFull}!u16 {
                if (self.depth == 0) {
                    // Top-level leaf — append directly to the tree.
                    return self.tree.addNode(.{ .kind = kind, .data = data });
                }
                // Buffer into the current scope; the real tree index is
                // assigned when the enclosing end() copies children.
                const scope = &self.scope_stack[self.depth - 1];
                // Too many direct children — surface as error.TreeFull.
                if (scope.child_count >= MAX_CHILDREN) return error.TreeFull;
                scope.children[scope.child_count] = .{ .kind = kind, .data = data };
                scope.child_count += 1;
                // Return 0 as a placeholder — callers of action()/condition()
                // inside a scope should not rely on the returned index.
                return 0;
            }
        };
    };
}

// ============================================================================
// Default-capacity aliases
// ============================================================================
//
// Mirrors the original flying-platform capacities (MAX_NODES=64,
// MAX_CHILDREN=32, MAX_DEPTH=16). Reach for `BehaviorTree(.{...})` when you
// need bigger trees.

const Default = BehaviorTree(.{});

pub const Tree = Default.Tree;
pub const TreeBuilder = Default.TreeBuilder;
