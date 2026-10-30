| variant | game compile s (edit rebuild) | game peak private GiB | compile s (--time-report) | peak GiB (--time-report) | LLVM emit s | sema CPU s | codegen CPU s | emcc link s | final .wasm B | game obj code B | functions |
|---|---|---|---|---|---|---|---|---|---|---|---|
| base2 | 130.9 | 5.67 | 136.8 | 5.89 |  |  |  | 157.7 | 35839098 | 5817335 | 4170 |
| base3 | 131.8 | 5.68 | 136.9 | 5.85 | 131.2 | 5.6 | 1.8 | 158.5 | 35839098 | 5817335 | 4170 |
| after1 | 101.1 | 4.93 | 107.9 | 5.17 |  |  |  | 152.7 | 35444795 | 5368582 | 4424 |
| after2 | 97.5 | 4.94 | 103.7 | 5.09 | 97.3 | 5.6 | 1.8 | 142.4 | 35444795 | 5368582 | 4424 |
| after3 | 98.8 | 4.86 | 102.7 | 5.09 | 96.8 | 5.6 | 1.8 | 140.6 | 35444795 | 5368582 | 4424 |

Largest function per variant:
  base2: 335369 B main.main
  base3: 335369 B main.main
  after1: 58476 B game.save_load.save.Mixin(game.GameConfigWithYAxis(...)
  after2: 58476 B game.save_load.save.Mixin(game.GameConfigWithYAxis(...)
  after3: 58476 B game.save_load.save.Mixin(game.GameConfigWithYAxis(...)

Cluster sizes (bytes / largest function):
| cluster | base2 | base3 | after1 | after2 | after3 |
|---|---:|---:|---:|---:|---:|
| startup main.main | 335369 (1 fn, max 335369) | 335369 (1 fn, max 335369) | 40046 (1 fn, max 40046) | 40046 (1 fn, max 40046) | 40046 (1 fn, max 40046) |
| inspector drawEntityDetail | 164914 (1 fn, max 164914) | 164914 (1 fn, max 164914) | 0 (0 fn, max 0) | 0 (0 fn, max 0) | 0 (0 fn, max 0) |
| inspector drawEntityBrowser | 84905 (1 fn, max 84905) | 84905 (1 fn, max 84905) | 0 (0 fn, max 0) | 0 (0 fn, max 0) | 0 (0 fn, max 0) |
| inspector other root.draw* | 78118 (54 fn, max 15996) | 78118 (54 fn, max 15996) | 256060 (364 fn, max 26122) | 256060 (364 fn, max 26122) | 256060 (364 fn, max 26122) |
| load.Mixin.* (all) | 134557 (3 fn, max 133381) | 134557 (3 fn, max 133381) | 142697 (82 fn, max 14322) | 142697 (82 fn, max 14322) | 142697 (82 fn, max 14322) |
| save.Mixin.* (all) | 407337 (141 fn, max 58476) | 407337 (141 fn, max 58476) | 407337 (141 fn, max 58476) | 407337 (141 fn, max 58476) | 407337 (141 fn, max 58476) |
| main.* (generated, all) | 385298 (5 fn, max 335369) | 385298 (5 fn, max 335369) | 89975 (5 fn, max 46494) | 89975 (5 fn, max 46494) | 89975 (5 fn, max 46494) |

Top LLVM passes (wall s, summed over time-report sections):
| pass | base2 | base3 | after1 | after2 | after3 |
|---|---:|---:|---:|---:|---:|
| InstCombinePass | 0 | 15.05 | 0 | 13.25 | 13.15 |
| WebAssembly Fix Irreducible Control Flow | 0 | 14.43 | 0 | 1.7 | 1.69 |
| InlinerPass | 0 | 13.7 | 0 | 11.72 | 11.6 |
| WebAssembly Instruction Selection | 0 | 8.27 | 0 | 7.4 | 7.41 |
| WebAssembly Register Stackify | 0 | 7.93 | 0 | 2.21 | 2.22 |
| GVNPass | 0 | 5.41 | 0 | 4.65 | 4.6 |
| SimplifyCFGPass | 0 | 4.29 | 0 | 3.73 | 3.72 |
| JumpThreadingPass | 0 | 4.24 | 0 | 3.55 | 3.54 |
| LICMPass | 0 | 3.1 | 0 | 2.4 | 2.38 |
| EarlyCSEPass | 0 | 2.74 | 0 | 2.38 | 2.37 |
| SROAPass | 0 | 2.5 | 0 | 2.1 | 2.08 |
| DSEPass | 0 | 2.3 | 0 | 2.01 | 1.99 |
| WebAssembly Assembly Printer | 0 | 2.25 | 0 | 1.86 | 1.84 |
| CorrelatedValuePropagationPass | 0 | 1.93 | 0 | 1.68 | 1.68 |
| MemorySSAAnalysis | 0 | 1.93 | 0 | 1.62 | 1.61 |
