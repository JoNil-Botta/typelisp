#!/usr/bin/env sh
set -eu

# Keep the cfg-only register-allocation instrumentation buildable.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_require_compiler

WORKDIR="$ROOT/target/regalloc-census-verify"
ASM="$WORKDIR/typelisp-regalloc-census.s"
STDOUT="$WORKDIR/compile.stdout"
STDERR="$WORKDIR/compile.stderr"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

echo "[regalloc-census] compile cfg-enabled CLI"
if ! "$COMPILER" compile "$ROOT/src/main.tl" \
    -o "$ASM" \
    --cfg regalloc-census \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    > "$STDOUT" 2> "$STDERR"; then
    if [ -s "$STDOUT" ]; then
        sed 's/^/  /' "$STDOUT" >&2 || true
    fi
    if [ -s "$STDERR" ]; then
        sed 's/^/  /' "$STDERR" >&2 || true
    fi
    echo "regalloc-census compiler build failed" >&2
    exit 1
fi

[ -s "$ASM" ] || {
    echo "regalloc-census compiler build emitted no assembly" >&2
    exit 1
}

for marker in \
    'regalloc-call-span-census|calls_spanned|register|spill|unassigned' \
    'group-pair-assigned|members='; do
    grep -F "$marker" "$ASM" >/dev/null || {
        echo "regalloc-census compiler assembly omitted marker: $marker" >&2
        exit 1
    }
done

echo "regalloc-census compiler build passed"
