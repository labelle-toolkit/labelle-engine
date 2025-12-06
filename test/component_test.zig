const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const component = engine.component;

test {
    zspec.runAll(@This());
}

// Test component types
const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
};

const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

const Tag = struct {};

const ComplexComponent = struct {
    name: []const u8 = "",
    value: i32 = 0,
    enabled: bool = true,
    scale: f32 = 1.0,
};

pub const COMPONENT_REGISTRY = struct {
    const TestRegistry = component.ComponentRegistry(struct {
        pub const Position = component_test.Position;
        pub const Velocity = component_test.Velocity;
        pub const Health = component_test.Health;
        pub const Tag = component_test.Tag;
        pub const ComplexComponent = component_test.ComplexComponent;
    });

    pub const HAS = struct {
        test "returns true for registered component" {
            try expect.toBeTrue(TestRegistry.has("Position"));
        }

        test "returns true for all registered components" {
            try expect.toBeTrue(TestRegistry.has("Position"));
            try expect.toBeTrue(TestRegistry.has("Velocity"));
            try expect.toBeTrue(TestRegistry.has("Health"));
            try expect.toBeTrue(TestRegistry.has("Tag"));
            try expect.toBeTrue(TestRegistry.has("ComplexComponent"));
        }

        test "returns false for unregistered component" {
            try expect.toBeFalse(TestRegistry.has("Unknown"));
        }

        test "is case sensitive" {
            try expect.toBeFalse(TestRegistry.has("position"));
            try expect.toBeFalse(TestRegistry.has("POSITION"));
            try expect.toBeFalse(TestRegistry.has("health"));
        }

        test "returns false for empty string" {
            try expect.toBeFalse(TestRegistry.has(""));
        }

        test "returns false for partial match" {
            try expect.toBeFalse(TestRegistry.has("Pos"));
            try expect.toBeFalse(TestRegistry.has("Heal"));
        }
    };

    pub const GET_TYPE = struct {
        test "returns correct type for Position" {
            const T = TestRegistry.getType("Position");
            try expect.toBeTrue(@typeName(T).len == @typeName(Position).len);
        }

        test "returns correct type for Velocity" {
            const T = TestRegistry.getType("Velocity");
            try expect.toBeTrue(@typeName(T).len == @typeName(Velocity).len);
        }

        test "returns correct type for Health" {
            const T = TestRegistry.getType("Health");
            try expect.toBeTrue(@typeName(T).len == @typeName(Health).len);
        }

        test "returns correct type for Tag" {
            const T = TestRegistry.getType("Tag");
            try expect.toBeTrue(@typeName(T).len == @typeName(Tag).len);
        }

        test "returns correct type for ComplexComponent" {
            const T = TestRegistry.getType("ComplexComponent");
            try expect.toBeTrue(@typeName(T).len == @typeName(ComplexComponent).len);
        }
    };

    pub const NAMES = struct {
        test "names contains all registered components" {
            const names = TestRegistry.names;
            try expect.equal(names.len, 5);
        }
    };
};

pub const EMPTY_REGISTRY = struct {
    const EmptyRegistry = component.ComponentRegistry(struct {});

    pub const HAS = struct {
        test "returns false for any name" {
            try expect.toBeFalse(EmptyRegistry.has("Position"));
            try expect.toBeFalse(EmptyRegistry.has("anything"));
            try expect.toBeFalse(EmptyRegistry.has(""));
        }
    };

    pub const NAMES = struct {
        test "names is empty" {
            try expect.equal(EmptyRegistry.names.len, 0);
        }
    };
};

pub const SINGLE_COMPONENT_REGISTRY = struct {
    const SingleRegistry = component.ComponentRegistry(struct {
        pub const OnlyOne = Position;
    });

    pub const HAS = struct {
        test "returns true for the single registered component" {
            try expect.toBeTrue(SingleRegistry.has("OnlyOne"));
        }

        test "returns false for other names" {
            try expect.toBeFalse(SingleRegistry.has("Position"));
            try expect.toBeFalse(SingleRegistry.has("Other"));
        }
    };

    pub const NAMES = struct {
        test "names has one entry" {
            try expect.equal(SingleRegistry.names.len, 1);
        }
    };
};

const component_test = @This();
