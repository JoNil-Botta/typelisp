#!/usr/bin/env sh
set -eu

# Exercise backend selection, status forwarding, complete-tree containment,
# and cleanup after an actual over-limit descendant.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-memory-limit.sh"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "Linux memory-limit verification is unsupported on this host" >&2
        exit 1
        ;;
esac

WORKDIR="$ROOT/target/linux-memory-limit-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "$*" >&2
    exit 1
}

LIMIT_BYTES=33554432
ALLOCATE_AWK='BEGIN {
    chunk = sprintf("%1048576s", "x")
    for (i = 0; i < 96; i++) values[i] = chunk i
    system("sleep 30")
}'

exercise_backend() {
    _memory_backend=$1
    _memory_stdout="$WORKDIR/$_memory_backend.stdout"
    _memory_stderr="$WORKDIR/$_memory_backend.stderr"
    _memory_metrics="$WORKDIR/$_memory_backend.peak-bytes"
    TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE=$_memory_metrics
    export TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE

    assert_peak_evidence() {
        [ -s "$_memory_metrics" ] ||
            fail "Linux memory-limit backend wrote no peak evidence: $_memory_backend"
        _memory_peak=$(sed -n '1p' "$_memory_metrics")
        case "$_memory_peak" in
            "" | *[!0-9]* | 0) fail "malformed peak evidence from $_memory_backend: $_memory_peak" ;;
        esac
    }

    TYPELISP_MEMORY_LIMIT_SELF_TEST=present
    export TYPELISP_MEMORY_LIMIT_SELF_TEST
    rm -f "$_memory_metrics"
    if ! linux_memory_limit_run "$LIMIT_BYTES" sh -c \
        '[ "$TYPELISP_MEMORY_LIMIT_SELF_TEST" = present ] && [ "$PWD" = "$1" ]' \
        sh "$ROOT" \
        > "$_memory_stdout" 2> "$_memory_stderr"; then
        cat "$_memory_stderr" >&2 || true
        fail "Linux memory-limit backend rejected an under-limit command: $_memory_backend"
    fi
    assert_peak_evidence
    rm -f "$_memory_metrics"
    _memory_status=0
    linux_memory_limit_run "$LIMIT_BYTES" sh -c 'exit 23' \
        > "$_memory_stdout" 2> "$_memory_stderr" || _memory_status=$?
    [ "$_memory_status" -eq 23 ] || {
        cat "$_memory_stderr" >&2 || true
        fail "Linux memory-limit backend did not forward exit 23: $_memory_backend returned $_memory_status"
    }
    assert_peak_evidence

    _memory_pid_file="$WORKDIR/$_memory_backend-child.pid"
    rm -f "$_memory_pid_file" "$_memory_metrics"
    _memory_status=0
    linux_memory_limit_run "$LIMIT_BYTES" sh -c '
        awk "$1" &
        child=$!
        printf "%s\n" "$child" > "$2"
        wait "$child"
    ' sh "$ALLOCATE_AWK" "$_memory_pid_file" \
        > "$_memory_stdout" 2> "$_memory_stderr" || _memory_status=$?
    if [ "$_memory_status" -eq 0 ]; then
        fail "Linux memory-limit backend accepted an over-limit command: $_memory_backend"
    fi
    assert_peak_evidence
    [ -s "$_memory_pid_file" ] ||
        fail "over-limit child did not publish its PID: $_memory_backend"
    _memory_child_pid=$(sed -n '1p' "$_memory_pid_file")
    case "$_memory_child_pid" in
        "" | *[!0-9]*) fail "over-limit child published malformed PID: $_memory_child_pid" ;;
    esac
    sleep 0.1
    if kill -0 "$_memory_child_pid" 2>/dev/null; then
        fail "Linux memory-limit backend left child $_memory_child_pid alive: $_memory_backend"
    fi
    if [ "$_memory_backend" = rss-watchdog ] \
        && ! grep -q 'memory limit exceeded: aggregate RSS' "$_memory_stderr"; then
        cat "$_memory_stderr" >&2 || true
        fail "RSS watchdog did not report its measured over-limit failure"
    fi
    echo "[linux-memory-limit] $_memory_backend pass/fail fixtures passed"
}

LINUX_MEMORY_LIMIT_BACKEND=
linux_memory_limit_select_backend
selected_backend=$LINUX_MEMORY_LIMIT_BACKEND
echo "[linux-memory-limit] auto-selected $selected_backend"
exercise_backend "$selected_backend"

# A usable systemd manager is host-dependent, but the portable fallback is a
# required path everywhere. Force it when auto-selection exercised systemd.
if [ "$selected_backend" != rss-watchdog ]; then
    LINUX_MEMORY_LIMIT_BACKEND=
    TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=rss-watchdog
    export TYPELISP_LINUX_MEMORY_LIMIT_BACKEND
    linux_memory_limit_select_backend
    [ "$LINUX_MEMORY_LIMIT_BACKEND" = rss-watchdog ] \
        || fail "forced RSS watchdog selection returned $LINUX_MEMORY_LIMIT_BACKEND"
    exercise_backend rss-watchdog
fi

echo "Linux memory-limit helper self-tests passed"
