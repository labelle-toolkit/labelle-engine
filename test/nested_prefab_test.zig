const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const prefab = engine.prefab;

// Import factory definitions from .zon files
const nested_prefab_defs = @import("factories/nested_prefabs.zon");

test {
    zspec.runAll(@This());
}

pub const PREFAB_WITH_COMPONENTS = struct {
    const ecs = @import("ecs");
    const Entity = ecs.Entity;

    const Bar = struct {
        bazzes: []const Entity = &.{},
    };

    const Foo = struct {
        value: i32 = 0,
    };

    const TestPrefabs = prefab.PrefabRegistry(.{
        .qux = nested_prefab_defs.qux,
    });

    pub const HAS_COMPONENTS = struct {
        test "qux prefab has components" {
            try expect.toBeTrue(TestPrefabs.hasComponents("qux"));
        }

        test "qux prefab has Foo component" {
            const components = TestPrefabs.getComponents("qux");
            try expect.toBeTrue(@hasField(@TypeOf(components), "Foo"));
        }

        test "qux prefab has Bar component" {
            const components = TestPrefabs.getComponents("qux");
            try expect.toBeTrue(@hasField(@TypeOf(components), "Bar"));
        }
    };

    pub const FOO_COMPONENT = struct {
        test "Foo has correct value" {
            const components = TestPrefabs.getComponents("qux");
            try expect.equal(components.Foo.value, 42);
        }
    };

    pub const BAR_COMPONENT = struct {
        test "Bar component type has bazzes field" {
            // The Bar component type (not prefab data) has bazzes field
            try expect.toBeTrue(@hasField(Bar, "bazzes"));
        }

        test "Bar.bazzes is a slice of Entity" {
            // Verify the field type is []const Entity
            const field_info = @typeInfo(Bar).@"struct".fields[0];
            try expect.toBeTrue(std.mem.eql(u8, field_info.name, "bazzes"));

            // Verify the type is a pointer (slice)
            const type_info = @typeInfo(field_info.type);
            try expect.toBeTrue(type_info == .pointer);

            // Verify it's a slice (not single pointer) of Entity
            try expect.toBeTrue(type_info.pointer.size == .slice);
            try expect.toBeTrue(type_info.pointer.child == Entity);
        }
    };
};

pub const SCENE_LOADER_API = struct {
    const loader = engine.loader;

    test "SceneLoader exports instantiatePrefab function" {
        // Verify the SceneLoader type has the instantiatePrefab method
        const TestPrefabs = prefab.PrefabRegistry(.{});
        const TestComponents = engine.component.ComponentRegistry(struct {});
        const TestScripts = engine.script.ScriptRegistry(struct {});
        const TestLoader = loader.SceneLoader(TestPrefabs, TestComponents, TestScripts);

        try expect.toBeTrue(@hasDecl(TestLoader, "instantiatePrefab"));
    }
};

pub const ZON_COERCION = struct {
    const zon = engine.zon_coercion;
    const ecs = @import("ecs");
    const Entity = ecs.Entity;

    pub const IS_ENTITY_SLICE = struct {
        test "isEntitySlice returns true for []const Entity" {
            try expect.toBeTrue(zon.isEntitySlice([]const Entity));
        }

        test "isEntitySlice returns false for []const u32" {
            try expect.toBeFalse(zon.isEntitySlice([]const u32));
        }

        test "isEntitySlice returns false for non-slice types" {
            try expect.toBeFalse(zon.isEntitySlice(u32));
            try expect.toBeFalse(zon.isEntitySlice(Entity));
        }
    };

    pub const IS_ENTITY = struct {
        test "isEntity returns true for Entity type" {
            try expect.toBeTrue(zon.isEntity(Entity));
        }

        test "isEntity returns false for slice of Entity" {
            try expect.toBeFalse(zon.isEntity([]const Entity));
        }

        test "isEntity returns false for other types" {
            try expect.toBeFalse(zon.isEntity(u32));
            try expect.toBeFalse(zon.isEntity(i32));
            try expect.toBeFalse(zon.isEntity([]const u8));
        }
    };

    test "coerceValue handles simple types" {
        const result = comptime zon.coerceValue(i32, 42);
        try expect.equal(result, 42);
    }

    test "coerceValue handles nested structs" {
        const Inner = struct { x: i32, y: i32 };
        const result = comptime zon.coerceValue(Inner, .{ .x = 10, .y = 20 });
        try expect.equal(result.x, 10);
        try expect.equal(result.y, 20);
    }

    test "coerceValue returns empty slice for Entity slices" {
        // Entity slices should return empty since entity creation is runtime-only
        const result = comptime zon.coerceValue([]const Entity, .{});
        try expect.equal(result.len, 0);
    }

    test "buildStruct creates struct from anonymous data" {
        const TestStruct = struct {
            value: i32 = 0,
            name: []const u8 = "",
        };
        const result = comptime zon.buildStruct(TestStruct, .{ .value = 123, .name = "test" });
        try expect.equal(result.value, 123);
        try expect.toBeTrue(std.mem.eql(u8, result.name, "test"));
    }

    test "buildStruct uses defaults for missing fields" {
        const TestStruct = struct {
            value: i32 = 99,
            count: u32 = 5,
        };
        const result = comptime zon.buildStruct(TestStruct, .{ .value = 42 });
        try expect.equal(result.value, 42);
        try expect.equal(result.count, 5);
    }

    test "buildStruct works with required fields when all provided" {
        const TestStruct = struct {
            required_value: i32, // No default - required
            optional_value: u32 = 10,
        };
        const result = comptime zon.buildStruct(TestStruct, .{ .required_value = 42 });
        try expect.equal(result.required_value, 42);
        try expect.equal(result.optional_value, 10);
    }

    test "tupleToSlice converts tuple to slice" {
        const result = comptime zon.tupleToSlice(i32, .{ 1, 2, 3 });
        try expect.equal(result.len, 3);
        try expect.equal(result[0], 1);
        try expect.equal(result[1], 2);
        try expect.equal(result[2], 3);
    }

    test "coerceValue handles fixed-size array from tuple" {
        const Item = struct {
            value: u32 = 0,
        };

        const Container = struct {
            items: [2]Item = undefined,
        };

        const zon_data = .{
            .items = .{
                .{ .value = 10 },
                .{ .value = 20 },
            },
        };

        const result = comptime zon.buildStruct(Container, zon_data);
        try expect.equal(result.items[0].value, 10);
        try expect.equal(result.items[1].value, 20);
    }

    test "coerceValue handles nested structs in fixed-size array" {
        const Inner = struct {
            x: i32 = 0,
            y: i32 = 0,
        };

        const Slot = struct {
            components: Inner = .{},
        };

        const Workstation = struct {
            slots: [3]Slot = undefined,
        };

        const zon_data = .{
            .slots = .{
                .{ .components = .{ .x = -60, .y = 0 } },
                .{ .components = .{ .x = 0, .y = 0 } },
                .{ .components = .{ .x = 60, .y = 0 } },
            },
        };

        const result = comptime zon.buildStruct(Workstation, zon_data);
        try expect.equal(result.slots[0].components.x, -60);
        try expect.equal(result.slots[1].components.x, 0);
        try expect.equal(result.slots[2].components.x, 60);
    }

    test "coerceValue handles single element fixed-size array" {
        const Item = struct {
            name: []const u8 = "",
        };

        const Container = struct {
            items: [1]Item = undefined,
        };

        const zon_data = .{
            .items = .{
                .{ .name = "first" },
            },
        };

        const result = comptime zon.buildStruct(Container, zon_data);
        try expect.toBeTrue(std.mem.eql(u8, result.items[0].name, "first"));
    }
};

// ============================================
// PREFAB REFERENCES IN ENTITY FIELDS
// ============================================

pub const PREFAB_IN_ENTITY_FIELDS = struct {
    const ecs = @import("ecs");
    const Entity = ecs.Entity;
    const loader = engine.loader;
    const component = engine.component;
    const script = engine.script;

    // ----------------------------------------
    // Test Components (factories for test data)
    // ----------------------------------------

    /// Component with entity list field
    const Room = struct {
        movement_nodes: []const Entity = &.{},
    };

    /// Component with single entity field
    const Weapon = struct {
        projectile: Entity = Entity.invalid,
    };

    /// Simple marker component for prefabs
    const MovementNode = struct {};

    /// Simple damage component for prefabs
    const Damage = struct {
        value: i32 = 10,
    };

    // ----------------------------------------
    // Test Registries Factory (using .zon definitions)
    // ----------------------------------------

    const TestPrefabs = prefab.PrefabRegistry(.{
        .movement_node = nested_prefab_defs.movement_node,
        .bullet = nested_prefab_defs.bullet,
    });

    const TestComponents = component.ComponentRegistry(struct {
        pub const Room = PREFAB_IN_ENTITY_FIELDS.Room;
        pub const Weapon = PREFAB_IN_ENTITY_FIELDS.Weapon;
        pub const MovementNode = PREFAB_IN_ENTITY_FIELDS.MovementNode;
        pub const Damage = PREFAB_IN_ENTITY_FIELDS.Damage;
    });

    const TestScripts = script.ScriptRegistry(struct {});

    const TestLoader = loader.SceneLoader(TestPrefabs, TestComponents, TestScripts);

    // ----------------------------------------
    // Entity List with Prefab References
    // ----------------------------------------

    pub const ENTITY_LIST_WITH_PREFABS = struct {
        test "prefab reference in entity list has prefab field" {
            const room_with_prefabs = .{
                .components = .{
                    .Room = .{ .movement_nodes = .{
                        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 10 } } },
                        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 20 } } },
                    } },
                },
            };
            const first_node = room_with_prefabs.components.Room.movement_nodes[0];
            try expect.toBeTrue(@hasField(@TypeOf(first_node), "prefab"));
            try expect.toBeTrue(std.mem.eql(u8, first_node.prefab, "movement_node"));
        }

        test "prefab reference in entity list can have component overrides" {
            const room_with_prefabs = .{
                .components = .{
                    .Room = .{ .movement_nodes = .{
                        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 10, .y = 20 } } },
                    } },
                },
            };
            const first_node = room_with_prefabs.components.Room.movement_nodes[0];
            try expect.toBeTrue(@hasField(@TypeOf(first_node), "components"));
            try expect.equal(first_node.components.Position.x, 10);
            try expect.equal(first_node.components.Position.y, 20);
        }

        test "entity list can mix prefab references and inline definitions" {
            const room_mixed = .{
                .components = .{
                    .Room = .{ .movement_nodes = .{
                        .{ .prefab = "movement_node" },
                        .{ .components = .{ .Position = .{ .x = 50 }, .Shape = .{ .type = .circle, .radius = 5 } } },
                    } },
                },
            };
            // First is prefab
            try expect.toBeTrue(@hasField(@TypeOf(room_mixed.components.Room.movement_nodes[0]), "prefab"));
            // Second is inline
            try expect.toBeTrue(@hasField(@TypeOf(room_mixed.components.Room.movement_nodes[1]), "components"));
        }
    };

    // ----------------------------------------
    // Single Entity with Prefab Reference
    // ----------------------------------------

    pub const SINGLE_ENTITY_WITH_PREFAB = struct {
        test "prefab reference in single entity field has prefab field" {
            const weapon_with_prefab = .{
                .components = .{
                    .Weapon = .{ .projectile = .{ .prefab = "bullet" } },
                },
            };
            const projectile = weapon_with_prefab.components.Weapon.projectile;
            try expect.toBeTrue(@hasField(@TypeOf(projectile), "prefab"));
            try expect.toBeTrue(std.mem.eql(u8, projectile.prefab, "bullet"));
        }

        test "prefab reference in single entity can have component overrides" {
            const weapon_with_prefab = .{
                .components = .{
                    .Weapon = .{ .projectile = .{ .prefab = "bullet", .components = .{ .Damage = .{ .value = 25 } } } },
                },
            };
            const projectile = weapon_with_prefab.components.Weapon.projectile;
            try expect.toBeTrue(@hasField(@TypeOf(projectile), "components"));
            try expect.equal(projectile.components.Damage.value, 25);
        }

        test "single entity can use inline definition instead of prefab" {
            const weapon_inline = .{
                .components = .{
                    .Weapon = .{ .projectile = .{
                        .components = .{
                            .Position = .{ .x = 0, .y = 0 },
                            .Sprite = .{ .name = "custom_bullet.png" },
                            .Damage = .{ .value = 50 },
                        },
                    } },
                },
            };
            const projectile = weapon_inline.components.Weapon.projectile;
            try expect.toBeTrue(@hasField(@TypeOf(projectile), "components"));
            try expect.toBeFalse(@hasField(@TypeOf(projectile), "prefab"));
        }
    };

    // ----------------------------------------
    // Loader Integration
    // ----------------------------------------

    pub const LOADER_INTEGRATION = struct {
        test "TestLoader is properly configured" {
            try expect.toBeTrue(@hasDecl(TestLoader, "load"));
            try expect.toBeTrue(@hasDecl(TestLoader, "instantiatePrefab"));
        }

        test "TestPrefabs has movement_node prefab" {
            try expect.toBeTrue(TestPrefabs.has("movement_node"));
        }

        test "TestPrefabs has bullet prefab" {
            try expect.toBeTrue(TestPrefabs.has("bullet"));
        }
    };
};
