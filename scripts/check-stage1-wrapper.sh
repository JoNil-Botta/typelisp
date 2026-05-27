#!/usr/bin/env sh
set -eu

# Smoke-test a TYPELISP_BIN-compatible stage1 wrapper on the Linux host-action
# surface: compile, build, run, and debug host-action.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "stage1 wrapper smoke is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "stage1 wrapper smoke requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/stage1-wrapper-smoke"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SRC="$WORKDIR/smoke.tl"
ASM="$WORKDIR/smoke.s"
BIN="$WORKDIR/smoke-bin"
HOST_ACTION_BIN="$WORKDIR/host action/out bin"
SCRATCH_ASM="$WORKDIR/inline-test.s"

cat > "$SRC" <<'EOF'
(define (main) : i64
  7)
EOF

assert_contains() {
    file=$1
    needle=$2
    if ! grep -qF "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    fi
}

run_capture() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if ! "$@" > "$stdout" 2> "$stderr"; then
        echo "stage1 wrapper smoke command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

echo "[stage1-wrapper] compile"
run_capture compile "$COMPILER" compile "$SRC" -o "$ASM"
[ -f "$ASM" ] || {
    echo "compile did not write $ASM" >&2
    exit 1
}
assert_contains "$WORKDIR/compile.stdout" "Generated: $ASM"

echo "[stage1-wrapper] build"
run_capture build "$COMPILER" build "$SRC" -o "$BIN"
[ -x "$BIN" ] || {
    echo "build did not write executable $BIN" >&2
    exit 1
}
assert_contains "$WORKDIR/build.stdout" "Generated: $BIN"

echo "[stage1-wrapper] run"
set +e
"$COMPILER" run "$SRC" > "$WORKDIR/run.stdout" 2> "$WORKDIR/run.stderr"
run_status=$?
set -e
if [ "$run_status" -ne 7 ]; then
    echo "run expected exit 7, got $run_status" >&2
    echo "stdout:" >&2
    sed 's/^/  /' "$WORKDIR/run.stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$WORKDIR/run.stderr" >&2 || true
    exit 1
fi
printf '' > "$WORKDIR/expected.stdout"
if ! cmp -s "$WORKDIR/expected.stdout" "$WORKDIR/run.stdout"; then
    echo "run stdout mismatch" >&2
    exit 1
fi
if [ -s "$WORKDIR/run.stderr" ]; then
    echo "run stderr was not empty" >&2
    sed 's/^/  /' "$WORKDIR/run.stderr" >&2 || true
    exit 1
fi

echo "[stage1-wrapper] debug host-action"
mkdir -p "$(dirname -- "$HOST_ACTION_BIN")"
{
    printf 'typelisp-host-plan v1\n'
    printf 'action build-source\n'
    printf 'source %s:%s\n' "${#SRC}" "$SRC"
    printf 'output %s:%s\n' "${#HOST_ACTION_BIN}" "$HOST_ACTION_BIN"
    printf 'target linux-x86_64\n'
    printf 'backend-mode scalar\n'
    printf 'end\n'
} > "$WORKDIR/host-action.in"
run_capture host-action "$COMPILER" debug host-action < "$WORKDIR/host-action.in"
[ -x "$HOST_ACTION_BIN" ] || {
    echo "debug host-action did not write executable $HOST_ACTION_BIN" >&2
    exit 1
}
assert_contains "$WORKDIR/host-action.stdout" "Generated: $HOST_ACTION_BIN"

cat > "$SCRATCH_ASM" <<'EOF'
.globl _start
_start:
    mov $5, %rdi
    mov $60, %rax
    syscall
EOF
{
    printf 'typelisp-host-plan v1\n'
    printf 'action run-scratch-assembly\n'
    printf 'scratch-assembly-path %s:%s\n' "${#SCRATCH_ASM}" "$SCRATCH_ASM"
    printf 'target linux-x86_64\n'
    printf 'backend-mode scalar\n'
    printf 'end\n'
} > "$WORKDIR/host-action-scratch.in"
set +e
"$COMPILER" debug host-action < "$WORKDIR/host-action-scratch.in" \
    > "$WORKDIR/host-action-scratch.stdout" \
    2> "$WORKDIR/host-action-scratch.stderr"
scratch_status=$?
set -e
if [ "$scratch_status" -ne 5 ]; then
    echo "debug host-action scratch expected exit 5, got $scratch_status" >&2
    echo "stdout:" >&2
    sed 's/^/  /' "$WORKDIR/host-action-scratch.stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$WORKDIR/host-action-scratch.stderr" >&2 || true
    exit 1
fi
[ ! -f "$SCRATCH_ASM" ] || {
    echo "debug host-action scratch did not remove $SCRATCH_ASM" >&2
    exit 1
}

echo "stage1 wrapper smoke passed"
