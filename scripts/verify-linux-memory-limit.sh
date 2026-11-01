#!/usr/bin/env sh
set -eu

# Exercise the user-systemd cgroup backend: status forwarding, complete-tree
# containment, cleanup after an actual over-limit descendant, nested evidence
# through run-memory-bounded.sh, and the invocation hierarchy that keeps
# nested calls inside every enclosing cap (#7793).
#
# Run from inside a bounded workload, every call below nests in that
# workload's cgroup, which is the point of the hierarchy. The fixtures that
# need a top-level systemd unit then report that they did not run; hosted CI
# runs this gate at top level, where all of them run.
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

mkdir -p "$ROOT/target/exp/linux-memory-limit-verify"
WORKDIR=$(mktemp -d "$ROOT/target/exp/linux-memory-limit-verify/run.XXXXXX")

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
    _memory_metrics="$WORKDIR/$_memory_backend-exit-23.peak-bytes"
    TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE=$_memory_metrics
    _memory_status=0
    linux_memory_limit_run "$LIMIT_BYTES" sh -c 'sleep "$1"; exit 23' \
        sh "$ACCOUNTING_FIXTURE_SECONDS" \
        > "$_memory_stdout" 2> "$_memory_stderr" || _memory_status=$?
    [ "$_memory_status" -eq 23 ] || {
        cat "$_memory_stderr" >&2 || true
        fail "Linux memory-limit backend did not forward exit 23: $_memory_backend returned $_memory_status"
    }
    assert_peak_evidence exit-23

    # Arguments reach the command exactly as given (#8082), with or without a
    # metrics destination and through the wrapper: a top-level unit must not
    # expand them, so they match a nested call, which never passes through
    # systemd. An inline shell still expands its own text.
    set -- '' 'two words' '$TYPELISP_MEMORY_LIMIT_SELF_TEST' \
        '${TYPELISP_MEMORY_LIMIT_SELF_TEST}' '${TYPELISP_MEMORY_LIMIT_ABSENT}' \
        '$$' '%n' '$(echo x)' 'key=${source//\//_}'
    printf '<%s>\n' "$@" '${HOME}' present > "$WORKDIR/argv.expected"
    for _memory_argv_route in metrics no-metrics wrapper; do
        _memory_status=0
        (
            [ "$_memory_argv_route" != no-metrics ] ||
                unset TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
            argv_run() {
                if [ "$_memory_argv_route" = wrapper ]; then
                    "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 32 \
                        --report "$WORKDIR/argv-$_memory_backend.report" -- "$@"
                else
                    linux_memory_limit_run "$LIMIT_BYTES" "$@"
                fi
            }
            argv_run printf '<%s>\n' "$@" &&
                argv_run sh -c 'printf "<%s>\n" "$1" "${TYPELISP_MEMORY_LIMIT_SELF_TEST}"' \
                    sh '${HOME}'
        ) > "$WORKDIR/argv.actual" 2> "$_memory_stderr" || _memory_status=$?
        if [ "$_memory_status" -ne 0 ] ||
            ! cmp -s "$WORKDIR/argv.expected" "$WORKDIR/argv.actual"; then
            cat "$_memory_stderr" >&2 || true
            diff "$WORKDIR/argv.expected" "$WORKDIR/argv.actual" >&2 || true
            fail "Linux memory-limit $_memory_argv_route route changed its command's arguments: $_memory_backend"
        fi
    done

    _memory_pid_file="$WORKDIR/$_memory_backend-child.pid"
    _memory_metrics="$WORKDIR/$_memory_backend-oom.peak-bytes"
    TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE=$_memory_metrics
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
    TYPELISP_MEMORY_RACE_AWK=$(command -v awk)
    export TYPELISP_MEMORY_RACE_PS TYPELISP_MEMORY_RACE_AWK
    mkdir -p "$WORKDIR/rss-race-bin"
    cat > "$WORKDIR/rss-race-bin/ps" <<'EOF'
#!/bin/sh
set -eu
[ "$*" = '-e -o pid= -o pgid= -o rss=' ] || exec "$TYPELISP_MEMORY_RACE_PS" "$@"
while read -r line; do
    case $line in 0::*) cgroup="/sys/fs/cgroup${line#0::}" ;; esac
done < /proc/self/cgroup
case $cgroup in */sampler) workload="$cgroup/../workload/tlmem-run" ;; *) exit 1 ;; esac
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
if [ "$TYPELISP_MEMORY_RACE_MODE" = sampling-error ] &&
    [ -e "$TYPELISP_MEMORY_RACE_DIR/excess-sampled" ]; then
    : > "$TYPELISP_MEMORY_RACE_DIR/fail-sample"
fi
read -r pgid < "$TYPELISP_MEMORY_RACE_DIR/pgid"
if [ "$TYPELISP_MEMORY_RACE_MODE" = transient ] &&
    [ -e "$TYPELISP_MEMORY_RACE_DIR/excess-sampled" ]; then
    printf '%s %s 0\n' "$pgid" "$pgid"
else
    : > "$TYPELISP_MEMORY_RACE_DIR/excess-sampled"
    printf '%s %s 65536\n' "$pgid" "$pgid"
fi
EOF
    cat > "$WORKDIR/rss-race-bin/awk" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
    '-v group='*)
        cat > "$TYPELISP_MEMORY_RACE_DIR/sample-input"
        [ ! -e "$TYPELISP_MEMORY_RACE_DIR/fail-sample" ] || exit 1
        exec "$TYPELISP_MEMORY_RACE_AWK" "$@" < "$TYPELISP_MEMORY_RACE_DIR/sample-input"
        ;;
    *) exec "$TYPELISP_MEMORY_RACE_AWK" "$@" ;;
esac
EOF
    cat > "$WORKDIR/rss-race-workload.sh" <<'EOF'
#!/bin/sh
set -eu
while [ ! -e "$TYPELISP_MEMORY_RACE_DIR/start" ]; do sleep 0.01; done
case $TYPELISP_MEMORY_RACE_MODE in
    kernel) exec awk 'BEGIN { s = "x"; while (1) s = s s }' ;;
    rss | transient | sampling-error) exec sleep 30 ;;
esac
EOF
    chmod +x "$WORKDIR/rss-race-bin/ps" "$WORKDIR/rss-race-bin/awk"
    PATH="$WORKDIR/rss-race-bin:$PATH"
    export PATH
    for TYPELISP_MEMORY_RACE_MODE in kernel rss transient sampling-error; do
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
            peak=$(sed -n 's/.*, sampler \([0-9]*\);.*/\1/p' \
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
            case $cgroup in */workload/tlmem-run) ;; *) exit 1 ;; esac
            node=$(dirname "$cgroup")
            read -r cap < "$node/memory.max"
            read -r swap < "$node/memory.swap.max"
            read -r group < "$node/memory.oom.group"
            [ "$cap" = 33554432 ] && [ "$swap" = 0 ] && [ "$group" = 1 ] &&
                [ "$TYPELISP_LINUX_MEMORY_LIMIT_NODE" = "$node" ]
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
        _sampled_peak=$(sed -n 's/.*, sampler \([0-9]*\);.*/\1/p' \
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

    if [ "$SELF_TEST_NESTED" -eq 1 ]; then
        echo "[linux-memory-limit] sampled containment, 20 fast OOMs passed; missing systemd delegation needs a top-level run"
        return 0
    fi
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
    [ "$_nested_status" -eq 2 ] || fail "evidence allocation failure did not fail closed"
    [ ! -s "$WORKDIR/scratch-failure.stdout" ] || fail "evidence allocation failure ran the workload"
    grep -Fq 'failed to create invocation' "$WORKDIR/scratch-failure.stderr" || \
        fail "evidence allocation failure lost its actionable diagnostic"
    echo "[linux-memory-limit] $_nested_backend nested evidence fixtures passed"
}

# #7793: nested library and wrapper calls stay inside every enclosing cap.
# Each scenario of hierarchy.sh runs as the outer workload of a public wrapper
# call (one as a direct library call), holds fixed 1 MiB AWK allocations and
# leaves PID, cgroup and log evidence in its own directory.
exercise_hierarchy() {
    _h_prefix="$WORKDIR/hierarchy"
    # hierarchy_run LABEL SCENARIO LIMIT_MIB [TIMEOUT_SECONDS]
    hierarchy_run() {
        _h_label=$1
        _h_dir="$_h_prefix-$1"
        mkdir "$_h_dir"
        _h_status=0
        "$ROOT/scripts/run-memory-bounded.sh" --limit-mib "$3" \
            --timeout-seconds "${4:-60}" --report "$_h_dir/outer.report" -- \
            sh "$WORKDIR/hierarchy.sh" "$ROOT" "$2" "$_h_dir" \
            > "$_h_dir/stdout" 2> "$_h_dir/stderr" || _h_status=$?
    }
    hierarchy_fail() {
        cat "$_h_dir/stderr" >&2 || true
        cat "$_h_dir/log" >&2 2>/dev/null || true
        fail "hierarchy $_h_label: $*"
    }
    # hierarchy_expect STATUS REASON
    hierarchy_expect() {
        [ "$_h_status" -eq "$1" ] || hierarchy_fail "expected exit $1, got $_h_status"
        grep -Fxq "reason=$2" "$_h_dir/outer.report" ||
            hierarchy_fail "expected outer reason=$2"
    }
    hierarchy_log() {
        grep -Fxq "$1" "$_h_dir/log" 2>/dev/null || hierarchy_fail "missing log line: $1"
    }
    # Every holder that published a PID must be gone soon after the outer
    # call returns; the holders themselves would wait 30 s.
    hierarchy_assert_dead() {
        for _h_pid_file in "$_h_dir"/*.pid; do
            [ -e "$_h_pid_file" ] || continue
            read -r _h_pid < "$_h_pid_file"
            _h_wait=0
            while kill -0 "$_h_pid" 2>/dev/null; do
                [ "$_h_wait" -lt 50 ] ||
                    hierarchy_fail "left holder $(basename "$_h_pid_file" .pid) ($_h_pid) alive"
                _h_wait=$((_h_wait + 1))
                sleep 0.1
            done
        done
    }
    # At least $1 nested holders published a cgroup, each its own node inside
    # the outer workload node.
    hierarchy_assert_inside() {
        _h_outer=$(dirname "$(cat "$_h_dir/outer.cgroup")")
        _h_count=0
        _h_seen=
        for _h_cgroup_file in "$_h_dir"/inner*.cgroup; do
            [ -e "$_h_cgroup_file" ] || continue
            _h_cgroup=$(cat "$_h_cgroup_file")
            case $_h_cgroup in
                "$_h_outer"/tlmem-[0-9]*-[0-9]*/*) ;;
                *) hierarchy_fail "nested holder ran in $_h_cgroup, outside $_h_outer" ;;
            esac
            _h_node=${_h_cgroup#"$_h_outer"/}
            _h_node=${_h_node%%/*}
            case " $_h_seen " in
                *" $_h_node "*) hierarchy_fail "two nested calls shared node $_h_node" ;;
            esac
            _h_seen="$_h_seen $_h_node"
            _h_count=$((_h_count + 1))
        done
        [ "$_h_count" -ge "$1" ] ||
            hierarchy_fail "expected $1 nested holder cgroups, found $_h_count"
    }
    # hierarchy_assert_capped CAP [kernel]: the outer cap ended the workload.
    # Either the kernel OOMed the workload node at its memory.max, whose exact
    # peak then stays within CAP, or, for a wrapper, its sampler's RSS check of
    # the same cap fired first: a nested library call stays in the outer
    # process group, so the sampler counts it, and which check wins is timing.
    # A direct library call has no sampler, so `kernel` requires the OOM.
    hierarchy_assert_capped() {
        _h_peak=$(sed -n 's/.*OOM peak sources: cgroup memory.peak \([0-9]*\) .*/\1/p' \
            "$_h_dir/stderr" | tail -n 1)
        if [ -n "$_h_peak" ]; then
            [ "$_h_peak" -le "$1" ] ||
                hierarchy_fail "outer workload peak $_h_peak exceeds cap $1"
        elif [ "${2:-}" = kernel ] ||
            ! grep -Fq 'memory limit exceeded: aggregate RSS' "$_h_dir/stderr"; then
            hierarchy_fail "outer workload ended without OOM or RSS evidence for cap $1"
        fi
    }

    # Overlapping 40 MiB allocations under a 64 MiB outer cap: outer plus a
    # nested library call, outer plus a nested wrapper call, and two
    # concurrent nested calls. The outer node's limit ends all of it.
    for _h_route in library wrapper parallel; do
        hierarchy_run "overlap-$_h_route" "overlap-$_h_route" 64
        hierarchy_expect 137 memory-limit
        if [ "$_h_route" = parallel ]; then
            hierarchy_assert_inside 2
        else
            hierarchy_assert_inside 1
        fi
        hierarchy_assert_capped 67108864
        hierarchy_assert_dead
    done

    # The same overlap with a direct library call as the outer invocation.
    _h_label=direct-outer
    _h_dir="$_h_prefix-direct-outer"
    mkdir "$_h_dir"
    _h_status=0
    TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE="$_h_dir/outer.peak" \
        linux_memory_limit_run 67108864 \
        sh "$WORKDIR/hierarchy.sh" "$ROOT" overlap-wrapper "$_h_dir" \
        > "$_h_dir/stdout" 2> "$_h_dir/stderr" || _h_status=$?
    [ "$_h_status" -eq 137 ] || hierarchy_fail "expected exit 137, got $_h_status"
    hierarchy_assert_inside 1
    hierarchy_assert_capped 67108864 kernel
    hierarchy_assert_dead

    # Three concurrent 24 MiB holders (outer, library, wrapper) fit a
    # 160 MiB cap. The outer node measures their simultaneous aggregate, and
    # both nested nodes are gone afterwards.
    hierarchy_run parallel parallel 160
    hierarchy_expect 0 success
    hierarchy_assert_inside 2
    hierarchy_log 'nodes 2'
    hierarchy_log 'library 0'
    hierarchy_log 'wrapper 0'
    hierarchy_log 'leftover 0'
    _h_current=$(sed -n 's/^current //p' "$_h_dir/log")
    [ "${_h_current:-0}" -ge 75497472 ] ||
        hierarchy_fail "outer node charged ${_h_current:-0} bytes for three 24 MiB holders"
    _h_peak=$(sed -n 's/^peak_memory_bytes=//p' "$_h_dir/outer.report")
    [ "${_h_peak:-0}" -ge 75497472 ] ||
        hierarchy_fail "outer peak ${_h_peak:-0} misses the nested holders"
    grep -Fxq 'reason=success' "$_h_dir/inner-wrapper.report" ||
        hierarchy_fail "nested wrapper report lost its own result"

    # A nested call's own 16 MiB limit still applies; its OOM fails only that
    # call, and the outer workload continues.
    hierarchy_run inner-oom inner-oom 128
    hierarchy_expect 0 success
    hierarchy_log 'library 137'
    hierarchy_log 'wrapper 137'
    hierarchy_log 'leftover 0'
    grep -Fxq 'reason=memory-limit' "$_h_dir/inner-wrapper.report" ||
        hierarchy_fail "nested wrapper report lost its memory-limit result"

    # A nested wrapper's own timeout ends its holder and node, and the outer
    # workload continues.
    hierarchy_run inner-timeout inner-timeout 128
    hierarchy_expect 0 success
    hierarchy_log 'wrapper 124'
    hierarchy_log 'holder gone'
    hierarchy_log 'leftover 0'
    grep -Fxq 'reason=timeout' "$_h_dir/inner-wrapper.report" ||
        hierarchy_fail "nested wrapper report lost its timeout result"

    # Releasing a node refuses every path but a generated node name under a
    # cgroup path without `.` or `..` components; none of these exist.
    for _h_release in '/sys/fs/cgroup/a/../b tlmem-1-1' '/tmp/a tlmem-1-1' \
        '/sys/fs/cgroup/a tlmem-1-1/..' '/sys/fs/cgroup/a tlmem-1-2-3' \
        '/sys/fs/cgroup/a tlmem-x-1' '/sys/fs/cgroup/a run-1.service' \
        '/sys/fs/cgroup/./a tlmem-1-1'; do
        # shellcheck disable=SC2086 # each case is a parent and a name
        if linux_memory_limit_release_node $_h_release 2> "$WORKDIR/release.stderr"; then
            fail "nested node release accepted unowned cgroup: $_h_release"
        fi
        grep -Fq 'refused to release a cgroup it does not own' "$WORKDIR/release.stderr" ||
            fail "nested node release lost its refusal diagnostic: $_h_release"
    done

    # An outer timeout terminates nested library and wrapper work.
    hierarchy_run timeout hold-nested 128 2
    hierarchy_expect 124 timeout
    [ -s "$_h_dir/inner-library.pid" ] && [ -s "$_h_dir/inner-wrapper.pid" ] ||
        hierarchy_fail "nested holders did not start before the timeout"
    hierarchy_assert_dead

    # Cancelling the outer invocation terminates nested work: stop its unit
    # at top level, or kill its node when this self-test is itself nested.
    _h_label=cancel
    _h_dir="$_h_prefix-cancel"
    mkdir "$_h_dir"
    "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 128 --timeout-seconds 60 \
        --report "$_h_dir/outer.report" -- \
        sh "$WORKDIR/hierarchy.sh" "$ROOT" hold-nested "$_h_dir" \
        > "$_h_dir/stdout" 2> "$_h_dir/stderr" &
    _h_outer_pid=$!
    _h_wait=0
    until [ -e "$_h_dir/inner-library.ready" ] && [ -e "$_h_dir/inner-wrapper.ready" ]; do
        [ "$_h_wait" -lt 200 ] || {
            kill "$_h_outer_pid" 2>/dev/null || true
            hierarchy_fail "nested holders were not ready"
        }
        _h_wait=$((_h_wait + 1))
        sleep 0.05
    done
    _h_invocation=/sys/fs/cgroup$(dirname "$(dirname "$(cat "$_h_dir/outer.cgroup")")")
    case $_h_invocation in
        */run-*.service) systemctl --user stop "$(basename "$_h_invocation")" ;;
        */tlmem-[0-9]*-[0-9]*) printf '1\n' > "$_h_invocation/cgroup.kill" ;;
        *) hierarchy_fail "unexpected outer invocation cgroup $_h_invocation" ;;
    esac
    _h_status=0
    wait "$_h_outer_pid" || _h_status=$?
    [ "$_h_status" -ne 0 ] || hierarchy_fail 'cancelled outer invocation reported success'
    ! grep -Fxq reason=success "$_h_dir/outer.report" ||
        hierarchy_fail 'cancelled outer report claimed success'
    hierarchy_assert_dead

    # Fail closed: a process that left its tlmem-run leaf, and a workload node
    # without memory for its children, run nothing in a nested call.
    for _h_case in lost undelegated; do
        hierarchy_run "$_h_case" "$_h_case" 64
        hierarchy_expect 0 success
        hierarchy_log 'library 2'
        hierarchy_log 'wrapper 2'
        ! grep -Fq must-not-run "$_h_dir/stdout" ||
            hierarchy_fail "an unestablished hierarchy ran its command"
        grep -Fxq 'reason=wrapper-failure' "$_h_dir/$_h_case.report" ||
            hierarchy_fail "nested wrapper lost its wrapper-failure classification"
    done
    grep -Fq 'cannot nest inside bounded workload' "$_h_prefix-lost/stderr" ||
        fail "lost hierarchy lost its actionable diagnostic"
    grep -Fq 'failed to configure nested cgroup' "$_h_prefix-undelegated/stderr" ||
        fail "undelegated workload node lost its actionable diagnostic"

    if [ "$SELF_TEST_NESTED" -eq 1 ]; then
        echo "[linux-memory-limit] hierarchy fixtures passed; an unavailable top-level user manager needs a top-level run"
        return 0
    fi
    # Without a usable user manager a top-level call fails closed.
    mkdir "$WORKDIR/no-systemd"
    printf '#!/bin/sh\nexit 1\n' > "$WORKDIR/no-systemd/systemd-run"
    chmod +x "$WORKDIR/no-systemd/systemd-run"
    _h_status=0
    (
        PATH="$WORKDIR/no-systemd:$PATH"
        LINUX_MEMORY_LIMIT_BACKEND=
        linux_memory_limit_run "$LIMIT_BYTES" sh -c 'echo must-not-run'
    ) > "$WORKDIR/no-systemd.stdout" 2> "$WORKDIR/no-systemd.stderr" || _h_status=$?
    [ "$_h_status" -ne 0 ] && [ ! -s "$WORKDIR/no-systemd.stdout" ] ||
        fail "an unavailable user manager did not fail closed for a library call"
    _h_status=0
    PATH="$WORKDIR/no-systemd:$PATH" "$ROOT/scripts/run-memory-bounded.sh" \
        --limit-mib 32 --report "$WORKDIR/no-systemd.report" -- sh -c 'echo must-not-run' \
        > "$WORKDIR/no-systemd.stdout" 2> "$WORKDIR/no-systemd.stderr" || _h_status=$?
    [ "$_h_status" -eq 2 ] && [ ! -s "$WORKDIR/no-systemd.stdout" ] &&
        grep -Fxq 'reason=wrapper-failure' "$WORKDIR/no-systemd.report" ||
        fail "an unavailable user manager did not fail closed for the wrapper"
    grep -Fq 'requires a usable user systemd manager' "$WORKDIR/no-systemd.stderr" ||
        fail "an unavailable user manager lost its actionable diagnostic"
    echo "[linux-memory-limit] hierarchy and backend-unavailable fixtures passed"
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

# One #7793 hierarchy scenario, run as an outer bounded workload:
# hierarchy.sh ROOT SCENARIO DIR. Allocations are fixed counts of 1 MiB AWK
# strings, every wait is bounded, and evidence goes to DIR.
cat > "$WORKDIR/hierarchy.sh" <<'EOF'
#!/bin/sh
set -u
cd "$1"
scenario=$2
dir=$3
. ./scripts/lib-linux-memory-limit.sh
sed -n 's/^0:://p' /proc/self/cgroup > "$dir/outer.cgroup"
hold_awk='BEGIN {
    chunk = sprintf("%1048576s", "x")
    for (i = 0; i < mib; i++) values[i] = chunk i
    system("touch \"" ready "\"; n=0; while [ ! -e \"" release "\" ] && [ $n -lt 600 ]; do sleep 0.05; n=$((n + 1)); done")
}'
# A holder publishes its PID and cgroup, then holds MIB MiB until the release
# file exists, for at most 30 s.
hold_program='printf "%s\n" "$$" > "$1.pid"
sed -n "s/^0:://p" /proc/self/cgroup > "$1.cgroup"
exec awk -v mib="$2" -v ready="$1.ready" -v release="$3" "$4"'
# hold NAME MIB: a holder in this workload.
hold() {
    sh -c "$hold_program" sh "$dir/$1" "$2" "$dir/release" "$hold_awk"
}
# nest ROUTE NAME MIB LIMIT_MIB [TIMEOUT_SECONDS]: a holder behind a nested
# library or wrapper call with its own LIMIT_MIB cap (and wrapper timeout).
nest() {
    case $1 in
        library)
            linux_memory_limit_run "$(($4 * 1048576))" \
                sh -c "$hold_program" sh "$dir/$2" "$3" "$dir/release" "$hold_awk"
            ;;
        wrapper)
            scripts/run-memory-bounded.sh --limit-mib "$4" --timeout-seconds "${5:-0}" \
                --report "$dir/$2.report" -- \
                sh -c "$hold_program" sh "$dir/$2" "$3" "$dir/release" "$hold_awk"
            ;;
    esac
}
# ready NAME...: wait up to 10 s for each holder's allocation.
ready() {
    for name in "$@"; do
        n=0
        while [ ! -e "$dir/$name.ready" ]; do
            [ "$n" -lt 200 ] || return 1
            n=$((n + 1))
            sleep 0.05
        done
    done
}
# The nested nodes present in this workload's node.
nodes() {
    count=0
    for node in "$TYPELISP_LINUX_MEMORY_LIMIT_NODE"/tlmem-[0-9]*; do
        [ ! -d "$node" ] || count=$((count + 1))
    done
    echo "$count"
}
case $scenario in
    overlap-library | overlap-wrapper | overlap-parallel)
        if [ "$scenario" = overlap-parallel ]; then
            nest library inner-library 40 64 &
            nest wrapper inner-wrapper 40 64 &
        else
            hold outer 40 &
            ready outer || exit 90
            nest "${scenario#overlap-}" inner 40 64 &
        fi
        # The outer cap must end this workload long before this.
        sleep 20
        exit 91
        ;;
    parallel)
        hold outer 24 &
        outer=$!
        nest library inner-library 24 64 &
        library=$!
        nest wrapper inner-wrapper 24 64 &
        wrapper=$!
        ready outer inner-library inner-wrapper || exit 90
        read -r current < "$TYPELISP_LINUX_MEMORY_LIMIT_NODE/memory.current"
        echo "current $current" >> "$dir/log"
        echo "nodes $(nodes)" >> "$dir/log"
        touch "$dir/release"
        status=0
        wait "$library" || status=$?
        echo "library $status" >> "$dir/log"
        status=0
        wait "$wrapper" || status=$?
        echo "wrapper $status" >> "$dir/log"
        wait "$outer"
        echo "leftover $(nodes)" >> "$dir/log"
        ;;
    inner-oom)
        status=0
        nest library inner-library 40 16 || status=$?
        echo "library $status" >> "$dir/log"
        status=0
        nest wrapper inner-wrapper 40 16 || status=$?
        echo "wrapper $status" >> "$dir/log"
        echo "leftover $(nodes)" >> "$dir/log"
        ;;
    inner-timeout)
        # The holder waits 30 s for a release that never comes.
        status=0
        nest wrapper inner-wrapper 8 32 1 || status=$?
        echo "wrapper $status" >> "$dir/log"
        if kill -0 "$(cat "$dir/inner-wrapper.pid")" 2>/dev/null; then
            echo "holder alive" >> "$dir/log"
        else
            echo "holder gone" >> "$dir/log"
        fi
        echo "leftover $(nodes)" >> "$dir/log"
        ;;
    hold-nested)
        nest library inner-library 8 32 &
        nest wrapper inner-wrapper 8 32 &
        # The outer timeout or cancellation must end this workload first.
        sleep 25
        exit 92
        ;;
    lost)
        leaf=/sys/fs/cgroup$(cat "$dir/outer.cgroup")
        mkdir "$leaf/escaped" || exit 90
        sh -c 'echo "$$" > "$1/cgroup.procs" || exit 90; shift; exec "$@"' \
            sh "$leaf/escaped" sh -c '
                . ./scripts/lib-linux-memory-limit.sh
                status=0
                linux_memory_limit_run 33554432 sh -c "echo must-not-run" || status=$?
                echo "library $status" >> "$1/log"
                status=0
                scripts/run-memory-bounded.sh --limit-mib 32 --report "$1/lost.report" -- \
                    sh -c "echo must-not-run" || status=$?
                echo "wrapper $status" >> "$1/log"
            ' sh "$dir"
        ;;
    undelegated)
        echo -memory > "$TYPELISP_LINUX_MEMORY_LIMIT_NODE/cgroup.subtree_control" || exit 90
        status=0
        linux_memory_limit_run 33554432 sh -c 'echo must-not-run' || status=$?
        echo "library $status" >> "$dir/log"
        status=0
        scripts/run-memory-bounded.sh --limit-mib 32 --report "$dir/undelegated.report" -- \
            sh -c 'echo must-not-run' || status=$?
        echo "wrapper $status" >> "$dir/log"
        ;;
    *)
        echo "unknown hierarchy scenario: $scenario" >&2
        exit 2
        ;;
esac
EOF

sh "$ROOT/scripts/verify-linux-memory-terminal.sh"

LINUX_MEMORY_LIMIT_BACKEND=
linux_memory_limit_select_backend
[ "$LINUX_MEMORY_LIMIT_BACKEND" = systemd-user-cgroup ] ||
    fail "Linux memory limiting selected $LINUX_MEMORY_LIMIT_BACKEND, expected systemd-user-cgroup"
linux_memory_limit_enclosing_node ||
    fail "this self-test runs outside the bounded workload it inherited"
SELF_TEST_NESTED=0
if [ -n "$_linux_memory_limit_node" ]; then
    SELF_TEST_NESTED=1
    echo "[linux-memory-limit] running nested inside $_linux_memory_limit_node"
fi
exercise_backend systemd-user-cgroup
exercise_sampled_observation_races
exercise_sampled_backend
exercise_nested_backend systemd-user-cgroup
exercise_hierarchy

echo "Linux memory-limit helper self-tests passed"
