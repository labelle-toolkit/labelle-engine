const expect = @import("zspec").expect;
const jsonc = @import("jsonc");
const Value = jsonc.Value;

pub const ValueSpec = struct {
    pub const asObject = struct {
        test "returns object for object values" {
            const val = Value{ .object = .{ .entries = &.{} } };
            try expect.not_null(val.asObject());
        }

        test "returns null for non-object values" {
            const val = Value{ .integer = 42 };
            try expect.to_be_null(val.asObject());
        }
    };

    pub const asString = struct {
        test "returns string for string values" {
            const val = Value{ .string = "hello" };
            try expect.equal(val.asString().?, "hello");
        }

        test "returns null for non-string values" {
            const val = Value{ .integer = 42 };
            try expect.to_be_null(val.asString());
        }
    };

    pub const asInteger = struct {
        test "returns integer for integer values" {
            const val = Value{ .integer = 42 };
            try expect.equal(val.asInteger().?, 42);
        }

        test "returns null for non-integer values" {
            const val = Value{ .string = "hello" };
            try expect.to_be_null(val.asInteger());
        }
    };

    pub const asFloat = struct {
        test "returns float for float values" {
            const val = Value{ .float = 3.14 };
            try expect.approx_eq(val.asFloat().?, 3.14, 0.001);
        }

        test "returns null for non-float values" {
            const val = Value{ .integer = 42 };
            try expect.to_be_null(val.asFloat());
        }
    };

    pub const asBool = struct {
        test "returns bool for boolean values" {
            const val = Value{ .boolean = true };
            try expect.equal(val.asBool().?, true);
        }

        test "returns null for non-boolean values" {
            const val = Value{ .string = "true" };
            try expect.to_be_null(val.asBool());
        }
    };

    pub const asEnum = struct {
        test "returns string for enum literal values" {
            const val = Value{ .enum_literal = "dynamic" };
            try expect.equal(val.asEnum().?, "dynamic");
        }

        test "returns null for non-enum values" {
            const val = Value{ .string = "dynamic" };
            try expect.to_be_null(val.asEnum());
        }
    };
};

pub const ObjectSpec = struct {
    pub const get = struct {
        test "finds entry by key" {
            const entries = &[_]Value.Object.Entry{
                .{ .key = "x", .value = Value{ .integer = 10 } },
                .{ .key = "y", .value = Value{ .integer = 20 } },
            };
            const obj = Value.Object{ .entries = @constCast(entries) };
            const val = obj.get("y").?;
            try expect.equal(val.asInteger().?, 20);
        }

        test "returns null for missing key" {
            const obj = Value.Object{ .entries = &.{} };
            try expect.to_be_null(obj.get("missing"));
        }
    };

    pub const getString = struct {
        test "returns string value for key" {
            const entries = &[_]Value.Object.Entry{
                .{ .key = "name", .value = Value{ .string = "main" } },
            };
            const obj = Value.Object{ .entries = @constCast(entries) };
            try expect.equal(obj.getString("name").?, "main");
        }

        test "returns null when value is not a string" {
            const entries = &[_]Value.Object.Entry{
                .{ .key = "count", .value = Value{ .integer = 5 } },
            };
            const obj = Value.Object{ .entries = @constCast(entries) };
            try expect.to_be_null(obj.getString("count"));
        }
    };

    pub const getInteger = struct {
        test "returns integer value for key" {
            const entries = &[_]Value.Object.Entry{
                .{ .key = "x", .value = Value{ .integer = 42 } },
            };
            const obj = Value.Object{ .entries = @constCast(entries) };
            try expect.equal(obj.getInteger("x").?, 42);
        }
    };

    pub const getBool = struct {
        test "returns bool value for key" {
            const entries = &[_]Value.Object.Entry{
                .{ .key = "visible", .value = Value{ .boolean = true } },
            };
            const obj = Value.Object{ .entries = @constCast(entries) };
            try expect.equal(obj.getBool("visible").?, true);
        }
    };
};
