//! #935 — a game with many scripts must compile.
//!
//! `ScriptRunner` walks every script at comptime (`script_count`,
//! `initProfile`, `buildStatesType`). With Zig's default quota of 1000
//! backwards branches those walks stopped compiling at a few dozen
//! scripts ("evaluation exceeded 1000 backwards branches"), an error
//! that points into the engine, not at the script that was added.
//!
//! The script set below is deliberately far past that: 300 scripts, a
//! third of them with `State`. Building the runner over it IS the test;
//! the assertions pin that every script was counted and every `State`
//! got its field.
const std = @import("std");
const engine = @import("engine");

const ScriptRunner = engine.ScriptRunner;

const Stateless = struct {
    pub fn setup(game: anytype) void {
        game.setups += 1;
    }
    pub fn tick(game: anytype, _: f32) void {
        game.ticks += 1;
    }
};

const Stateful = struct {
    pub const State = struct { calls: u32 = 0 };
    pub fn tick(game: anytype, state: *State, _: anytype, _: f32) void {
        state.calls += 1;
        game.ticks += 1;
    }
};

const Drawing = struct {
    pub fn drawGui(game: anytype) void {
        game.draws += 1;
    }
};

const SCRIPTS = 300;

const ManyScripts = struct {
    pub const script_000 = Stateless;
    pub const script_001 = Stateful;
    pub const script_002 = Drawing;
    pub const script_003 = Stateless;
    pub const script_004 = Stateful;
    pub const script_005 = Drawing;
    pub const script_006 = Stateless;
    pub const script_007 = Stateful;
    pub const script_008 = Drawing;
    pub const script_009 = Stateless;
    pub const script_010 = Stateful;
    pub const script_011 = Drawing;
    pub const script_012 = Stateless;
    pub const script_013 = Stateful;
    pub const script_014 = Drawing;
    pub const script_015 = Stateless;
    pub const script_016 = Stateful;
    pub const script_017 = Drawing;
    pub const script_018 = Stateless;
    pub const script_019 = Stateful;
    pub const script_020 = Drawing;
    pub const script_021 = Stateless;
    pub const script_022 = Stateful;
    pub const script_023 = Drawing;
    pub const script_024 = Stateless;
    pub const script_025 = Stateful;
    pub const script_026 = Drawing;
    pub const script_027 = Stateless;
    pub const script_028 = Stateful;
    pub const script_029 = Drawing;
    pub const script_030 = Stateless;
    pub const script_031 = Stateful;
    pub const script_032 = Drawing;
    pub const script_033 = Stateless;
    pub const script_034 = Stateful;
    pub const script_035 = Drawing;
    pub const script_036 = Stateless;
    pub const script_037 = Stateful;
    pub const script_038 = Drawing;
    pub const script_039 = Stateless;
    pub const script_040 = Stateful;
    pub const script_041 = Drawing;
    pub const script_042 = Stateless;
    pub const script_043 = Stateful;
    pub const script_044 = Drawing;
    pub const script_045 = Stateless;
    pub const script_046 = Stateful;
    pub const script_047 = Drawing;
    pub const script_048 = Stateless;
    pub const script_049 = Stateful;
    pub const script_050 = Drawing;
    pub const script_051 = Stateless;
    pub const script_052 = Stateful;
    pub const script_053 = Drawing;
    pub const script_054 = Stateless;
    pub const script_055 = Stateful;
    pub const script_056 = Drawing;
    pub const script_057 = Stateless;
    pub const script_058 = Stateful;
    pub const script_059 = Drawing;
    pub const script_060 = Stateless;
    pub const script_061 = Stateful;
    pub const script_062 = Drawing;
    pub const script_063 = Stateless;
    pub const script_064 = Stateful;
    pub const script_065 = Drawing;
    pub const script_066 = Stateless;
    pub const script_067 = Stateful;
    pub const script_068 = Drawing;
    pub const script_069 = Stateless;
    pub const script_070 = Stateful;
    pub const script_071 = Drawing;
    pub const script_072 = Stateless;
    pub const script_073 = Stateful;
    pub const script_074 = Drawing;
    pub const script_075 = Stateless;
    pub const script_076 = Stateful;
    pub const script_077 = Drawing;
    pub const script_078 = Stateless;
    pub const script_079 = Stateful;
    pub const script_080 = Drawing;
    pub const script_081 = Stateless;
    pub const script_082 = Stateful;
    pub const script_083 = Drawing;
    pub const script_084 = Stateless;
    pub const script_085 = Stateful;
    pub const script_086 = Drawing;
    pub const script_087 = Stateless;
    pub const script_088 = Stateful;
    pub const script_089 = Drawing;
    pub const script_090 = Stateless;
    pub const script_091 = Stateful;
    pub const script_092 = Drawing;
    pub const script_093 = Stateless;
    pub const script_094 = Stateful;
    pub const script_095 = Drawing;
    pub const script_096 = Stateless;
    pub const script_097 = Stateful;
    pub const script_098 = Drawing;
    pub const script_099 = Stateless;
    pub const script_100 = Stateful;
    pub const script_101 = Drawing;
    pub const script_102 = Stateless;
    pub const script_103 = Stateful;
    pub const script_104 = Drawing;
    pub const script_105 = Stateless;
    pub const script_106 = Stateful;
    pub const script_107 = Drawing;
    pub const script_108 = Stateless;
    pub const script_109 = Stateful;
    pub const script_110 = Drawing;
    pub const script_111 = Stateless;
    pub const script_112 = Stateful;
    pub const script_113 = Drawing;
    pub const script_114 = Stateless;
    pub const script_115 = Stateful;
    pub const script_116 = Drawing;
    pub const script_117 = Stateless;
    pub const script_118 = Stateful;
    pub const script_119 = Drawing;
    pub const script_120 = Stateless;
    pub const script_121 = Stateful;
    pub const script_122 = Drawing;
    pub const script_123 = Stateless;
    pub const script_124 = Stateful;
    pub const script_125 = Drawing;
    pub const script_126 = Stateless;
    pub const script_127 = Stateful;
    pub const script_128 = Drawing;
    pub const script_129 = Stateless;
    pub const script_130 = Stateful;
    pub const script_131 = Drawing;
    pub const script_132 = Stateless;
    pub const script_133 = Stateful;
    pub const script_134 = Drawing;
    pub const script_135 = Stateless;
    pub const script_136 = Stateful;
    pub const script_137 = Drawing;
    pub const script_138 = Stateless;
    pub const script_139 = Stateful;
    pub const script_140 = Drawing;
    pub const script_141 = Stateless;
    pub const script_142 = Stateful;
    pub const script_143 = Drawing;
    pub const script_144 = Stateless;
    pub const script_145 = Stateful;
    pub const script_146 = Drawing;
    pub const script_147 = Stateless;
    pub const script_148 = Stateful;
    pub const script_149 = Drawing;
    pub const script_150 = Stateless;
    pub const script_151 = Stateful;
    pub const script_152 = Drawing;
    pub const script_153 = Stateless;
    pub const script_154 = Stateful;
    pub const script_155 = Drawing;
    pub const script_156 = Stateless;
    pub const script_157 = Stateful;
    pub const script_158 = Drawing;
    pub const script_159 = Stateless;
    pub const script_160 = Stateful;
    pub const script_161 = Drawing;
    pub const script_162 = Stateless;
    pub const script_163 = Stateful;
    pub const script_164 = Drawing;
    pub const script_165 = Stateless;
    pub const script_166 = Stateful;
    pub const script_167 = Drawing;
    pub const script_168 = Stateless;
    pub const script_169 = Stateful;
    pub const script_170 = Drawing;
    pub const script_171 = Stateless;
    pub const script_172 = Stateful;
    pub const script_173 = Drawing;
    pub const script_174 = Stateless;
    pub const script_175 = Stateful;
    pub const script_176 = Drawing;
    pub const script_177 = Stateless;
    pub const script_178 = Stateful;
    pub const script_179 = Drawing;
    pub const script_180 = Stateless;
    pub const script_181 = Stateful;
    pub const script_182 = Drawing;
    pub const script_183 = Stateless;
    pub const script_184 = Stateful;
    pub const script_185 = Drawing;
    pub const script_186 = Stateless;
    pub const script_187 = Stateful;
    pub const script_188 = Drawing;
    pub const script_189 = Stateless;
    pub const script_190 = Stateful;
    pub const script_191 = Drawing;
    pub const script_192 = Stateless;
    pub const script_193 = Stateful;
    pub const script_194 = Drawing;
    pub const script_195 = Stateless;
    pub const script_196 = Stateful;
    pub const script_197 = Drawing;
    pub const script_198 = Stateless;
    pub const script_199 = Stateful;
    pub const script_200 = Drawing;
    pub const script_201 = Stateless;
    pub const script_202 = Stateful;
    pub const script_203 = Drawing;
    pub const script_204 = Stateless;
    pub const script_205 = Stateful;
    pub const script_206 = Drawing;
    pub const script_207 = Stateless;
    pub const script_208 = Stateful;
    pub const script_209 = Drawing;
    pub const script_210 = Stateless;
    pub const script_211 = Stateful;
    pub const script_212 = Drawing;
    pub const script_213 = Stateless;
    pub const script_214 = Stateful;
    pub const script_215 = Drawing;
    pub const script_216 = Stateless;
    pub const script_217 = Stateful;
    pub const script_218 = Drawing;
    pub const script_219 = Stateless;
    pub const script_220 = Stateful;
    pub const script_221 = Drawing;
    pub const script_222 = Stateless;
    pub const script_223 = Stateful;
    pub const script_224 = Drawing;
    pub const script_225 = Stateless;
    pub const script_226 = Stateful;
    pub const script_227 = Drawing;
    pub const script_228 = Stateless;
    pub const script_229 = Stateful;
    pub const script_230 = Drawing;
    pub const script_231 = Stateless;
    pub const script_232 = Stateful;
    pub const script_233 = Drawing;
    pub const script_234 = Stateless;
    pub const script_235 = Stateful;
    pub const script_236 = Drawing;
    pub const script_237 = Stateless;
    pub const script_238 = Stateful;
    pub const script_239 = Drawing;
    pub const script_240 = Stateless;
    pub const script_241 = Stateful;
    pub const script_242 = Drawing;
    pub const script_243 = Stateless;
    pub const script_244 = Stateful;
    pub const script_245 = Drawing;
    pub const script_246 = Stateless;
    pub const script_247 = Stateful;
    pub const script_248 = Drawing;
    pub const script_249 = Stateless;
    pub const script_250 = Stateful;
    pub const script_251 = Drawing;
    pub const script_252 = Stateless;
    pub const script_253 = Stateful;
    pub const script_254 = Drawing;
    pub const script_255 = Stateless;
    pub const script_256 = Stateful;
    pub const script_257 = Drawing;
    pub const script_258 = Stateless;
    pub const script_259 = Stateful;
    pub const script_260 = Drawing;
    pub const script_261 = Stateless;
    pub const script_262 = Stateful;
    pub const script_263 = Drawing;
    pub const script_264 = Stateless;
    pub const script_265 = Stateful;
    pub const script_266 = Drawing;
    pub const script_267 = Stateless;
    pub const script_268 = Stateful;
    pub const script_269 = Drawing;
    pub const script_270 = Stateless;
    pub const script_271 = Stateful;
    pub const script_272 = Drawing;
    pub const script_273 = Stateless;
    pub const script_274 = Stateful;
    pub const script_275 = Drawing;
    pub const script_276 = Stateless;
    pub const script_277 = Stateful;
    pub const script_278 = Drawing;
    pub const script_279 = Stateless;
    pub const script_280 = Stateful;
    pub const script_281 = Drawing;
    pub const script_282 = Stateless;
    pub const script_283 = Stateful;
    pub const script_284 = Drawing;
    pub const script_285 = Stateless;
    pub const script_286 = Stateful;
    pub const script_287 = Drawing;
    pub const script_288 = Stateless;
    pub const script_289 = Stateful;
    pub const script_290 = Drawing;
    pub const script_291 = Stateless;
    pub const script_292 = Stateful;
    pub const script_293 = Drawing;
    pub const script_294 = Stateless;
    pub const script_295 = Stateful;
    pub const script_296 = Drawing;
    pub const script_297 = Stateless;
    pub const script_298 = Stateful;
    pub const script_299 = Drawing;
};

const Runner = ScriptRunner(ManyScripts, struct {}, struct {});

const Game = struct {
    setups: u32 = 0,
    ticks: u32 = 0,
    draws: u32 = 0,
};

test "a runner over hundreds of scripts compiles, counts them all and keeps every State" {
    try std.testing.expectEqual(@as(usize, SCRIPTS), @typeInfo(ManyScripts).@"struct".decls.len);
    try std.testing.expectEqual(@as(usize, SCRIPTS), Runner.script_count);

    var runner = Runner.init(std.testing.allocator, &{});
    defer runner.deinit();
    // One State field per stateful script: a third of them.
    try std.testing.expectEqual(@as(usize, SCRIPTS / 3), @typeInfo(@TypeOf(runner.states)).@"struct".fields.len);

    var game = Game{};
    runner.setup(&game);
    // A third set up (the stateless ones).
    try std.testing.expectEqual(@as(u32, SCRIPTS / 3), game.setups);
    runner.tick(&game, 0.016);
    runner.drawGui(&game);
    // Two thirds tick (stateless + stateful), one third draws.
    try std.testing.expectEqual(@as(u32, SCRIPTS / 3 * 2), game.ticks);
    try std.testing.expectEqual(@as(u32, SCRIPTS / 3), game.draws);
    try std.testing.expectEqual(@as(u32, 1), runner.states.script_001.calls);
}
