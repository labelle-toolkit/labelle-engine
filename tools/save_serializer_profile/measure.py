"""Measure the WASM ReleaseSafe compile cost of the save serializer (#921).

A/B harness: compiles a game's generated WASM `game` library once with a
given `save.zig` dropped into the game's vendored engine copy, and reports

  * wall time of the `zig build-lib ... --name game` compiler process,
  * its peak private memory (Windows commit) and peak working set,
  * the size of every `save_load.save.Mixin(...)` function in the produced
    `libgame.a` (`llvm-nm -S`), i.e. `serializeGameState` and the #921
    per-component helpers.

Usage (from any directory; needs Python 3 with psutil):

    python measure.py NAME \
        --build-dir  <game>/.labelle/bgfx_wasm \
        --save-zig   <engine checkout>/src/game/save_load/save.zig \
        --llvm-nm    <emsdk>/upstream/bin/llvm-nm.exe \
        --out        results/

It temporarily
  1. replaces `<build-dir>/../deps/labelle-engine/src/game/save_load/save.zig`
     with `--save-zig` plus a unique trailing comment (forces a cold compile
     of the game module; zig's cache is content-addressed),
  2. adds a `profile-game` step to the generated `build.zig` that installs
     only the `game` library (skips the emcc link),
then restores both files, even on failure. Originals are also kept on disk as
`<file>.ab-backup` until restored, so a hard-killed run is repaired by
`measure.py --abort PID --build-dir ...` (what run_ab.sh does when
interrupted: kills the PID's process tree, then restores) or by the next run.
Nothing is written to the game's source tree — `.labelle/` is generated
output.

The game build's environment (LABELLE_ZIG, EMSDK, zig cache dirs) is taken
from the caller's environment; `--zig` selects the compiler.

Writes `<out>/<NAME>.jsonl` (1 Hz process samples), `<NAME>.log` (build
output) and `<NAME>-result.json` (the summary).
"""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

import psutil

PROFILE_STEP = (
    '    const profile_game = b.step("profile-game", "Compile only the game library (#921 profiling)");\n'
    '    profile_game.dependOn(&b.addInstallArtifact(wasm, .{}).step);\n'
)
ANCHOR = '    // post_wire (design'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('name', nargs='?')
    ap.add_argument('--build-dir', required=True, type=Path)
    ap.add_argument('--save-zig', type=Path)
    ap.add_argument('--llvm-nm', type=Path)
    ap.add_argument('--out', type=Path)
    ap.add_argument('--zig', default=os.environ.get('LABELLE_ZIG', 'zig'))
    ap.add_argument('--jobs', default='2')
    ap.add_argument('--abort', type=int, metavar='PID',
                    help='kill the measure.py process tree PID and restore the game files it changed')
    args = ap.parse_args()

    edited = edited_files(args.build_dir)
    if args.abort is not None:
        kill_tree(args.abort)
        restore(edited)
        return
    if not (args.name and args.save_zig and args.llvm_nm and args.out):
        ap.error('NAME, --save-zig, --llvm-nm and --out are required')

    # A TERM (POSIX) still runs the `finally` below. A hard kill (what a
    # Windows TerminateProcess amounts to) cannot: the on-disk backups let
    # `--abort` or the next run restore the files instead.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))

    args.out.mkdir(parents=True, exist_ok=True)
    restore(edited)  # left behind by an earlier, hard-killed run
    build_zig, target_save = edited
    lib = args.build_dir / 'zig-out' / 'lib' / 'libgame.a'

    original_build = build_zig.read_bytes()
    for path in edited:
        backup_path(path).write_bytes(path.read_bytes())
    try:
        text = original_build.decode()
        assert ANCHOR in text, 'generated build.zig changed shape; update ANCHOR'
        build_zig.write_bytes(text.replace(ANCHOR, PROFILE_STEP + ANCHOR, 1).encode())
        bust = f'\n// #921 profile run {args.name} {time.time_ns()}\n'.encode()
        target_save.write_bytes(args.save_zig.read_bytes() + bust)
        if lib.exists():
            lib.unlink()
        result = run_build(args)
        if result['exit'] == 0:
            result['save_mixin_functions'] = function_sizes(args.llvm_nm, lib)
            result['libgame_bytes'] = lib.stat().st_size
    finally:
        restore(edited)

    (args.out / f'{args.name}-result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != 'save_mixin_functions'}, indent=2))
    for f in result.get('save_mixin_functions', [])[:8]:
        print(f'{f["bytes"]:>8}  {f["name"]}')
    sys.exit(result['exit'])


def edited_files(build_dir):
    """The two generated files a run modifies: build.zig and the vendored save.zig."""
    save = build_dir.parent / 'deps' / 'labelle-engine' / 'src' / 'game' / 'save_load' / 'save.zig'
    return build_dir / 'build.zig', save


def backup_path(path):
    return path.with_name(path.name + '.ab-backup')


def restore(paths):
    for path in paths:
        backup = backup_path(path)
        if backup.exists():
            path.write_bytes(backup.read_bytes())
            backup.unlink()


def kill_tree(pid):
    """Kill `pid` and every descendant (the zig compiler processes), leaves first."""
    try:
        root = psutil.Process(pid)
        tree = root.children(recursive=True) + [root]
    except psutil.NoSuchProcess:
        return
    for p in reversed(tree[:-1]):
        try:
            p.kill()
        except psutil.NoSuchProcess:
            pass
    try:
        root.kill()
    except psutil.NoSuchProcess:
        pass
    psutil.wait_procs(tree, timeout=30)


def run_build(args):
    command = [args.zig, 'build', 'profile-game', '-Doptimize=ReleaseSafe', f'-j{args.jobs}', '--summary', 'all']
    started = time.time()
    process = subprocess.Popen(command, cwd=args.build_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding='utf-8', errors='replace')
    root = psutil.Process(process.pid)
    procs = {}

    def pump():
        with (args.out / f'{args.name}.log').open('w', encoding='utf-8') as log:
            for line in process.stdout:
                log.write(line)

    reader = threading.Thread(target=pump)
    reader.start()
    try:
        sample(args, process, root, procs)
    finally:
        # Interrupted: take the whole compiler tree down with us.
        if process.poll() is None:
            kill_tree(process.pid)
            process.wait()
    reader.join()
    return summarize(args, command, started, process, procs)


def sample(args, process, root, procs):
    with (args.out / f'{args.name}.jsonl').open('w', encoding='utf-8') as samples:
        while process.poll() is None:
            now = time.time()
            rows = []
            try:
                tree = [root] + root.children(recursive=True)
            except psutil.NoSuchProcess:
                tree = []
            for p in tree:
                try:
                    mem = p.memory_info()._asdict()
                    rec = procs.setdefault(p.pid, {'pid': p.pid, 'name': p.name(), 'argv': p.cmdline(),
                                                   'first': now, 'peak_private': 0, 'peak_wset': 0})
                    rec['last'] = now
                    rec['peak_private'] = max(rec['peak_private'], mem.get('private', mem['rss']))
                    rec['peak_wset'] = max(rec['peak_wset'], mem.get('peak_wset', mem['rss']))
                    rec['cpu_seconds'] = sum(p.cpu_times()[:2])
                    rows.append({'pid': p.pid, 'private': mem.get('private'), 'rss': mem['rss']})
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            samples.write(json.dumps({'time': now, 'available_ram': psutil.virtual_memory().available,
                                      'processes': rows}) + '\n')
            samples.flush()
            time.sleep(1)


def summarize(args, command, started, process, procs):
    game = [p for p in procs.values() if '--name' in p['argv'] and p['argv'][p['argv'].index('--name') + 1] == 'game']
    result = {'run': args.name, 'exit': process.returncode, 'command': command,
              'build_wall_seconds': round(time.time() - started, 1)}
    if game:
        g = max(game, key=lambda p: p['peak_private'])
        result.update({
            'game_compile_wall_seconds': round(g['last'] - g['first'], 1),
            'game_compile_cpu_seconds': round(g.get('cpu_seconds', 0), 1),
            'game_compile_peak_private_bytes': g['peak_private'],
            'game_compile_peak_private_gib': round(g['peak_private'] / 2**30, 2),
            'game_compile_peak_working_set_gib': round(g['peak_wset'] / 2**30, 2),
        })
    return result


def function_sizes(llvm_nm, lib):
    out = subprocess.run([str(llvm_nm), '-S', '--defined-only', str(lib)], capture_output=True, text=True,
                         encoding='utf-8', errors='replace', check=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(' ', 3)
        if len(parts) != 4 or parts[2].lower() != 't' or 'save_load.save.Mixin(' not in parts[3]:
            continue
        # Drop the (huge) Game type argument: keep `<fn>` and its anon suffix.
        short = re.sub(r'^.*\)\.([A-Za-z_][\w]*)$', r'\1', parts[3])
        rows.append({'name': short, 'bytes': int(parts[1], 16)})
    rows.sort(key=lambda r: r['bytes'], reverse=True)
    return rows


if __name__ == '__main__':
    main()
