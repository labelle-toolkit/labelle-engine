#!/usr/bin/env bash
#
# Measure the cost of opt-in hook tracing (labelle-engine#858).
#
# Two questions, two measurements.
#
#   OFF  Does a build that did NOT opt in change at all?
#        Compiles `test/hook_trace_cost_probe.zig` — which touches every
#        emit/dispatch path #858 instrumented and declares no
#        `labelle_hook_trace` — against a BASE engine tree and against
#        this WORKING tree, both unpacked to the SAME filesystem path,
#        and compares Mach-O section sizes plus a per-function size
#        table.
#
#        NOT SHA-256. `zig build-exe` on macOS is not byte-reproducible —
#        building the SAME tree twice already yields two different
#        hashes (LC_UUID) — so hash equality would fail for reasons that
#        have nothing to do with this change. Step 0 demonstrates that
#        and establishes section size as the metric that IS stable.
#
#        Step 3 is an ablation: BASE plus a single bare
#        `hook_tracer: void = {}` field on `Game` and nothing else. Any
#        residual delta that this reproduces is Zig's layout churn from a
#        struct gaining a zero-sized field, not emitted tracing code.
#
#   ON   What does tracing cost at the #854 validation scale?
#        Compiles the 64-variant x 16-receiver dispatcher twice — through
#        `core.MergeHooks.emit` (`test/hook_dispatch_scaling_test.zig`)
#        and through the engine's traced walk
#        (`test/hook_trace_scaling_exe.zig`) — and times both. That
#        product is where the comptime branch quota goes.
#
# Usage:
#   tools/hook_trace_cost.sh [BASE_REF]        # default BASE_REF=origin/main
#
# Requires: zig 0.16.0, git, size(1), nm(1), python3, perl. macOS/Mach-O;
# on ELF hosts swap `size -m` for `size -A`.

set -euo pipefail

BASE_REF="${1:-origin/main}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$(cd "$REPO/../labelle-core" && pwd)"
WORK="$(mktemp -d)"
# ONE path, reused for every tree: the compiler embeds source paths, so
# building two trees at two different paths would differ for a reason
# that has nothing to do with the change under test.
ENG="$WORK/eng"
trap 'rm -rf "$WORK"' EXIT

DARWIN_FRAMEWORKS=""
if [ "$(uname -s)" = "Darwin" ]; then
  DARWIN_FRAMEWORKS="-framework IOSurface -framework CoreFoundation"
fi

build_probe() { # build_probe <out> [extra zig flags...]
  local out="$1"; shift
  rm -rf "$WORK/zc"
  # shellcheck disable=SC2086
  zig build-exe \
    -O ReleaseFast -lc $DARWIN_FRAMEWORKS "$@" \
    --name probe \
    --cache-dir "$WORK/zc" --global-cache-dir "$WORK/zg" \
    -femit-bin="$out" \
    --dep engine --dep labelle-core --dep scene \
    -Mroot="$ENG/test/hook_trace_cost_probe.zig" \
    --dep labelle-core --dep scene --dep jsonc --dep audio_types --dep font_types \
    -Mengine="$ENG/src/root.zig" \
    -Mlabelle-core="$CORE/src/root.zig" \
    --dep labelle-core \
    -Mscene="$ENG/scene/src/root.zig" \
    -Mjsonc="$ENG/jsonc/src/root.zig" \
    -Maudio_types="$ENG/src/audio_types.zig" \
    --dep labelle-core \
    -Mfont_types="$ENG/src/font_types.zig" \
    >/dev/null
}

lay() { # lay <git-ref>
  rm -rf "$ENG"; mkdir -p "$ENG"
  git -C "$REPO" archive "$1" | tar -x -C "$ENG"
  # The probe does not exist in older refs; it is the constant here.
  cp "$REPO/test/hook_trace_cost_probe.zig" "$ENG/test/"
}

sizes() { # sizes <binary> -> "text=<n> const=<n> file=<n>"
  echo "text=$(size -m "$1" | awk '/Section __text:/{print $3}')" \
       "const=$(size -m "$1" | awk '/Section __const:/{print $3; exit}')" \
       "file=$(wc -c < "$1" | tr -d ' ')"
}

fn_table() { # fn_table <binary> <out> — per-function start addresses
  nm -n "$1" | awk '$2=="t"||$2=="T"{print $1, $3}' > "$2"
}

echo "== step 0: is the build byte-reproducible? =="
lay "$BASE_REF"; build_probe "$WORK/base_a" -fstrip
lay "$BASE_REF"; build_probe "$WORK/base_b" -fstrip
echo "  same tree, two builds:"
echo "    sha  $(shasum -a 256 "$WORK/base_a" | cut -c1-16)  vs  $(shasum -a 256 "$WORK/base_b" | cut -c1-16)"
echo "    size $(sizes "$WORK/base_a")"
echo "         $(sizes "$WORK/base_b")"
echo "  => hashes differ run to run; section sizes do not. Sizes are the metric."

echo
echo "== step 1: OFF — $BASE_REF vs HEAD, untraced probe =="
lay HEAD; build_probe "$WORK/head" -fstrip
echo "  base  $(sizes "$WORK/base_a")"
echo "  head  $(sizes "$WORK/head")"

echo
echo "== step 2: which functions changed size? =="
lay "$BASE_REF"; build_probe "$WORK/base_sym" -fno-strip; fn_table "$WORK/base_sym" "$WORK/base.sym"
lay HEAD;        build_probe "$WORK/head_sym" -fno-strip; fn_table "$WORK/head_sym" "$WORK/head.sym"
python3 - "$WORK" <<'PY'
import sys, re
W = sys.argv[1]
def load(p):
    rows = []
    for line in open(p):
        a, n = line.split()
        # Anonymous instantiation indices shift whenever ANY decl is added
        # anywhere; normalise them or every generic reads as "changed".
        rows.append((int(a, 16), re.sub(r'__(anon|struct)_\d+', '__X', n)))
    rows.sort()
    out = {}
    for i, (a, n) in enumerate(rows):
        end = rows[i + 1][0] if i + 1 < len(rows) else a
        out.setdefault(n, []).append(end - a)
    return out
b, h = load(W + "/base.sym"), load(W + "/head.sym")
diffs = [(k, sorted(b.get(k, [])), sorted(h.get(k, [])))
         for k in set(b) | set(h) if sorted(b.get(k, [])) != sorted(h.get(k, []))]
print(f"  functions emitted: base={sum(len(v) for v in b.values())} head={sum(len(v) for v in h.values())}")
print(f"  functions whose size changed: {len(diffs)}")
for k, bv, hv in sorted(diffs)[:20]:
    print(f"    {k[:100]}\n      base={bv} head={hv}")
PY

echo
echo "== step 3: ablation — BASE plus one bare 'void' field on Game =="
lay "$BASE_REF"
perl -0pi -e 's/(        hooks: HooksField = if \(has_hooks\) null else \{\},\n)/$1        hook_tracer: void = \{\},\n/' "$ENG/src/game.zig"
if grep -q 'hook_tracer: void' "$ENG/src/game.zig"; then
  build_probe "$WORK/void_field" -fstrip
  echo "  base        $(sizes "$WORK/base_a")"
  echo "  +void field $(sizes "$WORK/void_field")"
  echo "  head        $(sizes "$WORK/head")"
  echo "  => whatever '+void field' already accounts for is Zig struct-layout"
  echo "     churn from a zero-sized field, not emitted tracing code."
else
  echo "  ablation patch did not apply against $BASE_REF — skipped"
fi

echo
echo "== step 4: ON — comptime cost at 64 variants x 16 receivers =="
#
# A true A/B: the SAME file (test/hook_trace_scaling_exe.zig, 64 event
# variants x 16 receiver types), compiled twice. The only difference is
# whether its root carries `pub const labelle_hook_trace` — every tracer
# assertion in it is behind `if (comptime engine.hookTraceEnabled)` so
# both halves compile. OFF therefore goes through `core.MergeHooks.emit`,
# ON through the engine's traced walk, over an identical hook surface.
cd "$REPO"
mkdir -p "$WORK/scale"
grep -v '^pub const labelle_hook_trace' "$REPO/test/hook_trace_scaling_exe.zig" \
  > "$WORK/scale/scaling_off_exe.zig"
cp "$REPO/test/hook_trace_scaling_exe.zig" "$WORK/scale/scaling_on_exe.zig"

MODS=(
  --dep labelle-core --dep scene --dep jsonc --dep audio_types --dep font_types
  -Mengine="$REPO/src/root.zig"
  -Mlabelle-core="$CORE/src/root.zig"
  --dep labelle-core
  -Mscene="$REPO/scene/src/root.zig"
  -Mjsonc="$REPO/jsonc/src/root.zig"
  -Maudio_types="$REPO/src/audio_types.zig"
  --dep labelle-core
  -Mfont_types="$REPO/src/font_types.zig"
)

time_build() { # time_build <label> <root file> <out>
  echo "-- $1 (ReleaseFast) --"
  rm -rf "$WORK/zcs"
  # shellcheck disable=SC2086
  # ReleaseFast, matching the size probe in step 1. Without an explicit
  # -O this built in DEBUG, so the reported compile-time and __text deltas
  # described a mode nobody ships (#858 review).
  /usr/bin/time -p zig build-exe -O ReleaseFast -lc $DARWIN_FRAMEWORKS \
    --cache-dir "$WORK/zcs" --global-cache-dir "$WORK/zg2" \
    -femit-bin="$3" \
    --dep engine --dep labelle-core --dep scene \
    -Mroot="$2" \
    "${MODS[@]}"
  echo "   __text=$(size -m "$3" | awk '/Section __text:/{print $3}')"
}

# Warm the GLOBAL cache first: whichever half compiles the shared std /
# core artifacts pays for them, and that dwarfs the difference under
# measurement. Then interleave, because the numbers still drift.
rm -rf "$WORK/zcs"
# shellcheck disable=SC2086
zig build-exe -lc $DARWIN_FRAMEWORKS \
  --cache-dir "$WORK/zcs" --global-cache-dir "$WORK/zg2" -femit-bin="$WORK/warm" \
  --dep engine --dep labelle-core --dep scene \
  -Mroot="$WORK/scale/scaling_on_exe.zig" "${MODS[@]}" >/dev/null

for _ in 1 2; do
  time_build "tracing OFF (core.MergeHooks.emit)" "$WORK/scale/scaling_off_exe.zig" "$WORK/scale_off"
  time_build "tracing ON  (engine traced walk)"  "$WORK/scale/scaling_on_exe.zig"  "$WORK/scale_on"
done

echo
echo "  (Both binaries run; the ON one prints its record count.)"
"$WORK/scale_off" || true
"$WORK/scale_on" || true
