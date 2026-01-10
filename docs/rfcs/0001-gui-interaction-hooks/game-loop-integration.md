# Game Loop Integration & Event Timing

**Issue**: GUI events (button clicks, slider changes) must not execute during script execution or ECS system updates to avoid conflicts and race conditions.

## Problem Statement

### Race Condition Scenario

```zig
// BAD: Event handler runs immediately during GUI rendering
pub fn button_clicked(payload: GuiHookPayload) void {
    // This runs DURING renderGui() call
    game.registry.add(entity, Component{ ... });  // ❌ Modifying ECS during iteration!
}

// Meanwhile in game loop:
while (game.isRunning()) {
    systems.run();        // ← System might be iterating ECS
    game.renderGui(...);  // ← Button click happens HERE
                          //   Handler modifies ECS → CONFLICT!
    re.endFrame();
}
```

### Specific Conflicts

1. **ECS Iteration Conflicts**
   - System iterating entities
   - Button handler adds/removes entity
   - Iterator invalidated → crash or undefined behavior

2. **Script Execution Conflicts**
   - Script callback running (e.g., `on_collision`)
   - GUI event fires during script
   - Both modify same component → data race

3. **Rendering Conflicts**
   - Render system building draw list
   - Button handler removes visual component
   - Draw list has dangling reference → crash

4. **Order Guarantees**
   - Multiple events in same frame (button + slider + checkbox)
   - Execution order must be deterministic
   - Current immediate dispatch → undefined order

## Solution: Event Queue with Deferred Processing

### Architecture

**Key Insight**: GUI events are **queued** during rendering, then **processed** at a safe point in the game loop.

```zig
// Game loop structure with safe event processing points
while (game.isRunning()) {
    // 1. Input processing
    input.update();
    
    // 2. Fixed update (physics, game logic)
    systems.fixedUpdate(dt);
    
    // 3. Process queued GUI events ← SAFE POINT #1
    //    (ECS updates done, no systems running)
    game.processGuiEvents(dispatcher);
    
    // 4. Variable update (animations, interpolation)
    systems.update(dt);
    
    // 5. Render
    re.beginFrame();
    re.render();
    
    // 6. GUI rendering (events QUEUED, not executed)
    game.renderGui(...);  // ← Events go into queue
    
    re.endFrame();
    
    // 7. Alternative: Process GUI events here ← SAFE POINT #2
    //    (after all rendering, before next frame)
    // game.processGuiEvents(dispatcher);
}
```

### Implementation

#### 1. Event Queue in Game Struct

```zig
// engine/game.zig
pub fn Game(comptime HooksDispatcher: type) type {
    return struct {
        // ... existing fields ...
        
        /// Queued GUI events (processed at safe point in game loop)
        gui_events: std.ArrayList(gui.GuiHookPayload),
        gui_event_mutex: std.Thread.Mutex = .{},  // Thread safety (optional)
        
        pub fn init(allocator: Allocator, config: GameConfig) !Self {
            return Self{
                // ...
                .gui_events = std.ArrayList(gui.GuiHookPayload).init(allocator),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.gui_events.deinit();
            // ...
        }
    };
}
```

#### 2. Queue Events During Rendering

```zig
// gui/clay/adapter.zig (and other backends)
pub fn button(self: *Self, btn: types.Button) bool {
    const clicked = clay.button(...);
    
    if (clicked and btn.id.len > 0) {
        // Queue event instead of dispatching immediately
        self.game.queueGuiEvent(.{
            .button_clicked = .{
                .element = btn,
                .mouse_pos = getMousePos(),
                .frame_number = self.game.frame_number,
            },
        }) catch |err| {
            std.log.err("Failed to queue GUI event: {}", .{err});
        };
    }
    
    return clicked;  // Still return immediately for immediate-mode pattern
}

// Game method for queueing
pub fn queueGuiEvent(self: *Self, payload: gui.GuiHookPayload) !void {
    // Optional: Thread safety for multi-threaded rendering
    self.gui_event_mutex.lock();
    defer self.gui_event_mutex.unlock();
    
    try self.gui_events.append(payload);
}
```

#### 3. Process Events at Safe Point

```zig
// engine/game.zig
pub fn processGuiEvents(self: *Self, comptime Dispatcher: type) void {
    // Thread safety (if needed)
    self.gui_event_mutex.lock();
    defer self.gui_event_mutex.unlock();
    
    // Process all queued events in FIFO order
    for (self.gui_events.items) |payload| {
        Dispatcher.emit(payload);
    }
    
    // Clear queue for next frame
    self.gui_events.clearRetainingCapacity();
}
```

#### 4. User Code (Game Loop)

```zig
// main.zig
const GuiDispatcher = labelle.gui.GuiHookDispatcher(GuiHooks);

while (game.isRunning()) {
    // Fixed update
    systems.fixedUpdate(dt);
    
    // ✅ SAFE POINT: Process GUI events
    //    (no systems running, safe to modify ECS)
    game.processGuiEvents(GuiDispatcher);
    
    // Variable update
    systems.update(dt);
    
    // Render (events queued, not executed)
    re.beginFrame();
    re.render();
    game.renderGui(Views, Scripts);  // ← Events go into queue
    re.endFrame();
}
```

## Event Processing Strategies

### Strategy A: Process After Fixed Update (Recommended)

```zig
while (game.isRunning()) {
    input.update();
    systems.fixedUpdate(dt);
    game.processGuiEvents(GuiDispatcher);  // ← HERE
    systems.update(dt);
    render();
}
```

**Pros**:
- Events processed before variable update
- UI changes visible in same frame
- Natural order (input → logic → UI response → render)

**Cons**:
- None significant

### Strategy B: Process After Rendering

```zig
while (game.isRunning()) {
    input.update();
    systems.fixedUpdate(dt);
    systems.update(dt);
    render();
    game.renderGui(...);
    game.processGuiEvents(GuiDispatcher);  // ← HERE
}
```

**Pros**:
- Events processed at very end of frame
- Clear separation (all rendering done first)

**Cons**:
- UI changes not visible until next frame
- One frame of latency for UI feedback

### Strategy C: Hybrid (Two Passes)

```zig
while (game.isRunning()) {
    input.update();
    
    // Process high-priority events (e.g., "Pause" button)
    game.processGuiEventsPriority(.high, GuiDispatcher);
    
    systems.fixedUpdate(dt);
    systems.update(dt);
    
    // Process normal events
    game.processGuiEvents(GuiDispatcher);
    
    render();
}
```

**Pros**:
- Critical buttons (pause, quit) processed immediately
- Most events processed at optimal time

**Cons**:
- More complex
- Requires priority system

## Guarantees

With this architecture:

1. ✅ **No ECS conflicts** - Events processed when no systems running
2. ✅ **Deterministic order** - FIFO queue ensures consistent behavior
3. ✅ **Thread safety** - Optional mutex for multi-threaded rendering
4. ✅ **Frame consistency** - All events from frame N processed together
5. ✅ **Immediate feedback** - Return value still available for same-frame UI updates

## FormBinder Integration

FormBinder works perfectly with deferred events:

```zig
const GuiHooks = struct {
    pub fn slider_changed(payload: gui.GuiHookPayload) void {
        // This runs at SAFE POINT, not during rendering
        const binder = MonsterBinder.init(&monster_form);
        binder.handleEvent(payload);  // ✅ Safe to modify form state
    }
    
    pub fn button_clicked(payload: gui.GuiHookPayload) void {
        if (std.mem.eql(u8, payload.button_clicked.element.id, "create_monster")) {
            // ✅ Safe to modify ECS here
            const entity = game.registry.create();
            game.registry.add(entity, Monster{
                .name = monster_form.name,
                .health = monster_form.health,
            });
        }
    }
};
```

## Alternative: Command Pattern

For very complex scenarios, consider command pattern:

```zig
const GuiCommand = union(enum) {
    create_monster: MonsterFormState,
    delete_entity: EntityId,
    toggle_pause: void,
};

const GuiHooks = struct {
    pub fn button_clicked(payload: gui.GuiHookPayload) void {
        // Queue command instead of executing immediately
        game.queueCommand(.{ .create_monster = monster_form });
    }
};

// Game loop
game.processCommands();  // ← Execute commands at safe point
```

**Use when**:
- Need undo/redo
- Need networked multiplayer (replay commands)
- Need complex transaction semantics

## Error Handling

```zig
pub fn processGuiEvents(self: *Self, comptime Dispatcher: type) void {
    for (self.gui_events.items) |payload| {
        // Catch panics in event handlers (optional)
        Dispatcher.emit(payload) catch |err| {
            std.log.err("GUI event handler error: {}", .{err});
            // Could queue error dialog, send telemetry, etc.
        };
    }
    self.gui_events.clearRetainingCapacity();
}
```

## Performance Considerations

**Memory**:
- Queue grows with events per frame
- Typical: 1-10 events/frame = ~1KB
- Worst case: 100 events/frame = ~10KB
- Use `clearRetainingCapacity()` to reuse allocations

**CPU**:
- Queue append: O(1) amortized
- Queue iteration: O(n) where n = events per frame
- Typical: <1µs per frame

**Allocation**:
- Pre-allocate queue capacity to avoid frame hitches:
  ```zig
  try self.gui_events.ensureTotalCapacity(32);  // Reserve space for 32 events
  ```

## Testing

```zig
test "GUI events processed at correct time" {
    var game = try Game.init(allocator, .{});
    defer game.deinit();
    
    var event_processed = false;
    
    const TestHooks = struct {
        pub fn button_clicked(payload: GuiHookPayload) void {
            event_processed = true;
        }
    };
    const TestDispatcher = gui.GuiHookDispatcher(TestHooks);
    
    // Queue event
    try game.queueGuiEvent(.{
        .button_clicked = .{
            .element = .{ .id = "test" },
            .mouse_pos = .{ .x = 0, .y = 0 },
        },
    });
    
    // Event not processed yet
    try testing.expect(!event_processed);
    
    // Process events
    game.processGuiEvents(TestDispatcher);
    
    // Event now processed
    try testing.expect(event_processed);
}
```

## Documentation Updates

Add to main RFC (Section 5: Game Loop Integration):

```markdown
### 5.1 Event Queue

GUI events are queued during rendering and processed at a safe point in the game loop.
This prevents conflicts with ECS iteration and script execution.

### 5.2 Processing Point

Call `game.processGuiEvents(Dispatcher)` after fixed update, before variable update:

    while (game.isRunning()) {
        systems.fixedUpdate(dt);
        game.processGuiEvents(GuiDispatcher);  // ← Here
        systems.update(dt);
        render();
    }

### 5.3 Event Order

Events are processed in FIFO order (first queued, first processed).
Multiple events from the same frame execute in the order they were queued.
```

## Summary

**Required Changes**:

1. ✅ Add `gui_events: ArrayList(GuiHookPayload)` to `Game` struct
2. ✅ Add `queueGuiEvent()` method to `Game`
3. ✅ Add `processGuiEvents(Dispatcher)` method to `Game`
4. ✅ Update backends to call `queueGuiEvent()` instead of dispatching immediately
5. ✅ Document safe processing point in game loop examples

**Benefits**:

- ✅ No ECS conflicts
- ✅ No script conflicts  
- ✅ Deterministic event order
- ✅ Thread-safe (with optional mutex)
- ✅ Clean separation of concerns (queue vs. process)

**Recommendation**: Implement event queue in Week 1 of full implementation, before backend integration.
