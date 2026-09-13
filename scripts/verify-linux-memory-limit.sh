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
# A fast-exiting transient service can finish before the user manager publishes
# a positive post-run MemoryPeak even though the cgroup limit was active. Keep
# the two small accounting fixtures alive for one bounded interval. This is
# part of each command's single execution, not a retry of the bounded command.
ACCOUNTING_FIXTURE_SECONDS=1
export ACCOUNTING_FIXTURE_SECONDS
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
        _memory_fixture=$1
        [ -s "$_memory_metrics" ] ||
            fail "Linux memory-limit backend wrote no peak evidence: $_memory_backend"
        _memory_peak=$(sed -n '1p' "$_memory_metrics")
        case "$_memory_peak" in
            "" | *[!0-9]* | 0) fail "malformed peak evidence from $_memory_backend: $_memory_peak" ;;
        esac
        echo "[linux-memory-limit] $_memory_backend $_memory_fixture peak $_memory_peak bytes"
    }

    TYPELISP_MEMORY_LIMIT_SELF_TEST=present
    export TYPELISP_MEMORY_LIMIT_SELF_TEST
    rm -f "$_memory_metrics"
    if ! linux_memory_limit_run "$LIMIT_BYTES" sh -c \
        '[ "$TYPELISP_MEMORY_LIMIT_SELF_TEST" = present ] \
            && [ "$PWD" = "$1" ] \
            && sleep "$2"' \
        sh "$ROOT" "$ACCOUNTING_FIXTURE_SECONDS" \
        > "$_memory_stdout" 2> "$_memory_stderr"; then
        cat "$_memory_stderr" >&2 || true
        fail "Linux memory-limit backend rejected an under-limit command: $_memory_backend"
    fi
    assert_peak_evidence under-limit
    rm -f "$_memory_metrics"
    _memory_status=0
    linux_memory_limit_run "$LIMIT_BYTES" sh -c 'sleep "$1"; exit 23' \
        sh "$ACCOUNTING_FIXTURE_SECONDS" \
        > "$_memory_stdout" 2> "$_memory_stderr" || _memory_status=$?
    [ "$_memory_status" -eq 23 ] || {
        cat "$_memory_stderr" >&2 || true
        fail "Linux memory-limit backend did not forward exit 23: $_memory_backend returned $_memory_status"
    }
    assert_peak_evidence exit-23

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
    assert_peak_evidence over-limit
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

exercise_nested_backend() {
    _nested_backend=$1
    for _nested_mode in inherited metrics report; do
        for _nested_exit in 0 23; do
            _nested_prefix="$WORKDIR/$_nested_backend-$_nested_mode-$_nested_exit"
            _nested_status=0
            TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=$_nested_backend \
                "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 128 \
                --report "$_nested_prefix.outer" -- \
                sh "$WORKDIR/nested.sh" "$ROOT" "$_nested_mode" \
                    "$_nested_exit" "$_nested_prefix.inner" \
                > "$_nested_prefix.stdout" 2> "$_nested_prefix.stderr" || \
                _nested_status=$?
            [ "$_nested_status" -eq "$_nested_exit" ] || {
                cat "$_nested_prefix.stderr" >&2 || true
                fail "nested $_nested_backend/$_nested_mode expected $_nested_exit, got $_nested_status"
            }
            for _nested_marker in outer-before inner-marker outer-after; do
                [ "$(grep -Fxc "$_nested_marker" "$_nested_prefix.stderr")" -eq 1 ] || {
                    cat "$_nested_prefix.stderr" >&2 || true
                    fail "nested $_nested_backend/$_nested_mode lost or repeated $_nested_marker"
                }
            done
            grep -Fxq "exit_code=$_nested_exit" "$_nested_prefix.outer" || \
                fail "nested outer report did not preserve the command status"
            _nested_peak=$(sed -n 's/^peak_memory_bytes=//p' "$_nested_prefix.outer")
            case "$_nested_peak" in
                '' | *[!0-9]* | 0) fail "nested outer report lost peak evidence" ;;
            esac
            case "$_nested_mode" in
                metrics) _nested_peak=$(sed -n '1p' "$_nested_prefix.inner") ;;
                report)
                    grep -Fxq "exit_code=$_nested_exit" "$_nested_prefix.inner" || \
                        fail "nested inner report did not preserve the command status"
                    _nested_peak=$(sed -n 's/^peak_memory_bytes=//p' "$_nested_prefix.inner")
                    ;;
            esac
            case "$_nested_peak" in
                '' | *[!0-9]* | 0) fail "nested inner report lost peak evidence" ;;
            esac
            for _nested_scratch in "$_nested_prefix"*.systemd-stderr*; do
                [ ! -e "$_nested_scratch" ] || \
                    fail "nested helper left scratch stderr evidence: $_nested_scratch"
            done
        done
    done
    # The real full-CI failure also lost systemd's OOM classification. Terminate
    # the outer workload after its nested helper finishes, using a small cap.
    _nested_prefix="$WORKDIR/$_nested_backend-nested-oom"
    _nested_status=0
    TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=$_nested_backend \
        "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 \
        --report "$_nested_prefix.outer" -- \
        sh "$WORKDIR/nested.sh" "$ROOT" inherited 0 \
            "$_nested_prefix.inner" "$ALLOCATE_AWK" \
        > "$_nested_prefix.stdout" 2> "$_nested_prefix.stderr" || \
        _nested_status=$?
    [ "$_nested_status" -eq 137 ] || {
        cat "$_nested_prefix.stderr" >&2 || true
        fail "nested $_nested_backend OOM expected 137, got $_nested_status"
    }
    grep -Fxq 'reason=memory-limit' "$_nested_prefix.outer" || \
        fail "nested outer OOM lost memory-limit classification"
    _nested_peak=$(sed -n 's/^peak_memory_bytes=//p' "$_nested_prefix.outer")
    case "$_nested_peak" in
        '' | *[!0-9]*) fail "nested outer OOM lost peak evidence" ;;
    esac
    [ "$_nested_peak" -ge 33554432 ] || fail "nested outer OOM underreported its peak"
    for _nested_marker in outer-before inner-marker outer-after; do
        [ "$(grep -Fxc "$_nested_marker" "$_nested_prefix.stderr")" -eq 1 ] || \
            fail "nested outer OOM lost or repeated $_nested_marker"
    done
    if [ "$_nested_backend" = systemd-user-cgroup ]; then
        _nested_status=0
        TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE="$WORKDIR/missing/peak" \
            linux_memory_limit_run "$LIMIT_BYTES" sh -c 'echo must-not-run' \
            > "$WORKDIR/scratch-failure.stdout" 2> "$WORKDIR/scratch-failure.stderr" || \
            _nested_status=$?
        [ "$_nested_status" -eq 2 ] || fail "stderr allocation failure did not fail closed"
        [ ! -s "$WORKDIR/scratch-failure.stdout" ] || fail "stderr allocation failure ran the workload"
        grep -Fq 'failed to create invocation stderr evidence' "$WORKDIR/scratch-failure.stderr" || \
            fail "stderr allocation failure lost its actionable diagnostic"
    fi
    echo "[linux-memory-limit] $_nested_backend nested evidence fixtures passed"
}

# Exercise the actual public library and wrapper, including a direct library
# caller which does not request metrics and must not inherit its parent's file.
cat > "$WORKDIR/nested.sh" <<'EOF'
#!/bin/sh
set -eu
cd "$1"
. ./scripts/lib-linux-memory-limit.sh
mode=$2
expected=$3
inner_report=$4
# Direct systemd metrics need the existing stable accounting interval. The
# wrapper's own launch-gated sampler provides positive evidence for its cases.
nested_delay=0.1
if [ "$mode" = metrics ] && [ "${LINUX_MEMORY_LIMIT_BACKEND:-}" = systemd-user-cgroup ]; then
    nested_delay=$ACCOUNTING_FIXTURE_SECONDS
fi
printf 'outer-before\n' >&2
status=0
case "$mode" in
    report)
        scripts/run-memory-bounded.sh --limit-mib 32 --report "$inner_report" -- \
            sh -c 'printf "inner-marker\n" >&2; sleep 0.1; exit "$1"' sh "$expected" || status=$?
        ;;
    inherited | metrics)
        if [ "$mode" = metrics ]; then
            TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE=$inner_report
            export TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
        fi
        linux_memory_limit_run 33554432 \
            sh -c 'printf "inner-marker\n" >&2; sleep "$2"; exit "$1"' sh "$expected" "$nested_delay" || status=$?
        ;;
esac
printf 'outer-after\n' >&2
if [ "$#" -gt 4 ]; then awk "$5"; fi
exit "$status"
EOF

LINUX_MEMORY_LIMIT_BACKEND=
linux_memory_limit_select_backend
selected_backend=$LINUX_MEMORY_LIMIT_BACKEND
echo "[linux-memory-limit] auto-selected $selected_backend"
exercise_backend "$selected_backend"
exercise_nested_backend "$selected_backend"

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
    exercise_nested_backend rss-watchdog
fi

echo "Linux memory-limit helper self-tests passed"
