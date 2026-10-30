"""Run a build command, sample peak memory of the whole process tree.

usage: python measure.py <out_dir> <run_name> <cwd> -- <command...>
Env: inherits; caller sets ZIG_*_CACHE_DIR / EMSDK.
Writes <run_name>.log (timestamped output) and <run_name>.json (summary).
"""
import datetime, json, os, subprocess, sys, threading, time
from pathlib import Path
import psutil

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
name = sys.argv[2]; cwd = sys.argv[3]
cmd = sys.argv[sys.argv.index('--') + 1:]
t0 = time.time()
p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                     encoding='utf-8', errors='replace')
root = psutil.Process(p.pid)
peaks = {}  # pid -> (name, argv0, peak_private, peak_wset)
tree_peak = 0

def reader():
    with (out / (name + '.log')).open('w', encoding='utf-8') as f:
        for line in p.stdout:
            f.write(f'{time.time() - t0:8.1f} {line}')
            f.flush()

th = threading.Thread(target=reader); th.start()
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
                old = [c.name(), ' '.join(argv)[:300], 0, 0]
                peaks[c.pid] = old
            old[2] = max(old[2], priv)
            old[3] = max(old[3], getattr(m, 'peak_wset', m.rss))
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    tree_peak = max(tree_peak, total)
    time.sleep(0.5)
th.join()
elapsed = time.time() - t0
top = sorted(peaks.values(), key=lambda r: -r[2])[:5]
summary = {'run': name, 'cwd': cwd, 'command': cmd, 'exit': p.returncode, 'wall_seconds': round(elapsed, 2),
           'tree_peak_private_bytes': tree_peak,
           'top_processes': [{'name': n, 'argv': a, 'peak_private_bytes': pp, 'peak_working_set_bytes': pw} for n, a, pp, pw in top],
           'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
(out / (name + '.json')).write_text(json.dumps(summary, indent=2), encoding='utf-8')
print(json.dumps({k: summary[k] for k in ('run', 'exit', 'wall_seconds', 'tree_peak_private_bytes')}))
for t in summary['top_processes'][:3]:
    print('  ', t['name'], round(t['peak_private_bytes'] / 2**30, 2), 'GiB', t['argv'][:120])
sys.exit(p.returncode)
