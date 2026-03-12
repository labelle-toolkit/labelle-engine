/// Audio mixin — sound and music forwarding.

/// Returns the audio forwarding mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Audio = Game.Audio;

    return struct {
        pub fn playSound(_: *Game, id: u32) void {
            Audio.playSound(id);
        }

        pub fn stopSound(_: *Game, id: u32) void {
            Audio.stopSound(id);
        }

        pub fn setVolume(_: *Game, vol: f32) void {
            Audio.setVolume(vol);
        }
    };
}
