#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-build-invariance-batch.sh"
mkdir -p "$ROOT/target/exp"
WORKDIR=$(mktemp -d "$ROOT/target/exp/build-invariance-batch.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM
mkdir -p "$WORKDIR/left" "$WORKDIR/right"
CASES="$WORKDIR/cases"
ENTRIES="$WORKDIR/entries"
ALIASES="$WORKDIR/aliases"

record() {
    printf '%s|%s|%s|%s/%s.s|%s\n' "$1" "$2" "$2" "$3" "$1" "$4"
}
plan() {
    build_invariance_plan_chunk "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
}
reject() {
    if "$@" > "$WORKDIR/stdout" 2> "$WORKDIR/stderr"; then
        echo "expected failure: $*" >&2
        exit 1
    fi
    test -s "$WORKDIR/stderr"
}

# Every logical row survives; only same-invocation equal inputs share work.
{
    record first input.tl "$WORKDIR/left" 2
    record second other.tl "$WORKDIR/left" 2
    record alias input.tl "$WORKDIR/left" 2
} > "$CASES"
plan
test "$(wc -l < "$CASES")" -eq 3
test "$(wc -l < "$ENTRIES")" -eq 2
printf '%s|%s\n' "$WORKDIR/left/first.s" "$WORKDIR/left/alias.s" > "$WORKDIR/expected"
cmp "$ALIASES" "$WORKDIR/expected"
build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
cp "$ENTRIES" "$WORKDIR/saved-entries"
: > "$ENTRIES"
reject build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
cp "$WORKDIR/saved-entries" "$ENTRIES"
cp "$ALIASES" "$WORKDIR/saved-aliases"
printf 'foreign|foreign\n' > "$ALIASES"
reject build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
rm "$ALIASES"
reject build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
cp "$WORKDIR/saved-aliases" "$ALIASES"
reject build_invariance_copy_aliases "$ALIASES"
: > "$WORKDIR/left/first.s"
reject build_invariance_copy_aliases "$ALIASES"
printf 'assembly\n' > "$WORKDIR/left/first.s"
build_invariance_copy_aliases "$ALIASES"
cmp "$WORKDIR/left/first.s" "$WORKDIR/left/alias.s"
reject build_invariance_copy_aliases "$ALIASES"
rm "$WORKDIR/left/alias.s"
ln -s "$WORKDIR/nonexistent" "$WORKDIR/left/alias.s"
reject build_invariance_copy_aliases "$ALIASES"
rm "$WORKDIR/left/alias.s" "$WORKDIR/left/first.s"
ln -s "$WORKDIR/expected" "$WORKDIR/left/first.s"
reject build_invariance_copy_aliases "$ALIASES"

# Empty, oversized, duplicate-name, malformed and foreign-producer plans fail.
: > "$CASES"
reject plan
i=0
while [ "$i" -lt 64 ]; do
    record "case$i" same.tl "$WORKDIR/left" 2 >> "$CASES"
    i=$((i + 1))
done
plan
test "$(wc -l < "$ENTRIES")" -eq 1
test "$(wc -l < "$ALIASES")" -eq 63
record overflow same.tl "$WORKDIR/left" 2 >> "$CASES"
reject plan
record single same.tl "$WORKDIR/left" 2 > "$CASES"
plan
test "$(wc -l < "$ENTRIES")" -eq 1
test ! -s "$ALIASES"
record single other.tl "$WORKDIR/left" 2 >> "$CASES"
reject plan
record other same.tl "$WORKDIR/right" 2 > "$CASES"
reject plan
record other same.tl "$WORKDIR/left" 1 > "$CASES"
reject plan
record other same.tl "$WORKDIR/left" 02 > "$CASES"
reject plan
printf 'malformed\n' > "$CASES"
reject plan

CORPUS="$WORKDIR/corpus"
BATCHES="$WORKDIR/batches"
mkdir -p "$BATCHES/opt1/chunks" "$BATCHES/opt2/chunks"
printf 'first|input.tl|1\nsecond|other.tl|2\n' > "$CORPUS"
record first input.tl "$WORKDIR/left" 1 > "$BATCHES/opt1/chunks/cases.0000.txt"
record second other.tl "$WORKDIR/left" 2 > "$BATCHES/opt2/chunks/cases.0000.txt"
cat "$BATCHES/opt1/chunks/cases.0000.txt" "$BATCHES/opt2/chunks/cases.0000.txt" > "$BATCHES/cases.txt"
build_invariance_require_coverage "$CORPUS" "$BATCHES"
cp "$BATCHES/opt2/chunks/cases.0000.txt" "$WORKDIR/saved-chunk"
cp "$BATCHES/opt1/chunks/cases.0000.txt" "$BATCHES/opt2/chunks/cases.0000.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
rm "$BATCHES/opt2/chunks/cases.0000.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
cp "$WORKDIR/saved-chunk" "$BATCHES/opt2/chunks/cases.0000.txt"
cp "$WORKDIR/saved-chunk" "$BATCHES/opt2/chunks/cases.0001.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
rm "$BATCHES/opt2/chunks/cases.0001.txt"
printf 'other|other.tl|2\n' > "$CORPUS"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
printf 'first|input.tl|1\nfirst|other.tl|2\n' > "$CORPUS"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"

# Worker pool: jobs start in queue order, only inside the memory budget, exactly
# once; a drained pool passes only with one successful result per queued job.
POOL="$WORKDIR/pool"
QUEUE="$WORKDIR/queue"
printf 'full-a|8192\nfull-b|8192\nsmall-a|4096\nsmall-b|4096\n' > "$QUEUE"
build_invariance_pool_init "$POOL" 12288 "$QUEUE"
test "$(build_invariance_pool_claim "$POOL")" = 'full-a|8192'
# The second 8 GiB job does not fit beside the first; the next fitting job runs.
test "$(build_invariance_pool_claim "$POOL")" = 'small-a|4096'
pool_status=0
build_invariance_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 3
test ! -s "$WORKDIR/stdout"
reject build_invariance_pool_require_complete "$POOL"
build_invariance_pool_finish "$POOL" small-a 0
test "$(build_invariance_pool_claim "$POOL")" = 'small-b|4096'
build_invariance_pool_finish "$POOL" full-a 0
test "$(build_invariance_pool_claim "$POOL")" = 'full-b|8192'
pool_status=0
build_invariance_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 1
reject build_invariance_pool_require_complete "$POOL"
build_invariance_pool_finish "$POOL" small-b 0
build_invariance_pool_finish "$POOL" full-b 0
build_invariance_pool_require_complete "$POOL"
# A job reports once, and only after it was started.
reject build_invariance_pool_finish "$POOL" full-b 0
reject build_invariance_pool_finish "$POOL" never-started 0
build_invariance_pool_require_complete "$POOL"

# Failed, missing, foreign and unfinished results and an abort all fail closed.
printf '1\n' > "$POOL/results/full-b"
reject build_invariance_pool_require_complete "$POOL"
rm "$POOL/results/full-b"
reject build_invariance_pool_require_complete "$POOL"
cp "$POOL/results/full-a" "$POOL/results/full-b"
build_invariance_pool_require_complete "$POOL"
cp "$POOL/results/full-a" "$POOL/results/foreign"
reject build_invariance_pool_require_complete "$POOL"
rm "$POOL/results/foreign"
mkdir "$POOL/claims/foreign"
reject build_invariance_pool_require_complete "$POOL"
rmdir "$POOL/claims/foreign"
printf '4096\n' > "$POOL/running/small-a"
reject build_invariance_pool_require_complete "$POOL"
rm "$POOL/running/small-a"
: > "$POOL/abort"
reject build_invariance_pool_require_complete "$POOL"
reject build_invariance_pool_claim "$POOL"
rm "$POOL/abort"
build_invariance_pool_require_complete "$POOL"
# A lock that is never released is reported instead of waited on forever.
mkdir "$POOL/lock"
reject build_invariance_pool_require_complete "$POOL"
BUILD_INVARIANCE_POOL_LOCK_TRIES=2
reject build_invariance_pool_claim "$POOL"
reject build_invariance_pool_finish "$POOL" full-a 0
BUILD_INVARIANCE_POOL_LOCK_TRIES=600
rmdir "$POOL/lock"

# Malformed, duplicate, empty and over-budget queues never start a pool.
for bad_queue in 'job' 'job|' 'job|0' 'job|08' 'job|4096|extra' '../job|4096' \
    'job|16384' 'job|4096
job|4096'; do
    printf '%s\n' "$bad_queue" > "$QUEUE"
    reject build_invariance_pool_init "$POOL.bad" 12288 "$QUEUE"
    test ! -e "$POOL.bad"
done
: > "$QUEUE"
reject build_invariance_pool_init "$POOL.bad" 12288 "$QUEUE"
printf 'job|4096\n' > "$QUEUE"
reject build_invariance_pool_init "$POOL.bad" 0 "$QUEUE"
reject build_invariance_pool_init "$POOL.bad" '' "$QUEUE"

# Concurrent workers: every job runs once and the running caps never exceed the
# budget, which each job observes from inside the pool.
write_pool_queue() {
    i=0
    : > "$QUEUE"
    while [ "$i" -lt "$1" ]; do
        case $((i % 3)) in
            0) printf 'job%s|8192\n' "$i" >> "$QUEUE" ;;
            *) printf 'job%s|4096\n' "$i" >> "$QUEUE" ;;
        esac
        i=$((i + 1))
    done
}
count_entries() {
    find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}
POOL_FAIL_JOB=
POOL_KILL_JOB=
build_invariance_pool_run_job() {
    build_invariance_pool_lock "$POOL"
    pool_used=0
    for pool_running in "$POOL/running"/*; do
        pool_used=$((pool_used + $(cat "$pool_running")))
    done
    build_invariance_pool_unlock "$POOL"
    [ "$pool_used" -ge "$2" ] && [ "$pool_used" -le 12288 ]
    mkdir "$WORKDIR/ran/$1"
    sleep 0.05
    if [ "$1" = "$POOL_FAIL_JOB" ]; then
        echo "job $1 fails" >&2
        exit 7
    fi
    if [ "$1" = "$POOL_KILL_JOB" ]; then
        # The parent publishes the only worker's process id after starting it.
        until [ -s "$WORKDIR/worker.pid" ]; do
            sleep 0.05
        done
        kill -KILL "$(cat "$WORKDIR/worker.pid")"
        sleep 5
    fi
}
write_pool_queue 24
build_invariance_pool_init "$POOL" 12288 "$QUEUE"
mkdir "$WORKDIR/ran"
build_invariance_pool_start "$POOL" 3
build_invariance_pool_wait_for "$POOL" job0 job23
build_invariance_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 24

# A failing job aborts the pool: its status is kept, waiters and the join fail,
# and the jobs queued behind it never start.
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
build_invariance_pool_init "$POOL" 12288 "$QUEUE"
POOL_FAIL_JOB=job4
build_invariance_pool_start "$POOL" 2 2>> "$WORKDIR/workers.log"
reject build_invariance_pool_wait_for "$POOL" job23
reject build_invariance_pool_join "$POOL"
POOL_FAIL_JOB=
test "$(cat "$POOL/results/job4")" -eq 7
grep -q 'job job4 fails' "$WORKDIR/workers.log"
test -e "$POOL/abort"
test ! -e "$WORKDIR/ran/job23"
test "$(count_entries "$WORKDIR/ran")" -lt 24
reject build_invariance_pool_require_complete "$POOL"

# A worker that dies without reporting cannot leave the gate waiting or green.
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
build_invariance_pool_init "$POOL" 12288 "$QUEUE"
POOL_KILL_JOB=job2
build_invariance_pool_start "$POOL" 1 2>> "$WORKDIR/workers.log"
printf '%s\n' $BUILD_INVARIANCE_POOL_PIDS > "$WORKDIR/worker.pid.tmp"
mv "$WORKDIR/worker.pid.tmp" "$WORKDIR/worker.pid"
reject build_invariance_pool_wait_for "$POOL" job23
grep -q 'every pool worker exited without a result for job23' "$WORKDIR/stderr"
reject build_invariance_pool_join "$POOL"
POOL_KILL_JOB=
test -f "$POOL/running/job2"
test ! -e "$POOL/results/job2"
reject build_invariance_pool_require_complete "$POOL"

# The caller's own failure stops the pool: running jobs finish, none starts.
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
build_invariance_pool_init "$POOL" 12288 "$QUEUE"
build_invariance_pool_start "$POOL" 2 2>> "$WORKDIR/workers.log"
build_invariance_pool_stop "$POOL"
test "$(count_entries "$POOL/running")" -eq 0
pool_started_jobs=$(count_entries "$WORKDIR/ran")
test "$pool_started_jobs" -lt 24
test "$(count_entries "$POOL/results")" -eq "$pool_started_jobs"
sleep 0.2
test "$(count_entries "$WORKDIR/ran")" -eq "$pool_started_jobs"
reject build_invariance_pool_require_complete "$POOL"
echo 'build-invariance batch reuse and worker pool checks passed'
