#!/usr/bin/env sh
set -eu

# verify-process-runtime-linux.sh - deterministic Linux process syscall,
# exec-channel, capture, reaping, and cleanup fault coverage.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "process runtime fault verification is Linux-only"
        exit 0
        ;;
esac

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
gate_compiler
gate_compiler_absolute

[ -x "$COMPILER" ] || {
    echo "process runtime compiler is not executable: $COMPILER" >&2
    exit 1
}

WORKDIR="$ROOT/target/process-runtime-linux-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SOURCE="$ROOT/tests/integration/process_runtime_linux_failures.tl"
for MODE in faults concurrency; do
    ASM="$WORKDIR/$MODE.s"
    OBJ="$WORKDIR/$MODE.o"
    BIN="$WORKDIR/$MODE"
    case "$MODE" in
        faults) CFG=process-linux-test-hooks ;;
        concurrency) CFG=process-child-concurrency-test ;;
    esac
    echo "[process-runtime-linux] compile assembly fallback: $MODE"
    "$COMPILER" compile "$SOURCE" -o "$ASM" \
        --target linux-x86_64 --backend-mode scalar \
        --cfg "$CFG" --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT" \
        > "$WORKDIR/$MODE.compile.stdout" 2> "$WORKDIR/$MODE.compile.stderr" || {
            cat "$WORKDIR/$MODE.compile.stdout" "$WORKDIR/$MODE.compile.stderr" >&2
            fail "$MODE fixture compile failed"
        }
    assemble_and_link "$MODE" "$ASM" "$OBJ" "$BIN"

    set +e
    "$BIN" > "$WORKDIR/$MODE.stdout" 2> "$WORKDIR/$MODE.stderr"
    STATUS=$?
    set -e
    [ "$STATUS" -eq 42 ] || {
        cat "$WORKDIR/$MODE.stdout" "$WORKDIR/$MODE.stderr" >&2
        fail "$MODE fixture expected exit 42, got $STATUS"
    }
    [ ! -s "$WORKDIR/$MODE.stderr" ] || {
        cat "$WORKDIR/$MODE.stderr" >&2
        fail "$MODE fixture wrote stderr"
    }
    [ "$(wc -l < "$WORKDIR/$MODE.stdout")" -eq 1 ] ||
        fail "$MODE fixture did not write one metrics line"
    METRICS=$(sed -n '1p' "$WORKDIR/$MODE.stdout")
    case "$MODE:$METRICS" in
        "faults:process-linux-metrics ticks="*" alloc-bytes="*" fds="*" zombies=0 syscalls=15") ;;
        "concurrency:process-linux-concurrency workers=4 starts=128 failed-execs=128 zombies=0") ;;
        *) fail "unexpected $MODE metrics: $METRICS" ;;
    esac
    echo "[process-runtime-linux] $METRICS"
done
echo "Process runtime Linux verification passed"
