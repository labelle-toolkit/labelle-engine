"""Run one build, sample peak memory of its process tree, optionally collect
`--time-report` over the build web UI.

usage: python profile_run.py <out_dir> <run_name> <cwd> [--webui PORT] -- <command...>

With --webui, the command must include `--time-report --webui=127.0.0.1:PORT`.
`zig build --webui` keeps serving after the build finishes, so once the build
summary is printed and the timing reader has drained the report, this script
terminates ONLY the process tree it started (never by name).

Writes <run_name>.log, <run_name>.json (wall, exit, per-process peaks) and,
with --webui, <run_name>-timing.json + <run_name>-step-N-llvm.txt.
"""
import datetime, json, subprocess, sys, threading, time
from pathlib import Path
import psutil

here = Path(__file__).parent
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
name = sys.argv[2]; cwd = sys.argv[3]
args = sys.argv[4:sys.argv.index('--')]
cmd = sys.argv[sys.argv.index('--') + 1:]
port = args[args.index('--webui') + 1] if '--webui' in args else None

t0 = time.time()
p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                     encoding='utf-8', errors='replace')
root = psutil.Process(p.pid)
reader_proc = None
peaks = {}
tree_peak = 0
summary_seen = threading.Event()
summary_time = [None]


def reader():
    with (out / (name + '.log')).open('w', encoding='utf-8') as f:
        for line in p.stdout:
            f.write(f'{time.time() - t0:8.1f} {line}')
            f.flush()
            if line.startswith('Build Summary') or 'error: the following build command failed' in line:
                summary_time[0] = time.time() - t0
                summary_seen.set()


th = threading.Thread(target=reader); th.start()
killed_after_summary = False
while p.poll() is None:
    try:
        procs = [root] + root.children(recursive=True)
    except psutil.NoSuchProcess:
        procs = []
    total = 0
    for c in procs:
        try:
            m = c.memory_info()
            priv = getattr(m, 'private', m.rss)
            total += priv
            old = peaks.get(c.pid)
            if old is None:
                try:
                    argv = c.cmdline()
                except Exception:
                    argv = []
                old = [c.name(), ' '.join(argv)[:400], 0, 0, time.time() - t0, 0]
                peaks[c.pid] = old
            old[2] = max(old[2], priv)
            old[3] = max(old[3], getattr(m, 'peak_wset', m.rss))
            old[5] = time.time() - t0
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    tree_peak = max(tree_peak, total)
    if port and summary_seen.is_set():
        # The web UI keeps the finished build's time reports; connect only
        # now (a connection held during the build gets dropped), let the
        # reader drain the report, then stop the web UI server we started
        # (our own PID tree only).
        reader_proc = subprocess.Popen([sys.executable, str(here / 'read_timing.py'), str(out), name, port],
                                       stdout=open(out / (name + '-reader.log'), 'w'), stderr=subprocess.STDOUT)
        try:
            reader_proc.wait(timeout=90)
        except subprocess.TimeoutExpired:
            reader_proc.kill()
        for c in root.children(recursive=True):
            try: c.kill()
            except psutil.NoSuchProcess: pass
        try: root.kill()
        except psutil.NoSuchProcess: pass
        killed_after_summary = True
        break
    time.sleep(0.5)
p.wait()
th.join()
if reader_proc and reader_proc.poll() is None:
    reader_proc.kill()
elapsed = summary_time[0] if killed_after_summary else time.time() - t0
log_text = (out / (name + '.log')).read_text(encoding='utf-8')
ok = ('Build Summary' in log_text and ' failed' not in log_text.split('Build Summary', 1)[1].splitlines()[0]) if 'Build Summary' in log_text else p.returncode == 0
top = sorted(peaks.values(), key=lambda r: -r[2])[:5]
procs_out = [{'name': r[0], 'argv': r[1], 'peak_private_bytes': r[2], 'peak_working_set_bytes': r[3],
              'start_s': round(r[4], 1), 'end_s': round(r[5], 1), 'seconds': round(r[5] - r[4], 1)}
             for r in sorted(peaks.values(), key=lambda r: r[4]) if r[5] - r[4] > 2 or r[2] > 2**28]
summary = {'run': name, 'cwd': cwd, 'command': cmd, 'exit': 0 if (killed_after_summary and ok) else p.returncode,
           'build_ok': ok, 'wall_seconds': round(elapsed, 2), 'tree_peak_private_bytes': tree_peak,
           'top_processes': [{'name': r[0], 'argv': r[1], 'peak_private_bytes': r[2], 'peak_working_set_bytes': r[3]} for r in top],
           'long_processes': procs_out,
           'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
(out / (name + '.json')).write_text(json.dumps(summary, indent=2), encoding='utf-8')
print(json.dumps({k: summary[k] for k in ('run', 'exit', 'build_ok', 'wall_seconds', 'tree_peak_private_bytes')}))
for t in summary['top_processes'][:3]:
    print('  ', t['name'], round(t['peak_private_bytes'] / 2**30, 2), 'GiB', t['argv'][:140])
sys.exit(0 if ok else 1)
