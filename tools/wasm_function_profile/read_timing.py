import json
from pathlib import Path
import struct
import sys
import websocket

# usage: read_timing.py <out_dir> <name> <port> [--wait]
# Reads `zig build --time-report --webui=127.0.0.1:<port>` frames: per-step
# wall time, sema/codegen/LLVM stats, LLVM pass time-report text, top decls.
import time
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
name = sys.argv[2]
port = sys.argv[3]
ws = None
for _ in range(600):
    try:
        ws = websocket.create_connection('ws://127.0.0.1:%s/' % port, timeout=3, http_proxy_host=None)
        break
    except Exception:
        time.sleep(1)
if ws is None:
    sys.exit('could not connect to webui')
steps = []
results = []
status = None
stats_names = ['reachable_files', 'imported_files', 'generic_instances', 'inline_calls',
    'cpu_parse_ns', 'cpu_astgen_ns', 'cpu_sema_ns', 'cpu_codegen_ns', 'cpu_link_ns',
    'real_files_ns', 'real_decls_ns', 'real_llvm_emit_ns', 'real_link_flush_ns']
while True:
    try:
        message = ws.recv()
    except websocket.WebSocketConnectionClosedException:
        break
    except websocket.WebSocketTimeoutException:
        if '--wait' in sys.argv and status != 0:
            continue
        break
    if not isinstance(message, bytes) or not message:
        continue
    tag = message[0]
    if tag == 0:
        status = message[1]
        count = struct.unpack_from('<I', message, 12)[0]
        lengths = struct.unpack_from('<' + 'I' * count, message, 16)
        offset = 16 + count * 4
        for length in lengths:
            steps.append(message[offset:offset + length].decode())
            offset += length
    elif tag == 1:
        status = message[1]
    elif tag == 6:
        step, ns = struct.unpack_from('<IQ', message, 1)
        results.append({'step': steps[step], 'wall_seconds': ns / 1e9})
    elif tag == 7:
        step = struct.unpack_from('<I', message, 1)[0]
        stats = dict(zip(stats_names, struct.unpack_from('<4I9Q', message, 6)))
        ns, llvm_len, file_count, decl_count = struct.unpack_from('<QIII', message, 94)
        offset = 114
        llvm = message[offset:offset + llvm_len].decode(errors='replace')
        offset += llvm_len
        files = []
        for _ in range(file_count):
            end = message.index(0, offset)
            files.append(message[offset:end].decode(errors='replace'))
            offset = end + 1
        decls = []
        for _ in range(decl_count):
            end = message.index(0, offset)
            decl = message[offset:end].decode(errors='replace')
            file_index, sema_count, sema, codegen, link = struct.unpack_from('<IIQQQ', message, end + 1)
            offset = end + 33
            decls.append({'name': decl, 'file': files[file_index], 'sema_count': sema_count, 'sema_ns': sema, 'codegen_ns': codegen, 'link_ns': link})
        result = {'step': steps[step], 'wall_seconds': ns / 1e9, 'stats': stats,
            'declarations': sorted(decls, key=lambda d: d['sema_ns'] + d['codegen_ns'] + d['link_ns'], reverse=True)}
        results.append(result)
        (out / (name + '-step-' + str(step) + '-llvm.txt')).write_text(llvm, encoding='utf-8')
try:
    ws.close()
except Exception:
    pass
data = {'status': status, 'steps': steps, 'results': results}
(out / (name + '-timing.json')).write_text(json.dumps(data, indent=2), encoding='utf-8')
print(json.dumps({'status': status, 'results': [{k: v for k, v in r.items() if k != 'declarations'} for r in results]}, indent=2))
