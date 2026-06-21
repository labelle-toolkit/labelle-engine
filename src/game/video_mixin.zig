/// Video mixin — in-engine video playback (FP#549).
///
/// Two layers:
///   * Low-level handle API forwarded from the backend (`openVideo`/`update`/
///     `draw`/`close`) for ad-hoc playback (an intro, a cutscene).
///   * Component layer: attach a `core.VideoComponent` to an entity (in code or
///     via a prefab/scene) and `renderVideos` plays it at the entity's world
///     position — so a project authors *multiple videos in multiple places*
///     declaratively, like sprites.

const core = @import("labelle-core");
const VideoComponent = core.VideoComponent;

/// Returns the video mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Video = Game.Video;
    const Entity = Game.EntityType;

    return struct {
        // ── Low-level handle API ───────────────────────────────────

        /// True iff the active backend can actually decode + play video.
        pub fn videoSupported(_: *Game) bool {
            return Video.supported();
        }

        /// Open a video by resource name/path. Returns a handle (0 = failure or
        /// unsupported); call `closeVideo` to release it.
        pub fn openVideo(_: *Game, path: []const u8) u32 {
            return Video.open(path);
        }

        /// Advance playback by `dt` seconds (decode the due frame, upload it,
        /// keep A/V in sync). Call once per frame while the video is on screen.
        pub fn updateVideo(_: *Game, id: u32, dt: f32) void {
            Video.update(id, dt);
        }

        /// Draw the current frame into the destination rect (engine design
        /// coordinates; the backend maps to the surface).
        pub fn drawVideo(_: *Game, id: u32, x: f32, y: f32, w: f32, h: f32) void {
            Video.draw(id, x, y, w, h);
        }

        /// True while the stream still has frames (false once it ends).
        pub fn videoPlaying(_: *Game, id: u32) bool {
            return Video.isPlaying(id);
        }

        /// Release the player and its decoder/texture/audio.
        pub fn closeVideo(_: *Game, id: u32) void {
            Video.close(id);
        }

        // ── Component layer (prefab-placeable) ─────────────────────

        /// Attach a video to an entity. The player opens lazily on the next
        /// `renderVideos`. The entity's `Position` anchors the draw rect.
        pub fn addVideo(self: *Game, entity: Entity, video: VideoComponent) void {
            self.ecs_backend.addComponent(entity, video);
        }

        /// Detach + close an entity's video.
        pub fn removeVideo(self: *Game, entity: Entity) void {
            if (self.ecs_backend.getComponent(entity, VideoComponent)) |vc| {
                if (vc.handle != 0) Video.close(vc.handle);
            }
            self.ecs_backend.removeComponent(entity, VideoComponent);
        }

        /// Play every `VideoComponent` entity: lazily open, advance, and draw at
        /// the entity's `Position` (× the component size, or the video's native
        /// size when 0). Call once per frame — inside the camera transform for
        /// world-space screens, or in screen space for HUD videos. No-op when the
        /// backend has no video.
        pub fn renderVideos(self: *Game, dt: f32) void {
            if (!Video.supported()) return;
            var v = self.ecs_backend.view(.{VideoComponent}, .{});
            defer v.deinit();
            while (v.next()) |entity| {
                const vc = self.ecs_backend.getComponent(entity, VideoComponent) orelse continue;
                if (vc.handle == 0) {
                    vc.handle = Video.open(vc.path);
                    if (vc.handle == 0) continue; // open failed; retry next frame
                }
                Video.update(vc.handle, dt);
                if (!vc.visible) continue;

                if (vc.fullscreen) {
                    // Background/backdrop — the backend fills the framebuffer
                    // using vc.fit (cover/contain/stretch), so Position + size
                    // are ignored.
                    Video.drawFullscreen(vc.handle, vc.fit);
                    continue;
                }

                const pos = self.getPosition(entity);
                var w = vc.width;
                var h = vc.height;
                if (w == 0 or h == 0) {
                    const d = Video.dimensions(vc.handle);
                    w = @floatFromInt(d.w);
                    h = @floatFromInt(d.h);
                }
                Video.draw(vc.handle, pos.x, pos.y, w, h);
            }
        }
    };
}
