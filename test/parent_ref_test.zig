const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const ecs = @import("ecs");
const Entity = ecs.Entity;
const loader = engine.scene.loader;
const prefab = engine.scene.prefab;
const component = engine.scene.component;
const script = engine.scene.script;

test {
    zspec.runAll(@This());
}

// Helper to get invalid entity (backend-agnostic)
fn getInvalidEntity() Entity {
    if (comptime ecs.has_invalid_entity) {
        return Entity.invalid;
    } else {
        // For zig_ecs which doesn't have .invalid, use a sentinel value
        return @bitCast(@as(ecs.EntityBits, 0));
    }
}

// ============================================
// TO LOWERCASE HELPER
// ============================================

pub const TO_LOWERCASE = struct {
    test "toLowercase converts uppercase to lowercase" {
        const expected = "hello";
        const result = comptime loader.toLowercase("HELLO");
        try expect.toBeTrue(comptime std.mem.eql(u8, result, expected));
    }

    test "toLowercase preserves lowercase" {
        const expected = "hello";
        const result = comptime loader.toLowercase("hello");
        try expect.toBeTrue(comptime std.mem.eql(u8, result, expected));
    }

    test "toLowercase handles mixed case" {
        const expected = "workstation";
        const result = comptime loader.toLowercase("Workstation");
        try expect.toBeTrue(comptime std.mem.eql(u8, result, expected));
    }

    test "toLowercase handles single char" {
        const expected = "a";
        const result = comptime loader.toLowercase("A");
        try expect.toBeTrue(comptime std.mem.eql(u8, result, expected));
    }
};

// ============================================
// PARENT REFERENCE CONVENTION
// ============================================

pub const PARENT_REF_CONVENTION = struct {
    /// Storage component with parent reference field (Entity default handled at runtime)
    const Storage = struct {
        role: enum { eis, iis, ios, eos } = .ios,
        workstation: Entity = getInvalidEntity(), // Parent reference - matches "Workstation"

        // onReady callback for testing
        pub fn onReady(payload: loader.ComponentPayload) void {
            _ = payload;
            // Would be called after hierarchy is complete
        }
    };

    /// Workstation component with nested storages
    const Workstation = struct {
        process_duration: u32 = 60,
        output_storages: []const Entity = &.{},
    };

    /// Position component
    const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    pub const FIELD_DETECTION = struct {
        test "Storage has workstation field" {
            try expect.toBeTrue(@hasField(Storage, "workstation"));
        }

        test "workstation field is Entity type" {
            const field_info = @typeInfo(Storage).@"struct".fields[1];
            try expect.toBeTrue(std.mem.eql(u8, field_info.name, "workstation"));
            try expect.toBeTrue(field_info.type == Entity);
        }
    };

    pub const CONVENTION_NAMING = struct {
        test "lowercase of Workstation matches workstation field" {
            const lowercase = comptime loader.toLowercase("Workstation");
            try expect.toBeTrue(comptime std.mem.eql(u8, lowercase, "workstation"));
            try expect.toBeTrue(@hasField(Storage, lowercase));
        }
    };

    pub const COMPONENT_PAYLOAD = struct {
        test "ComponentPayload has entity_id field" {
            try expect.toBeTrue(@hasField(loader.ComponentPayload, "entity_id"));
        }

        test "ComponentPayload has game_ptr field" {
            try expect.toBeTrue(@hasField(loader.ComponentPayload, "game_ptr"));
        }

        test "ComponentPayload has getGame method" {
            try expect.toBeTrue(@hasDecl(loader.ComponentPayload, "getGame"));
        }
    };
};

// ============================================
// ZON PREFAB STRUCTURE WITH NESTED ENTITIES
// ============================================

pub const NESTED_ENTITIES_ZON = struct {
    // Sample prefab structure with nested entities
    const workstation_prefab = .{
        .components = .{
            .Position = .{ .x = 100, .y = 100 },
            .Workstation = .{
                .process_duration = 120,
                .output_storages = .{
                    .{ .components = .{ .Storage = .{ .role = .ios } } },
                    .{ .components = .{ .Storage = .{ .role = .eos } } },
                },
            },
        },
    };

    pub const STRUCTURE = struct {
        test "prefab has components field" {
            try expect.toBeTrue(@hasField(@TypeOf(workstation_prefab), "components"));
        }

        test "components has Workstation field" {
            try expect.toBeTrue(@hasField(@TypeOf(workstation_prefab.components), "Workstation"));
        }

        test "Workstation has output_storages field" {
            try expect.toBeTrue(@hasField(@TypeOf(workstation_prefab.components.Workstation), "output_storages"));
        }

        test "output_storages has 2 nested entities" {
            try expect.equal(workstation_prefab.components.Workstation.output_storages.len, 2);
        }

        test "nested entity has components field" {
            const first = workstation_prefab.components.Workstation.output_storages[0];
            try expect.toBeTrue(@hasField(@TypeOf(first), "components"));
        }

        test "nested entity components has Storage" {
            const first = workstation_prefab.components.Workstation.output_storages[0];
            try expect.toBeTrue(@hasField(@TypeOf(first.components), "Storage"));
        }

        test "nested Storage has role" {
            const first = workstation_prefab.components.Workstation.output_storages[0];
            try expect.toBeTrue(@hasField(@TypeOf(first.components.Storage), "role"));
        }
    };
};

// ============================================
// ON_READY CALLBACK
// ============================================

pub const ON_READY_CALLBACK = struct {
    /// Test component with onReady callback
    const TestComponent = struct {
        value: i32 = 0,

        pub fn onReady(payload: loader.ComponentPayload) void {
            _ = payload;
            // Callback implementation
        }
    };

    /// Test component without onReady callback
    const SimpleComponent = struct {
        value: i32 = 0,
    };

    pub const CALLBACK_DETECTION = struct {
        test "TestComponent has onReady declaration" {
            try expect.toBeTrue(@hasDecl(TestComponent, "onReady"));
        }

        test "SimpleComponent does not have onReady" {
            try expect.toBeFalse(@hasDecl(SimpleComponent, "onReady"));
        }

        test "onReady is a function" {
            const onReady = @TypeOf(TestComponent.onReady);
            try expect.toBeTrue(@typeInfo(onReady) == .@"fn");
        }
    };
};

// ============================================
// MULTI-LEVEL HIERARCHY
// ============================================

pub const MULTI_LEVEL_HIERARCHY = struct {
    /// Building contains rooms
    const Building = struct {
        rooms: []const Entity = &.{},
    };

    /// Room contains workstations and has building parent
    const Room = struct {
        building: Entity = getInvalidEntity(), // Parent reference
        workstations: []const Entity = &.{},
    };

    /// Workstation contains storages and has room parent
    const Workstation = struct {
        room: Entity = getInvalidEntity(), // Parent reference
        storages: []const Entity = &.{},
    };

    /// Storage has workstation parent
    const Storage = struct {
        workstation: Entity = getInvalidEntity(), // Parent reference
        role: enum { input, output } = .input,
    };

    pub const PARENT_FIELDS = struct {
        test "Room has building parent field" {
            try expect.toBeTrue(@hasField(Room, "building"));
        }

        test "Workstation has room parent field" {
            try expect.toBeTrue(@hasField(Workstation, "room"));
        }

        test "Storage has workstation parent field" {
            try expect.toBeTrue(@hasField(Storage, "workstation"));
        }
    };

    pub const NAMING_CONVENTION = struct {
        test "lowercase Building matches building field in Room" {
            const name = comptime loader.toLowercase("Building");
            try expect.toBeTrue(comptime std.mem.eql(u8, name, "building"));
            try expect.toBeTrue(@hasField(Room, name));
        }

        test "lowercase Room matches room field in Workstation" {
            const name = comptime loader.toLowercase("Room");
            try expect.toBeTrue(comptime std.mem.eql(u8, name, "room"));
            try expect.toBeTrue(@hasField(Workstation, name));
        }

        test "lowercase Workstation matches workstation field in Storage" {
            const name = comptime loader.toLowercase("Workstation");
            try expect.toBeTrue(comptime std.mem.eql(u8, name, "workstation"));
            try expect.toBeTrue(@hasField(Storage, name));
        }
    };
};
