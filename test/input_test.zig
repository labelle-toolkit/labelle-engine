const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const input_mod = @import("input");

test {
    zspec.runAll(@This());
}

pub const INPUT_TYPES = struct {
    pub const KEYBOARD_KEY = struct {
        test "has common keys defined" {
            // Letters
            try expect.equal(@intFromEnum(engine.KeyboardKey.a), 65);
            try expect.equal(@intFromEnum(engine.KeyboardKey.z), 90);

            // Numbers
            try expect.equal(@intFromEnum(engine.KeyboardKey.zero), 48);
            try expect.equal(@intFromEnum(engine.KeyboardKey.nine), 57);

            // Special keys
            try expect.equal(@intFromEnum(engine.KeyboardKey.space), 32);
            try expect.equal(@intFromEnum(engine.KeyboardKey.escape), 256);
            try expect.equal(@intFromEnum(engine.KeyboardKey.enter), 257);
        }

        test "has arrow keys defined" {
            try expect.equal(@intFromEnum(engine.KeyboardKey.up), 265);
            try expect.equal(@intFromEnum(engine.KeyboardKey.down), 264);
            try expect.equal(@intFromEnum(engine.KeyboardKey.left), 263);
            try expect.equal(@intFromEnum(engine.KeyboardKey.right), 262);
        }

        test "has function keys defined" {
            try expect.equal(@intFromEnum(engine.KeyboardKey.f1), 290);
            try expect.equal(@intFromEnum(engine.KeyboardKey.f12), 301);
        }

        test "has modifier keys defined" {
            try expect.equal(@intFromEnum(engine.KeyboardKey.left_shift), 340);
            try expect.equal(@intFromEnum(engine.KeyboardKey.left_control), 341);
            try expect.equal(@intFromEnum(engine.KeyboardKey.left_alt), 342);
        }
    };

    pub const MOUSE_BUTTON = struct {
        test "has common buttons defined" {
            try expect.equal(@intFromEnum(engine.MouseButton.left), 0);
            try expect.equal(@intFromEnum(engine.MouseButton.right), 1);
            try expect.equal(@intFromEnum(engine.MouseButton.middle), 2);
        }

        test "has extended buttons defined" {
            try expect.equal(@intFromEnum(engine.MouseButton.side), 3);
            try expect.equal(@intFromEnum(engine.MouseButton.extra), 4);
            try expect.equal(@intFromEnum(engine.MouseButton.forward), 5);
            try expect.equal(@intFromEnum(engine.MouseButton.back), 6);
        }
    };

    pub const MOUSE_POSITION = struct {
        test "can create mouse position" {
            const pos = engine.MousePosition{ .x = 100.0, .y = 200.0 };
            try expect.equal(pos.x, 100.0);
            try expect.equal(pos.y, 200.0);
        }

        test "has default values of zero" {
            const pos = engine.MousePosition{};
            try expect.equal(pos.x, 0.0);
            try expect.equal(pos.y, 0.0);
        }
    };
};

pub const INPUT_INTERFACE = struct {
    pub const TYPE_EXPORTS = struct {
        test "Input type is exported from engine" {
            const T = engine.Input;
            try expect.toBeTrue(@typeName(T).len > 0);
        }

        test "Input has Implementation type" {
            try expect.toBeTrue(@hasDecl(engine.Input, "Implementation"));
        }

        test "Input has init method" {
            try expect.toBeTrue(@hasDecl(engine.Input, "init"));
        }

        test "Input has deinit method" {
            try expect.toBeTrue(@hasDecl(engine.Input, "deinit"));
        }

        test "Input has beginFrame method" {
            try expect.toBeTrue(@hasDecl(engine.Input, "beginFrame"));
        }

        test "Input has keyboard methods" {
            try expect.toBeTrue(@hasDecl(engine.Input, "isKeyDown"));
            try expect.toBeTrue(@hasDecl(engine.Input, "isKeyPressed"));
            try expect.toBeTrue(@hasDecl(engine.Input, "isKeyReleased"));
        }

        test "Input has mouse button methods" {
            try expect.toBeTrue(@hasDecl(engine.Input, "isMouseButtonDown"));
            try expect.toBeTrue(@hasDecl(engine.Input, "isMouseButtonPressed"));
            try expect.toBeTrue(@hasDecl(engine.Input, "isMouseButtonReleased"));
        }

        test "Input has mouse position methods" {
            try expect.toBeTrue(@hasDecl(engine.Input, "getMousePosition"));
            try expect.toBeTrue(@hasDecl(engine.Input, "getMouseWheelMove"));
        }
    };

    pub const INITIALIZATION = struct {
        test "can init and deinit Input" {
            var input = engine.Input.init();
            defer input.deinit();
            // If we get here without error, init/deinit work
            try expect.toBeTrue(true);
        }

        test "can call beginFrame" {
            var input = engine.Input.init();
            defer input.deinit();
            input.beginFrame();
            try expect.toBeTrue(true);
        }
    };

    pub const KEYBOARD_INPUT = struct {
        test "isKeyDown returns bool" {
            var input = engine.Input.init();
            defer input.deinit();
            const result = input.isKeyDown(.space);
            try expect.toBeTrue(@TypeOf(result) == bool);
        }

        test "isKeyPressed returns bool" {
            var input = engine.Input.init();
            defer input.deinit();
            const result = input.isKeyPressed(.space);
            try expect.toBeTrue(@TypeOf(result) == bool);
        }

        test "isKeyReleased returns bool" {
            var input = engine.Input.init();
            defer input.deinit();
            const result = input.isKeyReleased(.space);
            try expect.toBeTrue(@TypeOf(result) == bool);
        }
    };

    pub const MOUSE_INPUT = struct {
        test "isMouseButtonDown returns bool" {
            var input = engine.Input.init();
            defer input.deinit();
            const result = input.isMouseButtonDown(.left);
            try expect.toBeTrue(@TypeOf(result) == bool);
        }

        test "isMouseButtonPressed returns bool" {
            var input = engine.Input.init();
            defer input.deinit();
            const result = input.isMouseButtonPressed(.left);
            try expect.toBeTrue(@TypeOf(result) == bool);
        }

        test "isMouseButtonReleased returns bool" {
            var input = engine.Input.init();
            defer input.deinit();
            const result = input.isMouseButtonReleased(.left);
            try expect.toBeTrue(@TypeOf(result) == bool);
        }

        test "getMousePosition returns MousePosition" {
            var input = engine.Input.init();
            defer input.deinit();
            const pos = input.getMousePosition();
            try expect.toBeTrue(@TypeOf(pos) == engine.MousePosition);
        }

        test "getMouseWheelMove returns f32" {
            var input = engine.Input.init();
            defer input.deinit();
            const wheel = input.getMouseWheelMove();
            try expect.toBeTrue(@TypeOf(wheel) == f32);
        }
    };
};

pub const INPUT_INTERFACE_VALIDATION = struct {
    test "InputInterface function exists" {
        try expect.toBeTrue(@hasDecl(input_mod, "InputInterface"));
    }

    test "backend selection enum exists" {
        try expect.toBeTrue(@hasDecl(input_mod, "Backend"));
        try expect.toBeTrue(@hasDecl(input_mod, "backend"));
    }
};
