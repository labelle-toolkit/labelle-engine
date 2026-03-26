/// JSONC (JSON with Comments) parser.
/// Parses JSON with // line comments, /* */ block comments, and trailing commas
/// into the same Value tree as the ZON parser — so the rest of the pipeline
/// (deserialize, scene_loader, hot_reload) works unchanged.
const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const JsoncParser = struct {
    source: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) JsoncParser {
        return .{
            .source = source,
            .pos = 0,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *JsoncParser) ParseError!Value {
        self.skipWhitespaceAndComments();
        const value = try self.parseValue();
        self.skipWhitespaceAndComments();
        return value;
    }

    pub fn parseFile(allocator: Allocator, path: []const u8) !Value {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const source = try file.readToEndAlloc(allocator, 1024 * 1024);
        var p = JsoncParser.init(allocator, source);
        return p.parse();
    }

    pub fn getLocation(self: *const JsoncParser) value_mod.Location {
        var line: usize = 1;
        var col: usize = 1;
        for (self.source[0..self.pos]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .column = col, .offset = self.pos };
    }

    fn parseValue(self: *JsoncParser) ParseError!Value {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) return error.UnexpectedEof;

        const c = self.source[self.pos];

        if (c == '{') return self.parseObject();
        if (c == '[') return self.parseArray();
        if (c == '"') return self.parseString();
        if (c == '-' or std.ascii.isDigit(c)) return self.parseNumber();
        if (std.ascii.isAlphabetic(c)) return self.parseKeyword();

        return error.UnexpectedCharacter;
    }

    fn parseObject(self: *JsoncParser) ParseError!Value {
        self.pos += 1; // consume '{'
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) return error.UnexpectedEof;
        if (self.source[self.pos] == '}') {
            self.pos += 1;
            return Value{ .object = .{ .entries = &.{} } };
        }

        var entries: std.ArrayList(Value.Object.Entry) = .{};

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.source.len) return error.UnexpectedEof;

            // Trailing comma support: check for '}' after comma
            if (self.source[self.pos] == '}') {
                self.pos += 1;
                return Value{ .object = .{ .entries = try entries.toOwnedSlice(self.allocator) } };
            }

            // Key (must be a string)
            if (self.source[self.pos] != '"') return error.UnexpectedCharacter;
            const key_val = try self.parseString();
            const key = key_val.asString() orelse return error.UnexpectedCharacter;

            self.skipWhitespaceAndComments();

            // Expect ':'
            if (self.pos >= self.source.len or self.source[self.pos] != ':') return error.ExpectedColon;
            self.pos += 1;

            self.skipWhitespaceAndComments();

            const value = try self.parseValue();
            try entries.append(self.allocator, .{ .key = key, .value = value });

            self.skipWhitespaceAndComments();

            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }
    }

    fn parseArray(self: *JsoncParser) ParseError!Value {
        self.pos += 1; // consume '['
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) return error.UnexpectedEof;
        if (self.source[self.pos] == ']') {
            self.pos += 1;
            return Value{ .array = .{ .items = &.{} } };
        }

        var items: std.ArrayList(Value) = .{};

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.source.len) return error.UnexpectedEof;

            // Trailing comma support
            if (self.source[self.pos] == ']') {
                self.pos += 1;
                return Value{ .array = .{ .items = try items.toOwnedSlice(self.allocator) } };
            }

            const value = try self.parseValue();
            try items.append(self.allocator, value);

            self.skipWhitespaceAndComments();

            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }
    }

    fn parseString(self: *JsoncParser) ParseError!Value {
        self.pos += 1; // consume opening '"'

        var result: std.ArrayList(u8) = .{};

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.pos += 1;
                return Value{ .string = try result.toOwnedSlice(self.allocator) };
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.source.len) return error.InvalidEscape;
                const escaped = self.source[self.pos];
                switch (escaped) {
                    'n' => try result.append(self.allocator, '\n'),
                    't' => try result.append(self.allocator, '\t'),
                    'r' => try result.append(self.allocator, '\r'),
                    '\\' => try result.append(self.allocator, '\\'),
                    '"' => try result.append(self.allocator, '"'),
                    '/' => try result.append(self.allocator, '/'),
                    else => return error.InvalidEscape,
                }
                self.pos += 1;
                continue;
            }
            try result.append(self.allocator, c);
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    fn parseNumber(self: *JsoncParser) ParseError!Value {
        const start = self.pos;
        var is_float = false;

        if (self.pos < self.source.len and self.source[self.pos] == '-') {
            self.pos += 1;
        }

        if (self.pos >= self.source.len or !std.ascii.isDigit(self.source[self.pos])) {
            return error.InvalidNumber;
        }
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.pos += 1;
        }

        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            if (self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1])) {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
        }

        // Exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
        }

        const num_str = self.source[start..self.pos];

        if (is_float) {
            const f = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
            return Value{ .float = f };
        } else {
            const i = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidNumber;
            return Value{ .integer = i };
        }
    }

    fn parseKeyword(self: *JsoncParser) ParseError!Value {
        const start = self.pos;
        while (self.pos < self.source.len and std.ascii.isAlphabetic(self.source[self.pos])) {
            self.pos += 1;
        }
        const word = self.source[start..self.pos];

        if (std.mem.eql(u8, word, "true")) return Value{ .boolean = true };
        if (std.mem.eql(u8, word, "false")) return Value{ .boolean = false };
        if (std.mem.eql(u8, word, "null")) return Value{ .null_value = {} };

        return error.UnexpectedCharacter;
    }

    fn skipWhitespaceAndComments(self: *JsoncParser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
                continue;
            }
            // Line comment
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            // Block comment
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.source.len) {
                    if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }
};

pub const ParseError = error{
    UnexpectedCharacter,
    UnexpectedEof,
    InvalidNumber,
    InvalidEscape,
    UnterminatedString,
    ExpectedColon,
    OutOfMemory,
};

// ======================== Tests ========================

test "parse empty object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(), "{}");
    const val = try p.parse();
    try std.testing.expectEqual(@as(usize, 0), val.asObject().?.entries.len);
}

test "parse empty array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(), "[]");
    const val = try p.parse();
    try std.testing.expectEqual(@as(usize, 0), val.asArray().?.items.len);
}

test "parse simple object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{ "x": 100, "y": 200 }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(@as(i64, 100), obj.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 200), obj.getInteger("y").?);
}

test "parse negative numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{ "x": -20, "y": 0 }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(@as(i64, -20), obj.getInteger("x").?);
}

test "parse floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{ "restitution": 0.9, "friction": 0.1 }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), obj.getFloat("restitution").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), obj.getFloat("friction").?, 0.001);
}

test "parse string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{ "name": "main", "prefab": "worker" }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqualStrings("main", obj.getString("name").?);
    try std.testing.expectEqualStrings("worker", obj.getString("prefab").?);
}

test "parse booleans and null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{ "visible": true, "hidden": false, "data": null }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(true, obj.getBool("visible").?);
    try std.testing.expectEqual(false, obj.getBool("hidden").?);
    try std.testing.expect(obj.get("data").? == .null_value);
}

test "parse array of strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\["pathfinder_bridge", "camera_control", "save_load"]
    );
    const val = try p.parse();
    const arr = val.asArray().?;
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expectEqualStrings("pathfinder_bridge", arr.items[0].asString().?);
    try std.testing.expectEqualStrings("save_load", arr.items[2].asString().?);
}

test "parse nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    "components": {
        \\        "Position": { "x": 50, "y": 100 }
        \\    }
        \\}
    );
    const val = try p.parse();
    const pos = val.asObject().?.getObject("components").?.getObject("Position").?;
    try std.testing.expectEqual(@as(i64, 50), pos.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 100), pos.getInteger("y").?);
}

test "parse line comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    // Scene name
        \\    "name": "main",
        \\    // Entity count will grow
        \\    "count": 42
        \\}
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqualStrings("main", obj.getString("name").?);
    try std.testing.expectEqual(@as(i64, 42), obj.getInteger("count").?);
}

test "parse block comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    /* This is a
        \\       multi-line comment */
        \\    "x": 10
        \\}
    );
    const val = try p.parse();
    try std.testing.expectEqual(@as(i64, 10), val.asObject().?.getInteger("x").?);
}

test "parse trailing commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    "a": 1,
        \\    "b": 2,
        \\}
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(@as(i64, 1), obj.getInteger("a").?);
    try std.testing.expectEqual(@as(i64, 2), obj.getInteger("b").?);
}

test "parse trailing commas in arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\[1, 2, 3,]
    );
    const val = try p.parse();
    try std.testing.expectEqual(@as(usize, 3), val.asArray().?.len());
}

test "parse scene in JSONC format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    "name": "main",
        \\    "scripts": [
        \\        "pathfinder_bridge",
        \\        "worker_movement",
        \\        "production_system",
        \\        "camera_control",
        \\    ],
        \\    "entities": [
        \\        // Ship
        \\        { "prefab": "ship_carcase", "components": { "Position": { "x": 0, "y": 0 } } },
        \\        // Rooms
        \\        { "prefab": "water_well", "components": { "Position": { "x": 0, "y": 0 } } },
        \\        { "prefab": "hydroponics", "components": { "Position": { "x": 156, "y": 0 } } },
        \\        // Workers
        \\        { "prefab": "worker", "components": { "Position": { "x": 0, "y": 0 } } },
        \\        { "prefab": "worker", "components": { "Position": { "x": 50, "y": 0 } } },
        \\    ],
        \\}
    );
    const val = try p.parse();
    const s = val.asObject().?;

    try std.testing.expectEqualStrings("main", s.getString("name").?);

    const scripts = s.getArray("scripts").?;
    try std.testing.expectEqual(@as(usize, 4), scripts.len());
    try std.testing.expectEqualStrings("pathfinder_bridge", scripts.items[0].asString().?);

    const entities = s.getArray("entities").?;
    try std.testing.expectEqual(@as(usize, 5), entities.len());
    try std.testing.expectEqualStrings("ship_carcase", entities.items[0].asObject().?.getString("prefab").?);
    try std.testing.expectEqualStrings("worker", entities.items[3].asObject().?.getString("prefab").?);
}

test "parse prefab in JSONC format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    "components": {
        \\        "Workstation": {
        \\            "workstation_type": "hydroponics",
        \\            "process_duration": 3,
        \\        },
        \\        "TendableWorkstation": {
        \\            "maintenance_per_work": 0.3,
        \\            "max_level": 5,
        \\        },
        \\    },
        \\    "children": [
        \\        {
        \\            "components": {
        \\                "Position": { "x": 42, "y": -20 },
        \\                "Storage": { "accepted_items": { "Water": true } },
        \\                "Eis": {},
        \\            },
        \\        },
        \\    ],
        \\}
    );
    const val = try p.parse();
    const root = val.asObject().?;
    const components = root.getObject("components").?;

    const ws = components.getObject("Workstation").?;
    try std.testing.expectEqualStrings("hydroponics", ws.getString("workstation_type").?);
    try std.testing.expectEqual(@as(i64, 3), ws.getInteger("process_duration").?);

    const tws = components.getObject("TendableWorkstation").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), tws.getFloat("maintenance_per_work").?, 0.001);

    const children = root.getArray("children").?;
    try std.testing.expectEqual(@as(usize, 1), children.len());
    const child_comps = children.items[0].asObject().?.getObject("components").?;
    const pos = child_comps.getObject("Position").?;
    try std.testing.expectEqual(@as(i64, 42), pos.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, -20), pos.getInteger("y").?);
    try std.testing.expect(child_comps.getObject("Eis").?.entries.len == 0);
}

test "parse bouncing ball scene in JSONC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    "name": "main",
        \\    "scripts": ["bouncing_ball"],
        \\    "camera": { "x": 400, "y": 300 },
        \\    "entities": [
        \\        // Floor
        \\        {
        \\            "components": {
        \\                "Position": { "x": 400, "y": 580 },
        \\                "Shape": {
        \\                    "shape": { "rectangle": { "width": 780, "height": 20 } },
        \\                    "color": { "r": 80, "g": 80, "b": 100 },
        \\                },
        \\                "RigidBody": { "body_type": "static" },
        \\            },
        \\        },
        \\        // Ball
        \\        {
        \\            "components": {
        \\                "Position": { "x": 400, "y": 150 },
        \\                "Shape": {
        \\                    "shape": { "circle": { "radius": 30 } },
        \\                    "color": { "r": 255, "g": 100, "b": 100 },
        \\                },
        \\                "RigidBody": { "body_type": "dynamic" },
        \\                "Collider": {
        \\                    "shape": { "circle": { "radius": 30 } },
        \\                    "restitution": 0.9,
        \\                    "friction": 0.1,
        \\                },
        \\            },
        \\        },
        \\    ],
        \\}
    );
    const val = try p.parse();
    const s = val.asObject().?;

    try std.testing.expectEqualStrings("main", s.getString("name").?);
    try std.testing.expectApproxEqAbs(
        @as(f64, 400),
        @as(f64, @floatFromInt(s.getObject("camera").?.getInteger("x").?)),
        0.001,
    );

    const entities = s.getArray("entities").?;
    try std.testing.expectEqual(@as(usize, 2), entities.len());

    const floor = entities.items[0].asObject().?.getObject("components").?;
    try std.testing.expectEqualStrings("static", floor.getObject("RigidBody").?.getString("body_type").?);

    const ball = entities.items[1].asObject().?.getObject("components").?;
    try std.testing.expectEqualStrings("dynamic", ball.getObject("RigidBody").?.getString("body_type").?);
    const collider = ball.getObject("Collider").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), collider.getFloat("restitution").?, 0.001);
}

test "parse scene with includes in JSONC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{
        \\    "name": "main",
        \\    "scripts": ["camera_control"],
        \\    "include": [
        \\        "scenes/floor1_rooms.json",
        \\        "scenes/floor2_rooms.json",
        \\        "scenes/workers.json",
        \\    ],
        \\    "entities": [
        \\        { "components": { "GameManager": {} } },
        \\    ],
        \\}
    );
    const val = try p.parse();
    const s = val.asObject().?;

    const includes = s.getArray("include").?;
    try std.testing.expectEqual(@as(usize, 3), includes.len());
    try std.testing.expectEqualStrings("scenes/floor1_rooms.json", includes.items[0].asString().?);

    const entities = s.getArray("entities").?;
    try std.testing.expectEqual(@as(usize, 1), entities.len());
}

test "parse string escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{ "path": "scenes\/main.json", "msg": "line1\nline2", "tab": "\t" }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqualStrings("scenes/main.json", obj.getString("path").?);
    try std.testing.expectEqualStrings("line1\nline2", obj.getString("msg").?);
    try std.testing.expectEqualStrings("\t", obj.getString("tab").?);
}

test "parse exponent numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = JsoncParser.init(arena.allocator(),
        \\{ "a": 1e2, "b": 1.5E-3, "c": -2e+1 }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), obj.getFloat("a").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0015), obj.getFloat("b").?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, -20.0), obj.getFloat("c").?, 0.001);
}
