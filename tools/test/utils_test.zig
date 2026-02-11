const std = @import("std");
const zspec = @import("zspec");
const utils = @import("../generator/utils.zig");

test {
    zspec.runAll(@This());
}

pub const SANITIZE_ZIG_IDENTIFIER = struct {
    test "passes through simple name" {
        const result = try utils.sanitizeZigIdentifier(std.testing.allocator, "hello");
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    test "replaces hyphens with underscores" {
        const result = try utils.sanitizeZigIdentifier(std.testing.allocator, "my-game-name");
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("my_game_name", result);
    }

    test "prepends underscore for leading digit" {
        const result = try utils.sanitizeZigIdentifier(std.testing.allocator, "3dworld");
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("_3dworld", result);
    }

    test "strips invalid characters" {
        const result = try utils.sanitizeZigIdentifier(std.testing.allocator, "hello@world!");
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("helloworld", result);
    }

    test "returns error for empty string" {
        const result = utils.sanitizeZigIdentifier(std.testing.allocator, "");
        try std.testing.expectError(error.InvalidIdentifier, result);
    }

    test "returns error for all invalid chars" {
        const result = utils.sanitizeZigIdentifier(std.testing.allocator, "@#$%");
        try std.testing.expectError(error.InvalidIdentifier, result);
    }

    test "preserves underscores" {
        const result = try utils.sanitizeZigIdentifier(std.testing.allocator, "my_game");
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("my_game", result);
    }
};

pub const TO_PASCAL_CASE = struct {
    test "converts snake_case" {
        const result = try utils.toPascalCase("task_workstation");
        try std.testing.expectEqualStrings("TaskWorkstation", result.buf[0..result.len]);
    }

    test "capitalizes single word" {
        const result = try utils.toPascalCase("hello");
        try std.testing.expectEqualStrings("Hello", result.buf[0..result.len]);
    }

    test "handles multiple underscores" {
        const result = try utils.toPascalCase("a_b_c_d");
        try std.testing.expectEqualStrings("ABCD", result.buf[0..result.len]);
    }

    test "handles already capitalized" {
        const result = try utils.toPascalCase("Hello");
        try std.testing.expectEqualStrings("Hello", result.buf[0..result.len]);
    }
};

pub const IS_VALID_IDENTIFIER_CHAR = struct {
    test "accepts alphanumeric" {
        try std.testing.expect(utils.isValidIdentifierChar('a'));
        try std.testing.expect(utils.isValidIdentifierChar('Z'));
        try std.testing.expect(utils.isValidIdentifierChar('5'));
    }

    test "accepts underscore" {
        try std.testing.expect(utils.isValidIdentifierChar('_'));
    }

    test "rejects hyphen" {
        try std.testing.expect(!utils.isValidIdentifierChar('-'));
    }

    test "rejects special chars" {
        try std.testing.expect(!utils.isValidIdentifierChar('@'));
        try std.testing.expect(!utils.isValidIdentifierChar(' '));
        try std.testing.expect(!utils.isValidIdentifierChar('.'));
    }
};
