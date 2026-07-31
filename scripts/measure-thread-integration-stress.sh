#!/usr/bin/env sh
set -eu

# Build the safe-thread integration fixtures once, then run the native
# executables repeatedly. This is an optional local reproducer, not a CI gate.
#
# Useful controls:
#   TYPELISP_THREAD_STRESS_ITERATIONS  runs per fixture (default: 100)
#   TYPELISP_THREAD_STRESS_JOBS        concurrent processes (default: 1)
#   TYPELISP_THREAD_STRESS_TIMEOUT_SECONDS
#                                      timeout per process (default: 10)
#   TYPELISP_THREAD_STRESS_CPU         Linux taskset CPU list (default: unset)
#   TYPELISP_THREAD_STRESS_CASES       whitespace-separated fixture basenames
#   TYPELISP_THREAD_STRESS_OPT_LEVEL   0, 1, or 2 (default: 2)
#
# Every run retains its exact exit code, stdout, and stderr under
# target/thread-integration-stress so an intermittent failure is diagnosable.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/measure-thread-integration-stress.sh

Build and repeatedly run all safe-thread native integration fixtures.
Configure the run with the TYPELISP_THREAD_STRESS_* environment variables
documented at the top of this script.
EOF
}

case "${1:-}" in
    "")
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

HOST_OS=linux
TARGET=linux-x86_64
EXE_SUFFIX=
case "$(uname -s)" in
    Linux*)
        ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        TARGET=windows-x86_64
        EXE_SUFFIX=.exe
        ;;
    *)
        echo "thread integration stress is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi
command -v sha256sum >/dev/null 2>&1 || {
    echo "thread integration stress requires sha256sum" >&2
    exit 1
}
command -v timeout >/dev/null 2>&1 || {
    echo "thread integration stress requires timeout" >&2
    exit 1
}

ITERATIONS=${TYPELISP_THREAD_STRESS_ITERATIONS:-100}
JOBS=${TYPELISP_THREAD_STRESS_JOBS:-1}
TIMEOUT_SECONDS=${TYPELISP_THREAD_STRESS_TIMEOUT_SECONDS:-10}
CPU_LIST=${TYPELISP_THREAD_STRESS_CPU:-}
OPT_LEVEL=${TYPELISP_THREAD_STRESS_OPT_LEVEL:-2}
CASES=${TYPELISP_THREAD_STRESS_CASES:-"
thread_safe_i64
thread_safe_bool_unit
thread_safe_unit
thread_safe_aggregate_capture
thread_safe_string
thread_safe_i64_vec
thread_safe_box_i64
"}

require_positive_integer() {
    _value=$1
    _name=$2
    case "$_value" in
        "" | *[!0-9]* | 0)
            echo "$_name must be a positive integer" >&2
            exit 2
            ;;
    esac
}

require_positive_integer "$ITERATIONS" TYPELISP_THREAD_STRESS_ITERATIONS
require_positive_integer "$JOBS" TYPELISP_THREAD_STRESS_JOBS
require_positive_integer \
    "$TIMEOUT_SECONDS" \
    TYPELISP_THREAD_STRESS_TIMEOUT_SECONDS
if [ "$JOBS" -gt 64 ]; then
    echo "TYPELISP_THREAD_STRESS_JOBS must be at most 64" >&2
    exit 2
fi
case "$OPT_LEVEL" in
    0 | 1 | 2) ;;
    *)
        echo "TYPELISP_THREAD_STRESS_OPT_LEVEL must be 0, 1, or 2" >&2
        exit 2
        ;;
esac
if [ -n "$CPU_LIST" ]; then
    if [ "$HOST_OS" != linux ]; then
        echo "TYPELISP_THREAD_STRESS_CPU is supported only on Linux" >&2
        exit 2
    fi
    command -v taskset >/dev/null 2>&1 || {
        echo "TYPELISP_THREAD_STRESS_CPU requires taskset" >&2
        exit 1
    }
fi

case_supported() {
    case "$1" in
        thread_safe_i64 | \
        thread_safe_bool_unit | \
        thread_safe_unit | \
        thread_safe_aggregate_capture | \
        thread_safe_string | \
        thread_safe_i64_vec | \
        thread_safe_box_i64)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

CASE_COUNT=0
for CASE_NAME in $CASES; do
    if ! case_supported "$CASE_NAME"; then
        echo "unsupported thread stress case: $CASE_NAME" >&2
        exit 2
    fi
    CASE_COUNT=$((CASE_COUNT + 1))
done
if [ "$CASE_COUNT" -eq 0 ]; then
    echo "TYPELISP_THREAD_STRESS_CASES selected no fixtures" >&2
    exit 2
fi

WORKDIR="$ROOT/target/thread-integration-stress/$HOST_OS"
case "$WORKDIR" in
    "$ROOT"/target/thread-integration-stress/*) ;;
    *)
        echo "refusing unsafe thread stress work directory: $WORKDIR" >&2
        exit 1
        ;;
esac
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/bin" "$WORKDIR/runs"

echo "[thread-stress] host=$HOST_OS target=$TARGET opt=$OPT_LEVEL"
echo "[thread-stress] fixtures=$CASE_COUNT iterations=$ITERATIONS jobs=$JOBS"
if [ -n "$CPU_LIST" ]; then
    echo "[thread-stress] taskset CPUs=$CPU_LIST"
fi

for CASE_NAME in $CASES; do
    SOURCE="$ROOT/tests/integration/$CASE_NAME.tl"
    BIN="$WORKDIR/bin/$CASE_NAME$EXE_SUFFIX"
    echo "[thread-stress] build $CASE_NAME"
    "$COMPILER" build "$SOURCE" \
        -o "$BIN" \
        --target "$TARGET" \
        --opt-level "$OPT_LEVEL" \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src"
    sha256sum "$BIN" > "$WORKDIR/bin/$CASE_NAME.sha256"
done

report_stream() {
    _label=$1
    _path=$2
    if [ -s "$_path" ]; then
        echo "  $_label:" >&2
        sed 's/^/    /' "$_path" >&2
    else
        echo "  $_label: <empty>" >&2
    fi
}

report_failure() {
    _case=$1
    _iteration=$2
    _prefix="$WORKDIR/runs/$_case.$_iteration"
    _exit=$(cat "$_prefix.exit" 2>/dev/null || printf '%s' missing)
    echo "FAIL: $_case iteration $_iteration expected exit 42 with no output, got $_exit" >&2
    sed 's/^/  binary /' "$WORKDIR/bin/$_case.sha256" >&2
    report_stream stdout "$_prefix.stdout"
    report_stream stderr "$_prefix.stderr"
    echo "  artifacts: $_prefix.{exit,stdout,stderr}" >&2
}

ACTIVE_RECORDS=
ACTIVE_COUNT=0

launch_run() {
    _case=$1
    _iteration=$2
    _bin="$WORKDIR/bin/$_case$EXE_SUFFIX"
    _prefix="$WORKDIR/runs/$_case.$_iteration"
    (
        set +e
        if [ -n "$CPU_LIST" ]; then
            timeout "${TIMEOUT_SECONDS}s" \
                taskset -c "$CPU_LIST" "$_bin" \
                > "$_prefix.stdout" 2> "$_prefix.stderr"
        else
            timeout "${TIMEOUT_SECONDS}s" "$_bin" \
                > "$_prefix.stdout" 2> "$_prefix.stderr"
        fi
        _exit=$?
        set -e
        printf '%s\n' "$_exit" > "$_prefix.exit"
        if [ "$_exit" -eq 42 ] &&
            [ ! -s "$_prefix.stdout" ] &&
            [ ! -s "$_prefix.stderr" ]; then
            exit 0
        fi
        exit 1
    ) &
    _pid=$!
    ACTIVE_RECORDS="${ACTIVE_RECORDS}${ACTIVE_RECORDS:+ }$_pid|$_case|$_iteration"
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
}

wait_batch() {
    _batch_failed=0
    for _record in $ACTIVE_RECORDS; do
        _saved_ifs=$IFS
        IFS='|'
        set -- $_record
        IFS=$_saved_ifs
        _pid=$1
        _case=$2
        _iteration=$3
        set +e
        wait "$_pid"
        _wait_status=$?
        set -e
        if [ "$_wait_status" -ne 0 ]; then
            report_failure "$_case" "$_iteration"
            _batch_failed=1
        fi
    done
    ACTIVE_RECORDS=
    ACTIVE_COUNT=0
    [ "$_batch_failed" -eq 0 ]
}

ITERATION=1
while [ "$ITERATION" -le "$ITERATIONS" ]; do
    for CASE_NAME in $CASES; do
        launch_run "$CASE_NAME" "$ITERATION"
        if [ "$ACTIVE_COUNT" -ge "$JOBS" ]; then
            if ! wait_batch; then
                echo "[thread-stress] failure artifacts retained under $WORKDIR" >&2
                exit 1
            fi
        fi
    done
    ITERATION=$((ITERATION + 1))
done
if [ "$ACTIVE_COUNT" -gt 0 ]; then
    if ! wait_batch; then
        echo "[thread-stress] failure artifacts retained under $WORKDIR" >&2
        exit 1
    fi
fi

TOTAL_RUNS=$((CASE_COUNT * ITERATIONS))
echo "[thread-stress] PASS: $TOTAL_RUNS native runs; artifacts retained under $WORKDIR"
