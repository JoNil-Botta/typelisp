#!/usr/bin/env sh
set -eu

# Exercise the user-systemd cgroup backend: status forwarding, complete-tree
# containment, cleanup after an actual over-limit descendant, and nested
# evidence through run-memory-bounded.sh.
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

. "$ROOT/scripts/lib-gate.sh"

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
    echo "[linux-memory-limit] $_memory_backend pass/fail fixtures passed"
}

# Pin the observation order: the workload cannot allocate until the second
# RSS collection, and that collection waits for its kernel OOM before returning.
# A separate RSS-only case keeps the fallback termination path mandatory.
exercise_sampled_observation_races() (
    TYPELISP_MEMORY_RACE_PS=$(command -v ps)
    export TYPELISP_MEMORY_RACE_PS
    mkdir -p "$WORKDIR/rss-race-bin"
    cat > "$WORKDIR/rss-race-bin/ps" <<'EOF'
#!/bin/sh
set -eu
[ "$*" = '-e -o pid= -o pgid= -o rss=' ] || exec "$TYPELISP_MEMORY_RACE_PS" "$@"
while read -r line; do
    case $line in 0::*) cgroup="/sys/fs/cgroup${line#0::}" ;; esac
done < /proc/self/cgroup
case $cgroup in */sampler) workload="$cgroup/../workload" ;; *) exit 1 ;; esac
if mkdir "$TYPELISP_MEMORY_RACE_DIR/first-sample" 2>/dev/null; then
    # Process-group publication can precede the gated child's cgroup move.
    placement=0
    while ! read -r pid < "$workload/cgroup.procs"; do
        [ "$placement" -lt 100 ] || exit 1
        placement=$((placement + 1))
        sleep 0.01
    done
    "$TYPELISP_MEMORY_RACE_PS" -o pgid= -p "$pid" | awk 'NR == 1 { print $1 }' \
        > "$TYPELISP_MEMORY_RACE_DIR/pgid"
    exec "$TYPELISP_MEMORY_RACE_PS" "$@"
fi
: > "$TYPELISP_MEMORY_RACE_DIR/start"
attempt=0
while :; do
    kills=0
    while read -r key value; do
        [ "$key" != oom_kill ] || kills=$value
    done < "$workload/memory.events"
    if [ "$TYPELISP_MEMORY_RACE_MODE" != kernel ] || [ "$kills" -gt 0 ]; then break; fi
    [ "$attempt" -lt 200 ] || exit 1
    attempt=$((attempt + 1))
    sleep 0.01
done
cat "$workload/memory.events" > "$TYPELISP_MEMORY_RACE_DIR/events"
read -r pgid < "$TYPELISP_MEMORY_RACE_DIR/pgid"
if [ "$TYPELISP_MEMORY_RACE_MODE" = transient ] &&
    [ -e "$TYPELISP_MEMORY_RACE_DIR/excess-sampled" ]; then
    printf '%s %s 0\n' "$pgid" "$pgid"
else
    : > "$TYPELISP_MEMORY_RACE_DIR/excess-sampled"
    printf '%s %s 65536\n' "$pgid" "$pgid"
fi
EOF
    cat > "$WORKDIR/rss-race-workload.sh" <<'EOF'
#!/bin/sh
set -eu
while [ ! -e "$TYPELISP_MEMORY_RACE_DIR/start" ]; do sleep 0.01; done
case $TYPELISP_MEMORY_RACE_MODE in
    kernel) exec awk 'BEGIN { s = "x"; while (1) s = s s }' ;;
    rss | transient) exec sleep 30 ;;
esac
EOF
    chmod +x "$WORKDIR/rss-race-bin/ps"
    PATH="$WORKDIR/rss-race-bin:$PATH"
    export PATH
    for TYPELISP_MEMORY_RACE_MODE in kernel rss transient; do
        TYPELISP_MEMORY_RACE_DIR="$WORKDIR/rss-race-$TYPELISP_MEMORY_RACE_MODE"
        export TYPELISP_MEMORY_RACE_MODE TYPELISP_MEMORY_RACE_DIR
        mkdir "$TYPELISP_MEMORY_RACE_DIR"
        status=0
        "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 --timeout-seconds 5 \
            --report "$TYPELISP_MEMORY_RACE_DIR/report" -- \
            sh "$WORKDIR/rss-race-workload.sh" \
            > "$TYPELISP_MEMORY_RACE_DIR/stdout" 2> "$TYPELISP_MEMORY_RACE_DIR/stderr" || status=$?
        [ "$status" -eq 137 ] || {
            cat "$TYPELISP_MEMORY_RACE_DIR/stderr" >&2
            fail "RSS observation fixture $TYPELISP_MEMORY_RACE_MODE returned $status"
        }
        if [ "$TYPELISP_MEMORY_RACE_MODE" = kernel ]; then
            peak=$(sed -n 's/.*systemd summary [0-9]*, sampler \([0-9]*\);.*/\1/p' \
                "$TYPELISP_MEMORY_RACE_DIR/stderr")
            kills=$(sed -n 's/.*(oom_kill \([0-9]*\)).*/\1/p' "$TYPELISP_MEMORY_RACE_DIR/stderr")
            [ "${peak:-0}" -ge 33554432 ] && [ "${kills:-0}" -ge 1 ] ||
                fail "RSS observation race lost the kernel OOM or sampler peak"
            if grep -Fq 'memory limit exceeded: aggregate RSS' "$TYPELISP_MEMORY_RACE_DIR/stderr"; then
                fail "RSS observation race terminated from stale pre-sample OOM state"
            fi
        else
            grep -Fxq 'oom_kill 0' "$TYPELISP_MEMORY_RACE_DIR/events" &&
                grep -Fq 'memory limit exceeded: aggregate RSS' "$TYPELISP_MEMORY_RACE_DIR/stderr" ||
                fail "RSS-only excess lost fallback termination without a kernel OOM"
        fi
    done
    echo '[linux-memory-limit] kernel/RSS observation race and RSS-only termination passed'
)

exercise_sampled_backend() {
    _sampled_prefix="$WORKDIR/sampled"
    "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 \
        --report "$_sampled_prefix.containment" -- sh -c '
            while read -r line; do
                case $line in 0::*) cgroup="/sys/fs/cgroup${line#0::}" ;; esac
            done < /proc/self/cgroup
            case $cgroup in */workload) ;; *) exit 1 ;; esac
            read -r cap < "$cgroup/memory.max"
            read -r swap < "$cgroup/memory.swap.max"
            [ "$cap" = 33554432 ] && [ "$swap" = 0 ]
        ' > "$_sampled_prefix.stdout" 2> "$_sampled_prefix.stderr" || {
            cat "$_sampled_prefix.stderr" >&2 || true
            fail "sampled workload did not enter its exact capped child cgroup"
        }
    _sampled_run=1
    while [ "$_sampled_run" -le 20 ]; do
        _sampled_status=0
        "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 \
            --report "$_sampled_prefix-$_sampled_run.memory" -- \
            awk 'BEGIN { s = "x"; while (1) s = s s }' \
            > "$_sampled_prefix.stdout" 2> "$_sampled_prefix-$_sampled_run.stderr" || \
            _sampled_status=$?
        _sampled_peak=$(sed -n 's/.*systemd summary [0-9]*, sampler \([0-9]*\);.*/\1/p' \
            "$_sampled_prefix-$_sampled_run.stderr")
        _sampled_kills=$(sed -n 's/.*(oom_kill \([0-9]*\)).*/\1/p' \
            "$_sampled_prefix-$_sampled_run.stderr")
        if [ "$_sampled_status" -ne 137 ] ||
            [ "${_sampled_peak:-0}" -lt 33554432 ] ||
            [ "${_sampled_kills:-0}" -lt 1 ]; then
            cat "$_sampled_prefix-$_sampled_run.stderr" >&2 || true
            fail "fast OOM $_sampled_run lost the sampler's own peak or OOM evidence"
        fi
        _sampled_run=$((_sampled_run + 1))
    done
    _sampled_pid="$WORKDIR/sampled-detached.pid"
    _sampled_status=0
    "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 \
        --report "$_sampled_prefix.detached" -- sh -c '
            setsid sleep 30 &
            printf "%s\n" "$!" > "$1"
            awk '\''BEGIN { s = "x"; while (1) s = s s }'\''
        ' sh "$_sampled_pid" > "$_sampled_prefix.stdout" 2> "$_sampled_prefix.stderr" || \
        _sampled_status=$?
    [ "$_sampled_status" -eq 137 ] || fail "detached descendant OOM did not report 137"
    read -r _sampled_child < "$_sampled_pid"
    sleep 0.1
    if kill -0 "$_sampled_child" 2>/dev/null; then
        fail "sampled OOM left detached descendant $_sampled_child alive"
    fi
    for _sampled_exit in 23 124; do
        _sampled_timeout=0
        _sampled_delay=0.1
        if [ "$_sampled_exit" -eq 124 ]; then
            _sampled_timeout=1
            _sampled_delay=30
        fi
        _sampled_status=0
        "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 \
            --timeout-seconds "$_sampled_timeout" \
            --report "$_sampled_prefix.detached-$_sampled_exit" -- sh -c '
                setsid sleep 30 &
                printf "%s\n" "$!" > "$1"
                sleep "$2"
                exit 23
            ' sh "$_sampled_pid" "$_sampled_delay" \
            > "$_sampled_prefix.stdout" 2> "$_sampled_prefix.stderr" || \
            _sampled_status=$?
        [ "$_sampled_status" -eq "$_sampled_exit" ] || \
            fail "sampled descendant cleanup changed exit $_sampled_exit to $_sampled_status"
        read -r _sampled_child < "$_sampled_pid"
        sleep 0.1
        if kill -0 "$_sampled_child" 2>/dev/null; then
            fail "sampled exit $_sampled_exit left detached descendant $_sampled_child alive"
        fi
    done

    _sampled_status=0
    linux_memory_limit_run_sampled 9223372036854775807 sh -c 'echo must-not-run' \
        > "$_sampled_prefix.stdout" 2> "$_sampled_prefix.stderr" || \
        _sampled_status=$?
    [ "$_sampled_status" -eq 2 ] || fail "sampler headroom overflow did not fail closed"
    [ ! -s "$_sampled_prefix.stdout" ] || fail "sampler headroom overflow ran the workload"
    grep -Fq 'cannot reserve sampler headroom' "$_sampled_prefix.stderr" || \
        fail "sampler headroom overflow lost its actionable diagnostic"

    # Simulate an unavailable delegation property while preserving systemd's
    # actual hard parent cap. No requested workload may start on this path.
    _sampled_systemd=$(command -v systemd-run)
    mkdir "$WORKDIR/no-delegation"
    cat > "$WORKDIR/no-delegation/systemd-run" <<'EOF'
#!/bin/sh
remaining=$#
while [ "$remaining" -gt 0 ]; do
    arg=$1
    shift
    case $arg in
        --property=DelegateSubgroup=sampler) ;;
        *) set -- "$@" "$arg" ;;
    esac
    remaining=$((remaining - 1))
done
exec "$TYPELISP_MEMORY_TEST_SYSTEMD_RUN" "$@"
EOF
    chmod +x "$WORKDIR/no-delegation/systemd-run"
    _sampled_status=0
    PATH="$WORKDIR/no-delegation:$PATH" \
        TYPELISP_MEMORY_TEST_SYSTEMD_RUN=$_sampled_systemd \
        "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 \
        --report "$_sampled_prefix.no-delegation" -- sh -c 'echo must-not-run' \
        > "$_sampled_prefix.stdout" 2> "$_sampled_prefix.stderr" || \
        _sampled_status=$?
    [ "$_sampled_status" -eq 2 ] || fail "missing delegation did not fail closed"
    [ ! -s "$_sampled_prefix.stdout" ] || fail "missing delegation ran the workload"
    grep -Fq 'requires systemd DelegateSubgroup=sampler' "$_sampled_prefix.stderr" || \
        fail "missing delegation lost its actionable diagnostic"
    grep -Fxq 'reason=wrapper-failure' "$_sampled_prefix.no-delegation" || \
        fail "missing delegation lost wrapper-failure classification"
    echo "[linux-memory-limit] sampled containment, 20 fast OOMs and missing delegation passed"
}

exercise_nested_backend() {
    _nested_backend=$1
    assert_no_nested_scratch() {
        for _nested_scratch in "$_nested_prefix"*.systemd-stderr* \
            "$_nested_prefix"*.cgroup-peak*; do
            [ ! -e "$_nested_scratch" ] || \
                fail "nested helper left scratch evidence: $_nested_scratch"
        done
    }
    for _nested_mode in inherited metrics report; do
        for _nested_exit in 0 23; do
            _nested_prefix="$WORKDIR/$_nested_backend-$_nested_mode-$_nested_exit"
            _nested_status=0
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
            assert_no_nested_scratch
        done
    done
    # A nested run must also keep systemd's OOM classification. Terminate the
    # outer workload after its nested helper finishes, using a small cap.
    _nested_prefix="$WORKDIR/$_nested_backend-nested-oom"
    _nested_status=0
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
    [ "$_nested_peak" -ge 33554432 ] || {
        cat "$_nested_prefix.outer" >&2 || true
        tail -n 20 "$_nested_prefix.stderr" >&2 || true
        # Who killed the unit: the kernel's cgroup OOM killer counts in
        # memory.events, systemd-oomd logs its own kills (#8142).
        _nested_unit=$(sed -n 's/^Running as unit: \([^;]*\).*/\1/p' "$_nested_prefix.stderr" | tail -n 1)
        journalctl --user --no-pager -o short-monotonic -u "$_nested_unit" 2>&1 |
            tail -n 20 >&2 || true
        journalctl --no-pager -o short-monotonic -u systemd-oomd --since=-10min 2>&1 |
            tail -n 20 >&2 || true
        oomctl 2>&1 | head -n 30 >&2 || true
        cat /proc/pressure/memory >&2 2>/dev/null || true
        journalctl -k --no-pager -o short-monotonic --since=-10min 2>&1 |
            grep -i -E 'oom|memory cgroup|killed process' | tail -n 20 >&2 || true
        fail "nested outer OOM underreported its peak"
    }
    assert_no_nested_scratch
    for _nested_marker in outer-before inner-marker outer-after; do
        [ "$(grep -Fxc "$_nested_marker" "$_nested_prefix.stderr")" -eq 1 ] || \
            fail "nested outer OOM lost or repeated $_nested_marker"
    done
    _nested_status=0
    TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE="$WORKDIR/missing/peak" \
        linux_memory_limit_run "$LIMIT_BYTES" sh -c 'echo must-not-run' \
        > "$WORKDIR/scratch-failure.stdout" 2> "$WORKDIR/scratch-failure.stderr" || \
        _nested_status=$?
    [ "$_nested_status" -eq 2 ] || fail "stderr allocation failure did not fail closed"
    [ ! -s "$WORKDIR/scratch-failure.stdout" ] || fail "stderr allocation failure ran the workload"
    grep -Fq 'failed to create invocation stderr evidence' "$WORKDIR/scratch-failure.stderr" || \
        fail "stderr allocation failure lost its actionable diagnostic"
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
if [ "$mode" = metrics ]; then
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
[ "$LINUX_MEMORY_LIMIT_BACKEND" = systemd-user-cgroup ] ||
    fail "Linux memory limiting selected $LINUX_MEMORY_LIMIT_BACKEND, expected systemd-user-cgroup"
exercise_backend systemd-user-cgroup
exercise_sampled_observation_races
exercise_sampled_backend
exercise_nested_backend systemd-user-cgroup

echo "Linux memory-limit helper self-tests passed"
