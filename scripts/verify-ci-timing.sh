#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"

WORKDIR="$ROOT/target/ci-timing-self-test"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

TYPELISP_CI_TIMING=1
TYPELISP_CI_TIMING_GATE=self-test
export TYPELISP_CI_TIMING TYPELISP_CI_TIMING_GATE
ci_timing_init "$WORKDIR/timing.tsv" self-test-host

started=$(ci_timing_now_ms)
finished=$(ci_timing_now_ms)
if [ "$finished" -lt "$started" ]; then
    echo "CI timing clock moved backwards: start=$started finish=$finished" >&2
    exit 1
fi

ci_timing_run pass-case helper sh -c 'exit 0'
set +e
ci_timing_run fail-case helper sh -c 'exit 7'
status=$?
set -e
if [ "$status" -ne 7 ]; then
    echo "CI timing wrapper changed exit 7 to $status" >&2
    exit 1
fi

awk -F '\t' '
    NR == 1 {
        if ($0 != "gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost") exit 1
        next
    }
    NF != 6 { exit 1 }
    $1 != "self-test" || $3 != "helper" || $6 != "self-test-host" { exit 1 }
    $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ { exit 1 }
    $2 == "pass-case" && $5 == 0 { pass = 1 }
    $2 == "fail-case" && $5 == 7 { fail = 1 }
    END { if (!pass || !fail) exit 1 }
' "$WORKDIR/timing.tsv" || {
    echo "CI timing artifact schema/exit preservation self-test failed" >&2
    cat "$WORKDIR/timing.tsv" >&2
    exit 1
}

if grep -F "$ROOT" "$WORKDIR/timing.tsv" >/dev/null 2>&1; then
    echo "CI timing artifact leaked the absolute repository path" >&2
    exit 1
fi

ci_timing_summary "$WORKDIR/timing.tsv" 2 > "$WORKDIR/summary.txt"
grep -F '[ci-timing] slowest 2 rows:' "$WORKDIR/summary.txt" >/dev/null
grep -F 'rows=2' "$WORKDIR/summary.txt" >/dev/null

if [ -r /proc/uptime ]; then
    ci_timing_init "$WORKDIR/overhead.tsv" self-test-host
    TYPELISP_CI_TIMING_GATE=overhead
    export TYPELISP_CI_TIMING_GATE
    ci_timing_set_now_ms
    overhead_started=$CI_TIMING_NOW_MS
    overhead_rows=0
    while [ "$overhead_rows" -lt 200 ]; do
        ci_timing_run no-op helper-overhead :
        overhead_rows=$((overhead_rows + 1))
    done
    ci_timing_set_now_ms
    overhead_elapsed=$((CI_TIMING_NOW_MS - overhead_started))
    if [ "$overhead_elapsed" -gt 1000 ]; then
        echo "CI timing wrapper overhead is too high: ${overhead_elapsed}ms for 200 rows" >&2
        exit 1
    fi
    echo "CI timing wrapper overhead: ${overhead_elapsed}ms for 200 rows"
fi

echo "CI timing helper self-tests passed"
