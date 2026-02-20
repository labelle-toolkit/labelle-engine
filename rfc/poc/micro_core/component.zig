/// Component lifecycle payload — passed to onAdd, onReady, onRemove callbacks.
/// Entity type is comptime so plugins aren't locked to any specific type.
pub fn ComponentPayload(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
        game_ptr: *anyopaque,

        pub fn getGame(self: @This(), comptime GameType: type) *GameType {
            return @ptrCast(@alignCast(self.game_ptr));
        }
    };
}
