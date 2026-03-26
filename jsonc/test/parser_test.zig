const std = @import("std");
const expect = @import("zspec").expect;
const jsonc = @import("jsonc");
const JsoncParser = jsonc.JsoncParser;

/// Test-scoped arena — each test gets its own, freed via `defer`.
fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn parseWith(allocator: std.mem.Allocator, input: []const u8) !jsonc.Value {
    var p = JsoncParser.init(allocator, input);
    return p.parse();
}

pub const JsoncParserSpec = struct {
    pub const primitives = struct {
        test "parses integer" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "42");
            try expect.equal(val.asInteger().?, 42);
        }

        test "parses negative integer" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "-20");
            try expect.equal(val.asInteger().?, -20);
        }

        test "parses float" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "3.14");
            try expect.approx_eq(val.asFloat().?, 3.14, 0.001);
        }

        test "parses scientific notation" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "1.5E-3");
            try expect.approx_eq(val.asFloat().?, 0.0015, 0.0001);
        }

        test "parses true" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "true");
            try expect.equal(val.asBool().?, true);
        }

        test "parses false" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "false");
            try expect.equal(val.asBool().?, false);
        }

        test "parses null" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "null");
            try expect.equal(@as(bool, val == .null_value), true);
        }

        test "parses string" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\"hello world"
            );
            try expect.equal(val.asString().?, "hello world");
        }
    };

    pub const strings = struct {
        test "handles newline escape" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\"line1\nline2"
            );
            try expect.equal(val.asString().?, "line1\nline2");
        }

        test "handles tab escape" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\"\t"
            );
            try expect.equal(val.asString().?, "\t");
        }

        test "handles backslash escape" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\"\\"
            );
            try expect.equal(val.asString().?, "\\");
        }

        test "handles slash escape" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\"a\/b"
            );
            try expect.equal(val.asString().?, "a/b");
        }

        test "handles backspace escape" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\"\b"
            );
            const s = val.asString().?;
            try expect.equal(s[0], 0x08);
        }

        test "handles form feed escape" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\"\f"
            );
            const s = val.asString().?;
            try expect.equal(s[0], 0x0C);
        }

        test "rejects invalid escape" {
            var arena = testArena();
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\"\x"
            );
            try expect.err(jsonc.ParseError, p.parse(), error.InvalidEscape);
        }

        test "rejects unterminated string" {
            var arena = testArena();
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\"hello
            );
            try expect.err(jsonc.ParseError, p.parse(), error.UnterminatedString);
        }
    };

    pub const objects = struct {
        test "parses empty object" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "{}");
            try expect.equal(val.asObject().?.entries.len, 0);
        }

        test "parses object with string values" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{ "name": "main", "type": "scene" }
            );
            const obj = val.asObject().?;
            try expect.equal(obj.getString("name").?, "main");
            try expect.equal(obj.getString("type").?, "scene");
        }

        test "parses object with mixed types" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{ "name": "test", "x": 100, "scale": 0.5, "visible": true }
            );
            const obj = val.asObject().?;
            try expect.equal(obj.getString("name").?, "test");
            try expect.equal(obj.getInteger("x").?, 100);
            try expect.approx_eq(obj.getFloat("scale").?, 0.5, 0.001);
            try expect.equal(obj.getBool("visible").?, true);
        }

        test "parses nested objects" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{ "pos": { "x": 10, "y": 20 } }
            );
            const pos = val.asObject().?.getObject("pos").?;
            try expect.equal(pos.getInteger("x").?, 10);
            try expect.equal(pos.getInteger("y").?, 20);
        }

        test "supports trailing comma" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{ "a": 1, "b": 2, }
            );
            const obj = val.asObject().?;
            try expect.equal(obj.getInteger("a").?, 1);
            try expect.equal(obj.getInteger("b").?, 2);
        }

        test "rejects missing comma between properties" {
            var arena = testArena();
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\{ "a": 1 "b": 2 }
            );
            try expect.err(jsonc.ParseError, p.parse(), error.UnexpectedCharacter);
        }

        test "rejects missing colon" {
            var arena = testArena();
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\{ "a" 1 }
            );
            try expect.err(jsonc.ParseError, p.parse(), error.ExpectedColon);
        }
    };

    pub const arrays = struct {
        test "parses empty array" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "[]");
            try expect.equal(val.asArray().?.items.len, 0);
        }

        test "parses array of integers" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "[1, 2, 3]");
            const arr = val.asArray().?;
            try expect.equal(arr.len(), 3);
            try expect.equal(arr.items[0].asInteger().?, 1);
            try expect.equal(arr.items[2].asInteger().?, 3);
        }

        test "parses array of strings" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\["physics", "camera", "save"]
            );
            const arr = val.asArray().?;
            try expect.equal(arr.len(), 3);
            try expect.equal(arr.items[0].asString().?, "physics");
        }

        test "parses array of objects" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\[{ "x": 1 }, { "x": 2 }]
            );
            const arr = val.asArray().?;
            try expect.equal(arr.len(), 2);
            try expect.equal(arr.items[0].asObject().?.getInteger("x").?, 1);
        }

        test "supports trailing comma" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(), "[1, 2, 3,]");
            try expect.equal(val.asArray().?.len(), 3);
        }

        test "rejects missing comma between elements" {
            var arena = testArena();
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(), "[1 2]");
            try expect.err(jsonc.ParseError, p.parse(), error.UnexpectedCharacter);
        }
    };

    pub const comments = struct {
        test "skips line comments" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{
                \\    // This is a comment
                \\    "x": 10
                \\}
            );
            try expect.equal(val.asObject().?.getInteger("x").?, 10);
        }

        test "skips block comments" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{
                \\    /* multi
                \\       line */
                \\    "x": 10
                \\}
            );
            try expect.equal(val.asObject().?.getInteger("x").?, 10);
        }

        test "skips inline comments between values" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{
                \\    "a": 1, // first
                \\    "b": 2  // second
                \\}
            );
            const obj = val.asObject().?;
            try expect.equal(obj.getInteger("a").?, 1);
            try expect.equal(obj.getInteger("b").?, 2);
        }
    };

    pub const scenes = struct {
        test "parses full scene structure" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{
                \\    "name": "main",
                \\    "camera": { "x": 400, "y": 300 },
                \\    "entities": [
                \\        // Player
                \\        { "prefab": "player", "components": { "Position": { "x": 0, "y": 0 } } },
                \\        // Enemy
                \\        { "prefab": "enemy", "components": { "Position": { "x": 100, "y": 50 } } },
                \\    ],
                \\}
            );
            const scene = val.asObject().?;
            try expect.equal(scene.getString("name").?, "main");
            try expect.equal(scene.getObject("camera").?.getInteger("x").?, 400);

            const entities = scene.getArray("entities").?;
            try expect.equal(entities.len(), 2);
            try expect.equal(entities.items[0].asObject().?.getString("prefab").?, "player");
        }

        test "parses prefab with children" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{
                \\    "components": {
                \\        "Room": {},
                \\        "Workstation": { "type": "hydroponics" },
                \\    },
                \\    "children": [
                \\        { "prefab": "storage", "components": { "Position": { "x": 42, "y": -20 } } },
                \\    ],
                \\}
            );
            const root = val.asObject().?;
            const comps = root.getObject("components").?;
            try expect.equal(comps.getObject("Room").?.entries.len, 0);
            try expect.equal(comps.getObject("Workstation").?.getString("type").?, "hydroponics");

            const children = root.getArray("children").?;
            try expect.equal(children.len(), 1);
            const child_pos = children.items[0].asObject().?.getObject("components").?.getObject("Position").?;
            try expect.equal(child_pos.getInteger("x").?, 42);
            try expect.equal(child_pos.getInteger("y").?, -20);
        }

        test "parses scene with includes" {
            var arena = testArena();
            defer arena.deinit();
            const val = try parseWith(arena.allocator(),
                \\{
                \\    "name": "main",
                \\    "include": ["scenes/floor1.json", "scenes/floor2.json"],
                \\    "entities": [],
                \\}
            );
            const scene = val.asObject().?;
            const includes = scene.getArray("include").?;
            try expect.equal(includes.len(), 2);
            try expect.equal(includes.items[0].asString().?, "scenes/floor1.json");
        }
    };

    pub const location = struct {
        test "reports correct line and column" {
            var arena = testArena();
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(), "{\n  \"x\": }");
            const result = p.parse();
            try expect.err(jsonc.ParseError, result, error.UnexpectedCharacter);

            const loc = p.getLocation();
            try expect.equal(loc.line, 2);
        }
    };
};
