# Clay UI Adapter for labelle-engine

This directory contains the Clay UI integration for the labelle-engine GUI system.

## Overview

**Clay** is a high-performance, declarative UI layout library written in C. It provides:
- Flexbox-style layout engine
- Retained-mode API (elements persist between frames)
- Zero dependencies
- Single-header C library
- Excellent performance characteristics

**Reference:** https://github.com/nicbarker/clay

## Architecture

```
┌─────────────────────────────────────────────┐
│  labelle-engine GUI System (gui/interface)  │
│  (Backend-agnostic GUI element types)       │
└──────────────────┬──────────────────────────┘
                   │
        ┌──────────┴──────────┐
        │  Clay Adapter       │
        │  (adapter.zig)      │
        └──────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │  Clay C Bindings    │
        │  (bindings.zig)     │
        └──────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │  Clay Layout Engine │
        │  (C library)        │
        └──────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │  Clay Renderer      │
        │  (renderer.zig)     │
        └──────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │  labelle-gfx        │
        │  (Rendering backend)│
        └─────────────────────┘
```

## Files

### `adapter.zig`
Implements the labelle-engine GUI backend interface for Clay.
- Translates labelle GUI elements to Clay layout calls
- Manages Clay context lifecycle
- Handles frame begin/end

### `bindings.zig`
Low-level C bindings to the Clay library.
- Extern function declarations
- C struct definitions
- Type conversions between Zig and C

### `renderer.zig`
Rendering interface between Clay and labelle-gfx.
- Defines render command types
- Translates Clay output to graphics API calls
- Handles different rendering backends (raylib, sokol, SDL, etc.)

## Integration Status

### Phase 1: Foundation ✅
- [x] Create directory structure
- [x] Define adapter interface
- [x] Define renderer interface
- [x] Create C bindings stubs
- [x] Document architecture

### Phase 2: Clay C Library Integration (TODO)
- [ ] Add Clay as a dependency in `build.zig.zon`
- [ ] Create C wrapper if needed
- [ ] Implement actual C bindings
- [ ] Test Clay initialization

### Phase 3: Adapter Implementation (TODO)
- [ ] Implement `init()` with Clay initialization
- [ ] Implement `beginFrame()` / `endFrame()`
- [ ] Implement element methods (button, label, etc.)
- [ ] Map labelle types to Clay layout configs
- [ ] Handle layout calculation

### Phase 4: Renderer Implementation (TODO)
- [ ] Implement raylib renderer
- [ ] Implement sokol renderer  
- [ ] Implement SDL renderer
- [ ] Test with each backend

### Phase 5: Integration & Testing (TODO)
- [ ] Add Clay to GUI backend enum in `interface.zig`
- [ ] Create example usage
- [ ] Write tests
- [ ] Performance benchmarks
- [ ] Documentation

## Usage Example (Future)

```zig
const gui = @import("gui");

// In build.zig.zon
.gui_backend = .clay,

// In game code
pub fn render() void {
    gui.beginFrame();
    defer gui.endFrame();
    
    // Panel container
    gui.beginPanel(.{
        .position = .{ .x = 100, .y = 100 },
        .size = .{ .width = 300, .height = 200 },
    });
    defer gui.endPanel();
    
    // Button inside panel
    if (gui.button(.{
        .text = "Click Me",
        .position = .{ .x = 10, .y = 10 },
    })) {
        std.log.info("Button clicked!", .{});
    }
    
    // Label
    gui.label(.{
        .text = "Score: 100",
        .position = .{ .x = 10, .y = 50 },
    });
}
```

## Benefits of Clay

1. **Performance**: Layout calculation is extremely fast
2. **Declarative**: Clean, readable UI code
3. **Flexible**: Supports complex layouts with flexbox-style rules
4. **Lightweight**: Minimal memory footprint
5. **Backend Agnostic**: Works with any rendering backend

## Comparison with Other Backends

| Feature | Clay | RayGUI | MicroUI |
|---------|------|--------|---------|
| Layout Engine | ✅ Flexbox | ❌ Manual | ❌ Manual |
| Performance | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| Declarative | ✅ Yes | ⚠️ Partial | ⚠️ Partial |
| Complexity | Low | Very Low | Low |
| Features | Rich | Basic | Basic |

## Next Steps

1. Add Clay C library to dependencies
2. Implement C bindings
3. Implement adapter methods
4. Create renderer for primary backend (raylib)
5. Write example and tests

## References

- Clay GitHub: https://github.com/nicbarker/clay
- Clay Documentation: https://nicbarker.com/clay
- labelle-engine GUI: `gui/interface.zig`
