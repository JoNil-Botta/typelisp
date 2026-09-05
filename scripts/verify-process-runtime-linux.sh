#!/usr/bin/env sh
set -eu

# verify-process-runtime-linux.sh - deterministic Linux process syscall,
# exec-channel, capture, reaping, and cleanup fault coverage. refs #7570

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "process runtime fault verification is Linux-only"
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

[ -x "$COMPILER" ] || {
    echo "process runtime compiler is not executable: $COMPILER" >&2
    exit 1
}
command -v as >/dev/null 2>&1 || {
    echo "process runtime verification requires as" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "process runtime verification requires ld" >&2
    exit 1
}

WORKDIR="$ROOT/target/process-runtime-linux-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

SOURCE="$ROOT/tests/integration/process_runtime_linux_failures.tl"
ASM="$WORKDIR/process-runtime-linux.s"
OBJ="$WORKDIR/process-runtime-linux.o"
BIN="$WORKDIR/process-runtime-linux"

echo "[process-runtime-linux] compile assembly fallback with fault hooks"
"$COMPILER" compile "$SOURCE" -o "$ASM" \
    --target linux-x86_64 --backend-mode scalar \
    --cfg process-linux-test-hooks --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT" \
    > "$WORKDIR/compile.stdout" 2> "$WORKDIR/compile.stderr" || {
        [ ! -s "$WORKDIR/compile.stdout" ] || cat "$WORKDIR/compile.stdout" >&2
        [ ! -s "$WORKDIR/compile.stderr" ] || cat "$WORKDIR/compile.stderr" >&2
        fail "process runtime fixture compile failed"
    }
as "$ASM" -o "$OBJ"
ld "$OBJ" -o "$BIN" -e _tl_start

set +e
"$BIN" > "$WORKDIR/run.stdout" 2> "$WORKDIR/run.stderr"
STATUS=$?
set -e

[ "$STATUS" -eq 42 ] || {
    [ ! -s "$WORKDIR/run.stdout" ] || cat "$WORKDIR/run.stdout" >&2
    [ ! -s "$WORKDIR/run.stderr" ] || cat "$WORKDIR/run.stderr" >&2
    fail "process runtime fixture expected exit 42, got $STATUS"
}
[ ! -s "$WORKDIR/run.stderr" ] || {
    cat "$WORKDIR/run.stderr" >&2
    fail "process runtime fixture wrote stderr"
}
[ "$(wc -l < "$WORKDIR/run.stdout")" -eq 1 ] ||
    fail "process runtime fixture did not write one metrics line"
METRICS=$(sed -n '1p' "$WORKDIR/run.stdout")
case "$METRICS" in
    "process-linux-metrics ticks="*" alloc-bytes="*" fds="*" zombies=0 syscalls=15") ;;
    *) fail "unexpected process runtime metrics: $METRICS" ;;
esac

echo "[process-runtime-linux] $METRICS"
echo "Process runtime Linux verification passed"
