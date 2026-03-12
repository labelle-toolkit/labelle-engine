/// Animation component — comptime-polymorphic sprite animation.
/// Pure state machine: frame advancement, looping, sprite name generation.
/// No rendering fields (tint, pivot, scale, etc.) — those live in the renderer's
/// component or as separate ECS components.
///
/// Usage:
///   const CharAnim = enum { idle, walk, attack,
///       pub fn config(self: @This()) AnimConfig {
///           return switch (self) {
///               .idle => .{ .frames = 4, .frame_duration = 0.2 },
///               .walk => .{ .frames = 6, .frame_duration = 0.1 },
///               .attack => .{ .frames = 5, .frame_duration = 0.08, .looping = false },
///           };
///       }
///   };
///   var anim = Animation(CharAnim).init(.idle);
///   anim.update(dt);
///   const name = anim.getSpriteName("player", &buf);

const std = @import("std");

/// Per-animation configuration — frame count, duration, looping.
pub const AnimConfig = struct {
    frames: u32,
    frame_duration: f32,
    looping: bool = true,
};

/// Default animation types for quick prototyping.
pub const DefaultAnimationType = enum {
    idle,
    walk,
    run,
    jump,
    fall,
    attack,
    hurt,
    die,

    pub fn config(self: @This()) AnimConfig {
        return switch (self) {
            .idle => .{ .frames = 4, .frame_duration = 0.2 },
            .walk => .{ .frames = 6, .frame_duration = 0.1 },
            .run => .{ .frames = 8, .frame_duration = 0.08 },
            .jump => .{ .frames = 4, .frame_duration = 0.1, .looping = false },
            .fall => .{ .frames = 2, .frame_duration = 0.15 },
            .attack => .{ .frames = 6, .frame_duration = 0.08, .looping = false },
            .hurt => .{ .frames = 2, .frame_duration = 0.1, .looping = false },
            .die => .{ .frames = 6, .frame_duration = 0.15, .looping = false },
        };
    }
};

/// Sprite animation component. AnimType must be an enum with `config() -> AnimConfig`.
pub fn Animation(comptime AnimType: type) type {
    comptime {
        if (@typeInfo(AnimType) != .@"enum") @compileError("AnimType must be an enum");
        if (!@hasDecl(AnimType, "config")) @compileError("AnimType must define config() -> AnimConfig");
    }

    return struct {
        const Self = @This();

        anim_type: AnimType,
        frame: u32 = 0,
        elapsed_time: f32 = 0,
        playing: bool = true,
        sprite_variant: []const u8 = "",
        on_complete: ?*const fn () void = null,

        pub fn init(anim_type: AnimType) Self {
            return .{ .anim_type = anim_type };
        }

        pub fn initWithVariant(anim_type: AnimType, variant: []const u8) Self {
            return .{ .anim_type = anim_type, .sprite_variant = variant };
        }

        /// Advance animation by delta time.
        pub fn update(self: *Self, dt: f32) void {
            if (!self.playing) return;

            const cfg = self.anim_type.config();
            self.elapsed_time += dt;

            while (self.elapsed_time >= cfg.frame_duration) {
                self.elapsed_time -= cfg.frame_duration;
                self.frame += 1;

                if (self.frame >= cfg.frames) {
                    if (cfg.looping) {
                        self.frame = 0;
                    } else {
                        self.frame = cfg.frames - 1;
                        self.playing = false;
                        if (self.on_complete) |cb| cb();
                        return;
                    }
                }
            }
        }

        /// Switch to a new animation (resets frame).
        pub fn play(self: *Self, anim_type: AnimType) void {
            self.anim_type = anim_type;
            self.frame = 0;
            self.elapsed_time = 0;
            self.playing = true;
        }

        pub fn pause(self: *Self) void {
            self.playing = false;
        }

        pub fn unpause(self: *Self) void {
            self.playing = true;
        }

        pub fn reset(self: *Self) void {
            self.frame = 0;
            self.elapsed_time = 0;
            self.playing = true;
        }

        pub fn getConfig(self: *const Self) AnimConfig {
            return self.anim_type.config();
        }

        /// Returns 1-based frame number.
        pub fn getFrameNumber(self: *const Self) u32 {
            return self.frame + 1;
        }

        /// Get animation name from enum tag.
        pub fn getAnimationName(self: *const Self) []const u8 {
            return @tagName(self.anim_type);
        }

        /// Generate sprite name: "{prefix}/{anim_name}_{frame:04}" (1-indexed).
        pub fn getSpriteName(
            self: *const Self,
            comptime prefix: []const u8,
            buffer: []u8,
        ) []const u8 {
            const frame_1 = self.frame + 1;
            const name = @tagName(self.anim_type);
            const result = std.fmt.bufPrint(buffer, prefix ++ "/{s}_{d:0>4}", .{ name, frame_1 }) catch return "";
            return result;
        }

        /// Generate sprite name with custom formatter.
        pub fn getSpriteNameCustom(
            self: *const Self,
            buffer: []u8,
            formatter: *const fn (anim_name: []const u8, frame: u32, buf: []u8) []const u8,
        ) []const u8 {
            return formatter(@tagName(self.anim_type), self.frame + 1, buffer);
        }

        /// Generate sprite name with entity variant.
        pub fn getSpriteNameWithVariant(
            self: *const Self,
            buffer: []u8,
            formatter: *const fn (anim_name: []const u8, variant: []const u8, frame: u32, buf: []u8) []const u8,
        ) []const u8 {
            return formatter(@tagName(self.anim_type), self.sprite_variant, self.frame + 1, buffer);
        }
    };
}
