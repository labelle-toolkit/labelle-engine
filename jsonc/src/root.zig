/// JSONC — JSON with Comments parser and Value deserializer for labelle runtime scenes.
/// No external dependencies. Produces a generic Value tree and deserializes
/// it into typed Zig structs via comptime-generated mappings.
pub const Value = @import("value.zig").Value;
pub const Location = @import("value.zig").Location;
pub const JsoncParser = @import("parser.zig").JsoncParser;
pub const ParseError = @import("parser.zig").ParseError;

const deserialize_mod = @import("deserialize.zig");
pub const deserialize = deserialize_mod.deserialize;
pub const DeserializeError = deserialize_mod.DeserializeError;
pub const ComponentRegistry = deserialize_mod.ComponentRegistry;
pub const TypeErasedComponent = deserialize_mod.TypeErasedComponent;
pub const component = deserialize_mod.component;

pub const scene_loader = @import("scene_loader.zig");

test {
    _ = @import("value.zig");
    _ = @import("parser.zig");
    _ = @import("deserialize.zig");
    _ = @import("scene_loader.zig");
}
