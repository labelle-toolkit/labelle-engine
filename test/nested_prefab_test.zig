const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const prefab = engine.prefab;

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

    // Prefab with Foo and Bar components (like qux in example_5)
    const qux_prefab = .{
        .sprite = .{
            .name = "qux",
            .z_index = 100,
        },
        .components = .{
            .Foo = .{ .value = 42 },
            .Bar = .{},
        },
    };

    const TestPrefabs = prefab.PrefabRegistry(.{
        .qux = qux_prefab,
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
};
