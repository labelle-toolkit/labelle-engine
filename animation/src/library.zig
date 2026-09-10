//! Immutable named definitions owned by a game session. Reloading a scene
//! borrows the same frames again; registration never invalidates a borrow.
const std = @import("std");
const Definition = @import("definition.zig").Definition;

pub const Library = struct {
    allocator: std.mem.Allocator,
    definitions: std.StringHashMap(*Definition),

    pub fn init(allocator: std.mem.Allocator) Library {
        return .{ .allocator = allocator, .definitions = .init(allocator) };
    }

    pub fn deinit(self: *Library) void {
        var it = self.definitions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.definitions.deinit();
        self.* = undefined;
    }

    /// Copies name and source. Duplicate names fail without changing the
    /// previous definition. Live definition replacement is a separate API.
    pub fn load(self: *Library, name: []const u8, source: []const u8) !void {
        if (name.len == 0) return error.EmptyAnimationName;
        if (self.definitions.contains(name)) return error.DuplicateAnimationDefinition;
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const def = try self.allocator.create(Definition);
        errdefer self.allocator.destroy(def);
        def.* = try Definition.parse(self.allocator, source);
        errdefer def.deinit();
        try self.definitions.put(key, def);
    }

    pub fn get(self: *const Library, name: []const u8) ?*const Definition {
        return self.definitions.get(name);
    }
};
