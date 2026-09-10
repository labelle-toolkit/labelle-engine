//! Renderer/ECS-independent animation authoring. No dependency on the engine.
pub const Library = @import("library.zig").Library;
pub const Definition = @import("definition.zig").Definition;
pub const Clip = @import("definition.zig").Clip;
pub const FrameRange = @import("frame_range.zig").FrameRange;
pub const Marker = @import("marker.zig").Marker;
pub const MarkerCursor = @import("marker_cursor.zig").MarkerCursor;
pub const Occurrence = @import("marker_cursor.zig").Occurrence;
pub const BoundaryMode = @import("marker_cursor.zig").BoundaryMode;
