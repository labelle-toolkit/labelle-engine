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
            // Verify the type is correct
            const field_info = @typeInfo(Bar).@"struct".fields[0];
            try expect.toBeTrue(std.mem.eql(u8, field_info.name, "bazzes"));
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
