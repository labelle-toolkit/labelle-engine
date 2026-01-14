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

    test "isReference returns true for id reference" {
        const data = .{ .ref = .{ .id = "player_1" } };
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
        try expect.toBeTrue(comptime std.mem.eql(u8, ref_info.ref_key.?, "player"));
        try expect.toBeFalse(ref_info.is_self);
        try expect.toBeFalse(ref_info.is_id_ref);
    }

    test "extractRefInfo extracts id from reference" {
        const data = .{ .ref = .{ .id = "player_1" } };
        const ref_info = comptime core.extractRefInfo(data).?;
        try expect.toBeTrue(comptime std.mem.eql(u8, ref_info.ref_key.?, "player_1"));
        try expect.toBeFalse(ref_info.is_self);
        try expect.toBeTrue(ref_info.is_id_ref);
    }

    test "extractRefInfo identifies self reference" {
        const data = .{ .ref = .self };
        const ref_info = comptime core.extractRefInfo(data).?;
        try expect.toBeTrue(ref_info.ref_key == null);
        try expect.toBeTrue(ref_info.is_self);
    }
};

// ============================================
// ENTITY ID GENERATION
// ============================================

pub const ENTITY_ID_GENERATION = struct {
    test "generateAutoId creates indexed IDs" {
        try expect.toBeTrue(comptime std.mem.eql(u8, core.generateAutoId(0), "_e0"));
        try expect.toBeTrue(comptime std.mem.eql(u8, core.generateAutoId(1), "_e1"));
        try expect.toBeTrue(comptime std.mem.eql(u8, core.generateAutoId(42), "_e42"));
    }

    test "getEntityId returns explicit id when present" {
        const entity_def = .{ .id = "my_entity", .prefab = "player" };
        const id = comptime core.getEntityId(entity_def, 5);
        try expect.toBeTrue(comptime std.mem.eql(u8, id, "my_entity"));
    }

    test "getEntityId generates auto id when not present" {
        const entity_def = .{ .prefab = "player" };
        const id = comptime core.getEntityId(entity_def, 5);
        try expect.toBeTrue(comptime std.mem.eql(u8, id, "_e5"));
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

    test "hasAnyReference returns true for struct with id reference field" {
        const data = .{
            .x = 10,
            .target = .{ .ref = .{ .id = "player_1" } },
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

    test "entity reference by name syntax is valid zon" {
        // This is how you reference another entity by name
        const ai_component = .{
            .state = .idle,
            .target = .{ .ref = .{ .entity = "player" } },
        };
        try expect.toBeTrue(comptime core.isReference(ai_component.target));

        const ref_info = comptime core.extractRefInfo(ai_component.target).?;
        try expect.toBeFalse(ref_info.is_id_ref);
    }

    test "entity reference by id syntax is valid zon" {
        // This is how you reference another entity by unique ID
        const ai_component = .{
            .state = .idle,
            .target = .{ .ref = .{ .id = "player_1" } },
        };
        try expect.toBeTrue(comptime core.isReference(ai_component.target));

        const ref_info = comptime core.extractRefInfo(ai_component.target).?;
        try expect.toBeTrue(ref_info.is_id_ref);
    }

    test "self reference syntax is valid zon" {
        // This is how you reference the current entity (self)
        const health_bar_component = .{
            .offset_y = -20,
            .source = .{ .ref = .self },
        };
        try expect.toBeTrue(comptime core.isReference(health_bar_component.source));
    }

    test "scene with named entities and references by name" {
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
        try expect.toBeTrue(comptime std.mem.eql(u8, ref_info.ref_key.?, "player"));
        try expect.toBeFalse(ref_info.is_id_ref);
    }

    test "scene with explicit ids and references by id" {
        // Example scene structure with explicit IDs
        const scene_data = .{
            .name = "battle",
            .entities = .{
                // Entity with explicit ID
                .{ .id = "player_1", .name = "player", .prefab = "player_character" },
                // Entity referencing by ID (not name)
                .{ .id = "enemy_1", .prefab = "enemy", .components = .{
                    .AI = .{
                        .state = .idle,
                        .target = .{ .ref = .{ .id = "player_1" } },
                    },
                }},
            },
        };

        // Verify first entity has explicit ID
        try expect.toBeTrue(@hasField(@TypeOf(scene_data.entities[0]), "id"));
        try expect.toBeTrue(comptime std.mem.eql(u8, scene_data.entities[0].id, "player_1"));

        // Verify second entity references by ID
        const ai = scene_data.entities[1].components.AI;
        const ref_info = comptime core.extractRefInfo(ai.target).?;
        try expect.toBeTrue(comptime std.mem.eql(u8, ref_info.ref_key.?, "player_1"));
        try expect.toBeTrue(ref_info.is_id_ref);
    }

    test "scene with auto-generated ids" {
        // When no .id is specified, IDs are auto-generated as _e0, _e1, etc.
        const scene_data = .{
            .name = "level",
            .entities = .{
                .{ .prefab = "enemy" }, // ID will be _e0
                .{ .prefab = "enemy" }, // ID will be _e1
                .{ .prefab = "enemy" }, // ID will be _e2
            },
        };

        // Verify auto-generated IDs
        try expect.toBeTrue(comptime std.mem.eql(u8, core.getEntityId(scene_data.entities[0], 0), "_e0"));
        try expect.toBeTrue(comptime std.mem.eql(u8, core.getEntityId(scene_data.entities[1], 1), "_e1"));
        try expect.toBeTrue(comptime std.mem.eql(u8, core.getEntityId(scene_data.entities[2], 2), "_e2"));
    }
};
