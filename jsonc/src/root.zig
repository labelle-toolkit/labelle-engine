/// JSONC — JSON with Comments parser for labelle runtime scenes.
/// No external dependencies. Produces a generic Value tree consumed
/// by the engine's deserializer, scene loader, and hot reload system.
pub const Value = @import("value.zig").Value;
pub const Location = @import("value.zig").Location;
pub const JsoncParser = @import("parser.zig").JsoncParser;
pub const ParseError = @import("parser.zig").ParseError;
pub const HotReloader = @import("hot_reload.zig").HotReloader;

test {
    _ = @import("value.zig");
    _ = @import("parser.zig");
    _ = @import("hot_reload.zig");
}
