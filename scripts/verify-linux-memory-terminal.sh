#!/usr/bin/env sh
set -eu

# Part of verify-linux-memory-limit.sh: terminal evidence, without a compiler.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-gate.sh"
. "$ROOT/scripts/lib-linux-memory-limit.sh"
linux_memory_limit_enclosing_node || exit 2
if [ -n "$_linux_memory_limit_node" ]; then
    echo '[linux-memory-limit] terminal launcher fixtures require a top-level run; nested calls use ordinary child waits'
    exit 0
fi
mkdir -p "$ROOT/target/exp/linux-memory-terminal"
WORKDIR=$(mktemp -d "$ROOT/target/exp/linux-memory-terminal/run.XXXXXX")
echo "[linux-memory-limit] terminal evidence: $WORKDIR"
mkdir "$WORKDIR/bin"

# Model the systemd launcher only. Execute the real private waiter, then vary
# its terminal record or launcher status. No fixture allocates unbounded work.
cat > "$WORKDIR/bin/systemd-run" <<'EOF'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
[ "$#" -gt 0 ] || exit 90
shift
case ${3:-} in 'unset _tlmem_terminal '*) ;; *) exit 0 ;; esac # capability probe
[ "$1:$2:$4" = sh:-c:sh ] || exit 91
program=$3
shift 4
terminal=$1
owner=$2
printf '%s\n' "$terminal" > "$TERMINAL_CASE/terminal-path"
if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
    case ${TERMINAL_PEAK:-positive} in
        positive) printf '4194304\n' > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE" ;;
        zero) printf '0\n' > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE" ;;
        unavailable) : > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE" ;;
    esac
fi
status=0
case $TERMINAL_MODE in
    missing | known-7 | timeout | oom) ;;
    *)
        sh -c "$program" sh "$terminal" "$owner" sh -c '
            case $1 in
                exit-7) exit 7 ;;
                exit-2) exit 2 ;;
                term) kill -TERM "$$" ;;
                kill) kill -KILL "$$" ;;
            esac
        ' sh "$TERMINAL_MODE" || status=$?
        ;;
esac
case $TERMINAL_MODE in
    absent)
        case $terminal in
            "${TERMINAL_CASE:?}"/tmp/typelisp-memory-limit.??????/terminal | \
                "${TERMINAL_CASE:?}"/typelisp-memory-limit.??????/terminal) rm -- "${terminal:?}" ;;
            *) exit 93 ;;
        esac
        ;;
    malformed) printf 'garbage\n' > "$terminal" ;;
    mismatch) printf 'tlmem-terminal-v1 foreign 0\n' > "$terminal" ;;
    range) printf 'tlmem-terminal-v1 %s 256\n' "$owner" > "$terminal" ;;
    duplicate) printf 'tlmem-terminal-v1 %s 0\n' "$owner" >> "$terminal" ;;
    truncated) printf 'tlmem-terminal-v1 %s 0' "$owner" > "$terminal" ;;
    swapped)
        cp "$terminal" "$TERMINAL_CASE/own-record"
        n=0
        while [ ! -s "$TERMINAL_PEER/own-record" ]; do
            [ "$n" -lt 200 ] || exit 92
            n=$((n + 1)); sleep 0.01
        done
        cp "$TERMINAL_PEER/own-record" "$terminal"
        ;;
    known-7) exit 7 ;;
    timeout) exit 124 ;;
    oom)
        printf 'ran\nkills 1\npeak 33554432\n' > "$TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE"
        echo 'Finished with result: oom-kill' >&2
        exit 0
        ;;
esac
# Also verify the status record can recover exit 7 from a zero launcher.
[ "$TERMINAL_MODE" != exit-7 ] || exit 0
exit "$status"
EOF
chmod +x "$WORKDIR/bin/systemd-run"

# route-run ROUTE: public wrappers always own their report.memory destination;
# the optional caller metrics path must remain untouched on that route.
route_run() (
    route=$1
    if [ "${route#*-}" = metrics ]; then
        TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE="$TERMINAL_CASE/caller-peak"
        export TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
        printf 'caller-owned\n' > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
    else
        unset TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
    fi
    case $route in
        library-*)
            . "$ROOT/scripts/lib-linux-memory-limit.sh"
            LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup
            route_rc=0
            linux_memory_limit_run 67108864 sh -c 'exit 0' || route_rc=$?
            printf '%s\n' "$LINUX_MEMORY_LIMIT_REASON" > "$TERMINAL_CASE/library-reason"
            exit "$route_rc"
            ;;
        wrapper-*)
            "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 64 \
                --timeout-seconds 10 --report "$TERMINAL_CASE/report" -- sh -c 'exit 0'
            ;;
    esac
)

assert_case() {
    expected_reason=wrapper-failure
    case $TERMINAL_MODE in
        valid | real-valid | real-stdin | stderr) expected_reason=success ;;
        exit-2 | exit-7 | term | real-exit-2 | real-exit-7 | real-term | real-int | real-quit)
            expected_reason=command-failure ;;
        kill | oom | real-kill | real-oom) expected_reason=memory-limit ;;
        timeout | real-timeout) expected_reason=timeout ;;
    esac
    [ "$terminal_status" -eq "$expected" ] || {
        cat "$TERMINAL_CASE/stderr" >&2
        fail "terminal $route/$TERMINAL_MODE expected $expected, got $terminal_status"
    }
    if [ "$expected" -eq 2 ] && [ "$TERMINAL_MODE" != real-exit-2 ] && [ "$TERMINAL_MODE" != exit-2 ]; then
        grep -Fq 'invocation terminal evidence' "$TERMINAL_CASE/stderr" ||
            fail "terminal $route/$TERMINAL_MODE lost its diagnostic"
    fi
    case $route in
        wrapper-*)
            grep -Fxq "exit_code=$expected" "$TERMINAL_CASE/report" ||
                fail 'terminal wrapper report lost its status'
            grep -Fxq "reason=$expected_reason" "$TERMINAL_CASE/report" ||
                fail "terminal wrapper $TERMINAL_MODE lost its reason $expected_reason"
            if [ "$expected" -ne 0 ]; then
                ! grep -Fxq reason=success "$TERMINAL_CASE/report" ||
                    fail 'terminal wrapper reported false success'
            fi
            ;;
        library-*)
            [ "$(cat "$TERMINAL_CASE/library-reason")" = "$expected_reason" ] ||
                fail "terminal library $TERMINAL_MODE lost its reason $expected_reason"
            ;;
    esac
    if [ "$route" = wrapper-metrics ]; then
        grep -Fxq caller-owned "$TERMINAL_CASE/caller-peak" ||
            fail 'terminal wrapper consumed inherited caller metrics'
    fi
    # A killed sampler cannot clean its older launch gate; the outer backend
    # must still remove its own terminal/stderr/peak records after unit stop.
    for evidence in "$TERMINAL_CASE/tmp"/typelisp-memory-limit.* \
        "$TERMINAL_CASE"/typelisp-memory-limit.*; do
        [ ! -e "$evidence" ] || fail 'terminal helper left private evidence after return'
    done
}

for route in library-none library-metrics wrapper-none wrapper-metrics; do
    for TERMINAL_MODE in valid missing absent malformed mismatch range duplicate truncated \
        exit-2 exit-7 term kill known-7 timeout oom; do
        TERMINAL_CASE="$WORKDIR/$route-$TERMINAL_MODE"
        mkdir -p "$TERMINAL_CASE/tmp"
        expected=2
        case $TERMINAL_MODE in
            valid) expected=0 ;;
            exit-2) expected=2 ;;
            exit-7 | known-7) expected=7 ;;
            term) expected=143 ;;
            kill | oom) expected=137 ;;
            timeout) expected=124 ;;
        esac
        terminal_status=0
        PATH="$WORKDIR/bin:$PATH" TMPDIR="$TERMINAL_CASE/tmp" \
            TERMINAL_MODE=$TERMINAL_MODE TERMINAL_CASE=$TERMINAL_CASE \
            route_run "$route" > "$TERMINAL_CASE/stdout" 2> "$TERMINAL_CASE/stderr" || terminal_status=$?
        assert_case
    done
done

# Invalid completion remains a wrapper failure even when peak measurement is
# zero or unavailable. Positive peaks are covered by the full matrix above.
for route in library-none library-metrics wrapper-none wrapper-metrics; do
    for TERMINAL_PEAK in zero unavailable; do
        for TERMINAL_MODE in missing absent malformed mismatch range duplicate truncated; do
            TERMINAL_CASE="$WORKDIR/$route-$TERMINAL_PEAK-$TERMINAL_MODE"
            mkdir -p "$TERMINAL_CASE/tmp"
            expected=2
            terminal_status=0
            PATH="$WORKDIR/bin:$PATH" TMPDIR="$TERMINAL_CASE/tmp" \
                TERMINAL_PEAK=$TERMINAL_PEAK TERMINAL_MODE=$TERMINAL_MODE TERMINAL_CASE=$TERMINAL_CASE \
                route_run "$route" > "$TERMINAL_CASE/stdout" 2> "$TERMINAL_CASE/stderr" || terminal_status=$?
            assert_case
        done
    done
done

# Concurrent calls receive each other's otherwise valid terminal records.
# The invocation identity, rather than status alone, must reject both.
for route in library-none wrapper-metrics; do
    mkdir -p "$WORKDIR/$route-swap-a/tmp" "$WORKDIR/$route-swap-b/tmp"
    PATH="$WORKDIR/bin:$PATH" TMPDIR="$WORKDIR/$route-swap-a/tmp" \
        TERMINAL_MODE=swapped TERMINAL_CASE="$WORKDIR/$route-swap-a" \
        TERMINAL_PEER="$WORKDIR/$route-swap-b" route_run "$route" \
        > "$WORKDIR/$route-swap-a/stdout" 2> "$WORKDIR/$route-swap-a/stderr" &
    first=$!
    terminal_status=0
    PATH="$WORKDIR/bin:$PATH" TMPDIR="$WORKDIR/$route-swap-b/tmp" \
        TERMINAL_MODE=swapped TERMINAL_CASE="$WORKDIR/$route-swap-b" \
        TERMINAL_PEER="$WORKDIR/$route-swap-a" route_run "$route" \
        > "$WORKDIR/$route-swap-b/stdout" 2> "$WORKDIR/$route-swap-b/stderr" || terminal_status=$?
    [ "$terminal_status" -eq 2 ] || fail 'concurrent terminal swap accepted second record'
    terminal_status=0
    wait "$first" || terminal_status=$?
    [ "$terminal_status" -eq 2 ] || fail 'concurrent terminal swap accepted first record'
done
echo '[linux-memory-limit] 116 deterministic terminal/status/peak fixtures and concurrent record swaps passed'

linux_memory_limit_systemd_available || {
    echo 'Linux terminal integration requires a usable user systemd manager with delegated memory' >&2
    exit 2
}
# Real bounded invocations: forward normal statuses/signals, then stop only the
# service published by this invocation's own workload and confirmed live PID.
for route in library-none library-metrics wrapper-none wrapper-metrics; do
    for operation in valid stdin int quit exit-2 exit-7 term kill timeout oom stop; do
        # The new waiter must preserve direct callers' stdin and INT/QUIT.
        # The sampled wrapper has pre-existing behavior at its own background
        # launch (#9359); its terminal/status coverage here stays independent.
        case $operation in
            stdin | int | quit) [ "${route%%-*}" != wrapper ] || continue ;;
        esac
        TERMINAL_CASE="$WORKDIR/real-$route-$operation"
        mkdir -p "$TERMINAL_CASE/tmp"
        (
            [ "${route#*-}" != metrics ] || {
                TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE="$TERMINAL_CASE/caller-peak"
                export TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
                printf 'caller-owned\n' > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
            }
            [ "${route#*-}" != none ] || unset TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
            real_run() {
                real_rc=0
                case $route in
                    library-*)
                        linux_memory_limit_run 67108864 timeout "$deadline" "$@" || real_rc=$?
                        printf '%s\n' "$LINUX_MEMORY_LIMIT_REASON" > "$TERMINAL_CASE/library-reason"
                        return "$real_rc"
                        ;;
                    wrapper-*) "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 64 \
                        --timeout-seconds "$deadline" --report "$TERMINAL_CASE/report" -- "$@" ;;
                esac
            }
            deadline=10
            [ "$operation" != timeout ] || deadline=1
            # Even pre-exported internal names must not export the waiter's
            # subsequently assigned terminal destination or invocation token.
            _tlmem_terminal=caller-value
            _tlmem_owner=caller-value
            export _tlmem_terminal _tlmem_owner
            printf 'stdin-marker\n' > "$TERMINAL_CASE/stdin"
            TMPDIR="$TERMINAL_CASE/tmp" real_run sh -c '
                [ -z "${_tlmem_terminal+x}" ] && [ -z "${_tlmem_owner+x}" ] || exit 93
                case $1 in
                    valid) exit 0 ;;
                    stdin) read -r input; [ "$input" = stdin-marker ] ;;
                    int) trap "exit 7" INT; kill -INT "$$"; exit 93 ;;
                    quit) trap "exit 7" QUIT; kill -QUIT "$$"; exit 93 ;;
                    exit-2) exit 2 ;;
                    exit-7) exit 7 ;;
                    term) kill -TERM "$$" ;;
                    kill) kill -KILL "$$" ;;
                    timeout) sleep 8 ;;
                    oom) exec awk '\''BEGIN { s = "x"; while (1) s = s s }'\'' ;;
                    stop)
                        printf "%s\n" "$$" > "$2/pid"
                        cat /proc/self/cgroup > "$2/cgroup"
                        sleep 8
                        touch "$2/finished"
                        ;;
                esac
            ' sh "$operation" "$TERMINAL_CASE" < "$TERMINAL_CASE/stdin"
        ) > "$TERMINAL_CASE/stdout" 2> "$TERMINAL_CASE/stderr" &
        invocation=$!
        expected=0
        case $operation in
            exit-2) expected=2 ;;
            exit-7 | int | quit) expected=7 ;;
            term) expected=143 ;;
            kill | oom) expected=137 ;;
            timeout) expected=124 ;;
            stop)
                expected=2
                n=0
                while [ ! -s "$TERMINAL_CASE/cgroup" ]; do
                    [ "$n" -lt 200 ] || fail 'owned terminal-stop workload never started'
                    n=$((n + 1)); sleep 0.01
                done
                cgroup=$(sed -n 's/^0:://p' "$TERMINAL_CASE/cgroup")
                case $cgroup in */run-*.service/workload/tlmem-run) ;; *) fail "unowned stop cgroup $cgroup" ;; esac
                read -r pid < "$TERMINAL_CASE/pid"
                [ "$(sed -n 's/^0:://p' "/proc/$pid/cgroup")" = "$cgroup" ] ||
                    fail 'owned terminal-stop PID changed its cgroup'
                unit_path=${cgroup%/workload/tlmem-run}
                unit=${unit_path##*/}
                printf 'owned_unit=%s\nowned_pid=%s\n' "$unit" "$pid" > "$TERMINAL_CASE/ownership"
                systemctl --user stop "$unit"
                [ ! -e "$TERMINAL_CASE/finished" ] || fail 'stopped workload finished normally'
                ;;
        esac
        terminal_status=0
        wait "$invocation" || terminal_status=$?
        TERMINAL_MODE="real-$operation"
        assert_case
    done
done
echo '[linux-memory-limit] 38 real status/stdin/signal/OOM/timeout/owned-unit-stop fixtures passed'

# Pin stderr's destination directly, independently of dirty-page writeback.
# Metrics capture stays beside the metrics file, even with a distinct TMPDIR;
# without metrics the direct caller must see progress before completion.
stderr_program='readlink /proc/self/fd/2 > "$1/fd2"
printf "stderr-live-marker\n" >&2
touch "$1/ready"
n=0
while [ ! -e "$1/release" ]; do
    [ "$n" -lt 1000 ] || exit 94
    n=$((n + 1)); sleep 0.01
done
touch "$1/finished"'
for route in library-none library-metrics wrapper-none wrapper-metrics; do
    TERMINAL_CASE="$WORKDIR/stderr-$route"
    mkdir -p "$TERMINAL_CASE/tmp"
    stderr_parent=$(CDPATH= cd -- "$TERMINAL_CASE" && pwd -P)
    (
        unset TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
        if [ "${route#*-}" = metrics ]; then
            TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE="$TERMINAL_CASE/caller-peak"
            export TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
            printf 'caller-owned\n' > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
        fi
        TMPDIR="$TERMINAL_CASE/tmp"
        export TMPDIR
        case $route in
            library-*)
                linux_memory_limit_run 16777216 \
                    timeout 10 sh -c "$stderr_program" sh "$TERMINAL_CASE"
                printf '%s\n' "$LINUX_MEMORY_LIMIT_REASON" > "$TERMINAL_CASE/library-reason"
                ;;
            wrapper-*) "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 16 --timeout-seconds 10 \
                --report "$TERMINAL_CASE/report" -- \
                sh -c "$stderr_program" sh "$TERMINAL_CASE" ;;
        esac
    ) > "$TERMINAL_CASE/stdout" 2> "$TERMINAL_CASE/stderr" &
    stderr_pid=$!
    n=0
    while [ ! -e "$TERMINAL_CASE/ready" ] && [ "$n" -lt 200 ]; do
        n=$((n + 1)); sleep 0.05
    done
    stderr_live=1
    if [ "$route" = library-none ] &&
        { ! grep -Fq stderr-live-marker "$TERMINAL_CASE/stderr" ||
            [ -e "$TERMINAL_CASE/finished" ]; }; then stderr_live=0; fi
    touch "$TERMINAL_CASE/release"
    terminal_status=0
    wait "$stderr_pid" || terminal_status=$?
    if [ "$terminal_status" -ne 0 ] || [ ! -e "$TERMINAL_CASE/ready" ]; then
        tr -d '\000' < "$TERMINAL_CASE/stderr" | tail -c 4096 >&2
        fail "stderr destination $route returned $terminal_status or never became ready"
    fi
    stderr_target=$(cat "$TERMINAL_CASE/fd2")
    case "$route:$stderr_target" in
        "library-none:$stderr_parent/stderr") ;;
        library-metrics:"$stderr_parent"/typelisp-memory-limit.??????/systemd-stderr | \
            wrapper-*:"$stderr_parent"/typelisp-memory-limit.??????/systemd-stderr) ;;
        *) fail "stderr $route used unexpected destination $stderr_target" ;;
    esac
    [ "$stderr_live" -eq 1 ] || fail 'direct no-metrics stderr lost live progress'
    expected=0
    TERMINAL_MODE=stderr
    assert_case
done
echo '[linux-memory-limit] four deterministic stderr destination/live-progress fixtures passed'
