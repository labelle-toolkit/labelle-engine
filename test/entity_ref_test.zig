const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const core = engine.core;

test {
    zspec.runAll(@This());
}

// ============================================
// REFERENCE DETECTION (Issue #242)
// ============================================

pub const REFERENCE_DETECTION = struct {
    test "isReference returns false for non-reference struct" {
        const data = .{ .x = 10, .y = 20 };
        try expect.toBeFalse(comptime core.isReference(data));
    }

    test "isReference returns true for entity reference" {
        const data = .{ .ref = .{ .entity = "player" } };
        try expect.toBeTrue(comptime core.isReference(data));
    }

    test "isReference returns true for self reference" {
        const data = .{ .ref = .self };
        try expect.toBeTrue(comptime core.isReference(data));
    }

    test "extractRefInfo returns null for non-reference" {
        const data = .{ .x = 10, .y = 20 };
        const ref_info = comptime core.extractRefInfo(data);
        try expect.toBeTrue(ref_info == null);
    }

    test "extractRefInfo extracts entity name from reference" {
        const data = .{ .ref = .{ .entity = "player" } };
        const ref_info = comptime core.extractRefInfo(data).?;
        try expect.toBeTrue(comptime std.mem.eql(u8, ref_info.entity_name.?, "player"));
        try expect.toBeFalse(ref_info.is_self);
    }

    test "extractRefInfo identifies self reference" {
        const data = .{ .ref = .self };
        const ref_info = comptime core.extractRefInfo(data).?;
        try expect.toBeTrue(ref_info.entity_name == null);
        try expect.toBeTrue(ref_info.is_self);
    }
};

// ============================================
// REFERENCE HELPER FUNCTIONS
// ============================================

pub const REFERENCE_HELPERS = struct {
    test "hasAnyReference returns false for struct without references" {
        const data = .{
            .x = 10,
            .y = 20,
            .name = "test",
        };
        try expect.toBeFalse(comptime core.hasAnyReference(data));
    }

    test "hasAnyReference returns true for struct with reference field" {
        const data = .{
            .x = 10,
            .target = .{ .ref = .{ .entity = "player" } },
        };
        try expect.toBeTrue(comptime core.hasAnyReference(data));
    }

    test "getReferenceFieldNames returns empty for no references" {
        const data = .{
            .x = 10,
            .y = 20,
        };
        const names = comptime core.getReferenceFieldNames(data);
        try expect.equal(names.len, 0);
    }

    test "getReferenceFieldNames returns field names with references" {
        const data = .{
            .x = 10,
            .target = .{ .ref = .{ .entity = "player" } },
            .self_ref = .{ .ref = .self },
        };
        const names = comptime core.getReferenceFieldNames(data);
        try expect.equal(names.len, 2);
    }
};

// ============================================
// REFERENCE SYNTAX EXAMPLES
// ============================================

pub const REFERENCE_SYNTAX = struct {
    // Example ZON structures showing valid reference syntax

    test "entity reference syntax is valid zon" {
        // This is how you reference another entity by name
        const ai_component = .{
            .state = .idle,
            .target = .{ .ref = .{ .entity = "player" } },
        };
        try expect.toBeTrue(comptime core.isReference(ai_component.target));
    }

    test "self reference syntax is valid zon" {
        // This is how you reference the current entity (self)
        const health_bar_component = .{
            .offset_y = -20,
            .source = .{ .ref = .self },
        };
        try expect.toBeTrue(comptime core.isReference(health_bar_component.source));
    }

    test "scene with named entities and references" {
        // Example scene structure with named entities
        const scene_data = .{
            .name = "battle",
            .entities = .{
                // Named entity
                .{ .name = "player", .prefab = "player_character", .components = .{ .Position = .{ .x = 100, .y = 100 } } },
                // Entity with reference to named entity
                .{ .prefab = "enemy", .components = .{
                    .Position = .{ .x = 200, .y = 100 },
                    .AI = .{
                        .state = .idle,
                        .target = .{ .ref = .{ .entity = "player" } },
                    },
                }},
            },
        };

        // Verify scene has entities
        try expect.equal(scene_data.entities.len, 2);

        // Verify first entity has name
        try expect.toBeTrue(@hasField(@TypeOf(scene_data.entities[0]), "name"));
        try expect.toBeTrue(comptime std.mem.eql(u8, scene_data.entities[0].name, "player"));

        // Verify second entity has reference in AI component
        const ai = scene_data.entities[1].components.AI;
        try expect.toBeTrue(comptime core.isReference(ai.target));

        const ref_info = comptime core.extractRefInfo(ai.target).?;
        try expect.toBeTrue(comptime std.mem.eql(u8, ref_info.entity_name.?, "player"));
    }
};
