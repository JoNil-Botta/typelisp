#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-build-invariance-batch.sh"
BOUNDED_POOL_LABEL=build-invariance
. "$ROOT/scripts/lib-bounded-pool.sh"
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
bounded_pool_init "$POOL" 12288 "$QUEUE"
test "$(bounded_pool_claim "$POOL")" = 'full-a|8192'
# The second 8 GiB job does not fit beside the first; the next fitting job runs.
test "$(bounded_pool_claim "$POOL")" = 'small-a|4096'
pool_status=0
bounded_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 3
test ! -s "$WORKDIR/stdout"
reject bounded_pool_require_complete "$POOL"
bounded_pool_finish "$POOL" small-a 0
test "$(bounded_pool_claim "$POOL")" = 'small-b|4096'
bounded_pool_finish "$POOL" full-a 0
test "$(bounded_pool_claim "$POOL")" = 'full-b|8192'
pool_status=0
bounded_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 1
reject bounded_pool_require_complete "$POOL"
bounded_pool_finish "$POOL" small-b 0
bounded_pool_finish "$POOL" full-b 0
bounded_pool_require_complete "$POOL"
# A job reports once, and only after it was started.
reject bounded_pool_finish "$POOL" full-b 0
reject bounded_pool_finish "$POOL" never-started 0
bounded_pool_require_complete "$POOL"

# Failed, missing, foreign and unfinished results and an abort all fail closed.
printf '1\n' > "$POOL/results/full-b"
reject bounded_pool_require_complete "$POOL"
rm "$POOL/results/full-b"
reject bounded_pool_require_complete "$POOL"
cp "$POOL/results/full-a" "$POOL/results/full-b"
bounded_pool_require_complete "$POOL"
cp "$POOL/results/full-a" "$POOL/results/foreign"
reject bounded_pool_require_complete "$POOL"
rm "$POOL/results/foreign"
mkdir "$POOL/claims/foreign"
reject bounded_pool_require_complete "$POOL"
rmdir "$POOL/claims/foreign"
printf '4096\n' > "$POOL/running/small-a"
reject bounded_pool_require_complete "$POOL"
reject bounded_pool_claim "$POOL"
test ! -e "$POOL/lock"
rm "$POOL/running/small-a"
: > "$POOL/abort"
reject bounded_pool_require_complete "$POOL"
reject bounded_pool_claim "$POOL"
rm "$POOL/abort"
bounded_pool_require_complete "$POOL"
# A lock that is never released is reported instead of waited on forever.
mkdir "$POOL/lock"
reject bounded_pool_require_complete "$POOL"
BOUNDED_POOL_LOCK_TRIES=2
reject bounded_pool_claim "$POOL"
reject bounded_pool_finish "$POOL" full-a 0
BOUNDED_POOL_LOCK_TRIES=600
rmdir "$POOL/lock"

# Malformed, duplicate, empty and over-budget queues never start a pool.
for bad_queue in 'job' 'job|' 'job|0' 'job|08' 'job|4096|extra' '../job|4096' \
    'job|16384' 'job|4096
job|4096'; do
    printf '%s\n' "$bad_queue" > "$QUEUE"
    reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
    test ! -e "$POOL.bad"
done
: > "$QUEUE"
reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
# A final record without its newline would be validated but never run or counted.
printf 'first|4096\nlast|4096' > "$QUEUE"
reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
test ! -e "$POOL.bad"
printf 'job|4096\n' > "$QUEUE"
reject bounded_pool_init "$POOL.bad" 0 "$QUEUE"
reject bounded_pool_init "$POOL.bad" '' "$QUEUE"

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
bounded_pool_run_job() {
    bounded_pool_lock "$POOL"
    pool_used=0
    for pool_running in "$POOL/running"/*; do
        read -r pool_running_cap < "$pool_running"
        pool_used=$((pool_used + pool_running_cap))
    done
    bounded_pool_unlock "$POOL"
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
bounded_pool_init "$POOL" 12288 "$QUEUE"
mkdir "$WORKDIR/ran"
bounded_pool_start "$POOL" 3
bounded_pool_wait_for "$POOL" job0 job23
bounded_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 24

# A failing job aborts the pool: its status is kept, waiters and the join fail,
# and the jobs queued behind it never start.
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_FAIL_JOB=job4
bounded_pool_start "$POOL" 2 2>> "$WORKDIR/workers.log"
reject bounded_pool_wait_for "$POOL" job23
reject bounded_pool_join "$POOL"
POOL_FAIL_JOB=
test "$(cat "$POOL/results/job4")" -eq 7
grep -q 'job job4 fails' "$WORKDIR/workers.log"
test -e "$POOL/abort"
test ! -e "$WORKDIR/ran/job23"
test "$(count_entries "$WORKDIR/ran")" -lt 24
reject bounded_pool_require_complete "$POOL"

# A worker that dies without reporting cannot leave the gate waiting or green.
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_KILL_JOB=job2
bounded_pool_start "$POOL" 1 2>> "$WORKDIR/workers.log"
printf '%s\n' $BOUNDED_POOL_PIDS > "$WORKDIR/worker.pid.tmp"
mv "$WORKDIR/worker.pid.tmp" "$WORKDIR/worker.pid"
reject bounded_pool_wait_for "$POOL" job23
grep -q 'every pool worker exited without a result for job23' "$WORKDIR/stderr"
reject bounded_pool_join "$POOL"
POOL_KILL_JOB=
test -f "$POOL/running/job2"
test ! -e "$POOL/results/job2"
reject bounded_pool_require_complete "$POOL"

# The caller's own failure stops the pool: running jobs finish, none starts.
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 2 2>> "$WORKDIR/workers.log"
bounded_pool_stop "$POOL"
test "$(count_entries "$POOL/running")" -eq 0
pool_started_jobs=$(count_entries "$WORKDIR/ran")
test "$pool_started_jobs" -lt 24
test "$(count_entries "$POOL/results")" -eq "$pool_started_jobs"
sleep 0.2
test "$(count_entries "$WORKDIR/ran")" -eq "$pool_started_jobs"
reject bounded_pool_require_complete "$POOL"

# Needs name earlier queued jobs and locks are distinct names; a self, later,
# unknown or empty need, and an empty, duplicate or malformed lock, rejects the
# queue.
for bad_queue in 'a|4096|a' 'a|4096|b
b|4096' 'a|4096
b|4096|a,c' 'a|4096|' 'a|4096|-|' 'a|4096|-|x,x' 'a|4096|-|../x' \
    'a|4096|-|x|y'; do
    printf '%s\n' "$bad_queue" > "$QUEUE"
    reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
    test ! -e "$POOL.bad"
done

# A job starts only after each of its needs succeeded, and a job blocked on its
# needs does not hold back independent jobs queued behind it: `slow` finishes
# only once `free` has run beside it.
POOL_NEEDS_FAIL_JOB=
bounded_pool_run_job() {
    needs_record=$(awk -F '|' -v job="$1" '$1 == job { print $3 }' "$QUEUE")
    [ -z "$needs_record" ] || bounded_pool_needs_met "$POOL" "$needs_record" || exit 9
    printf '%s\n' "$1" >> "$WORKDIR/order"
    if [ "$1" = slow ]; then
        needs_waits=0
        until [ -e "$WORKDIR/ran/free" ]; do
            needs_waits=$((needs_waits + 1))
            [ "$needs_waits" -lt 100 ] || exit 8
            sleep 0.1
        done
    fi
    [ "$1" != "$POOL_NEEDS_FAIL_JOB" ] || exit 7
    mkdir "$WORKDIR/ran/$1"
}
cat > "$QUEUE" <<'EOF'
slow|4096
after-slow|4096|slow
free|4096
join|8192|after-slow,free
tail|4096|join
EOF
rm -rf "$WORKDIR/ran" "$WORKDIR/order"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 3
bounded_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 5
test "$(sed -n '$p' "$WORKDIR/order")" = tail

# One worker runs a dependency-ordered queue exactly in queue order.
cat > "$QUEUE" <<'EOF'
a|4096
b|4096|a
c|4096
d|4096|b,c
EOF
rm -rf "$WORKDIR/ran" "$WORKDIR/order"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 1
bounded_pool_join "$POOL"
test "$(tr '\n' ' ' < "$WORKDIR/order")" = 'a b c d '

# A failed need aborts the pool; nothing that needs it starts.
rm -rf "$WORKDIR/ran" "$WORKDIR/order"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_NEEDS_FAIL_JOB=a
bounded_pool_start "$POOL" 3 2>> "$WORKDIR/workers.log"
reject bounded_pool_join "$POOL"
POOL_NEEDS_FAIL_JOB=
test "$(cat "$POOL/results/a")" -eq 7
test ! -e "$POOL/claims/b"
test ! -e "$POOL/claims/d"
reject bounded_pool_require_complete "$POOL"

# Jobs that share a lock never run at once, whatever their needs, and every
# lock is released when its job finishes or fails.
POOL_LOCK_FAIL_JOB=
bounded_pool_run_job() {
    lock_record=$(awk -F '|' -v job="$1" '$1 == job { print $4 }' "$QUEUE")
    for lock_name in $(printf '%s\n' "$lock_record" | tr ',' ' '); do
        mkdir "$WORKDIR/in-$lock_name" || exit 9
    done
    sleep 0.2
    for lock_name in $(printf '%s\n' "$lock_record" | tr ',' ' '); do
        rmdir "$WORKDIR/in-$lock_name"
    done
    [ "$1" != "$POOL_LOCK_FAIL_JOB" ] || exit 7
    mkdir "$WORKDIR/ran/$1"
}
cat > "$QUEUE" <<'EOF'
stamp-a|4096|-|stamp
both|4096|-|stamp,release
release-a|4096|-|release
free|4096
stamp-b|4096|free|stamp
release-b|4096|stamp-a|release
EOF
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 3
bounded_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 6
test "$(count_entries "$POOL/held")" -eq 0
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_LOCK_FAIL_JOB=stamp-a
bounded_pool_start "$POOL" 3 2>> "$WORKDIR/workers.log"
reject bounded_pool_join "$POOL"
POOL_LOCK_FAIL_JOB=
test "$(cat "$POOL/results/stamp-a")" -eq 7
test "$(count_entries "$POOL/held")" -eq 0
# A lock left held is incomplete even when every job succeeded.
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 3
bounded_pool_join "$POOL"
mkdir "$POOL/held/stamp"
reject bounded_pool_require_complete "$POOL"

# CPU admission accounts for nested compiler workers as well as memory and
# checkout locks. Workers observe the bound while running, not just at claim.
cat > "$QUEUE" <<'EOF'
first|4096|-|stamp|2
second|4096|-|-|2
third|4096|-|-|1
after|4096|first,second|stamp|2
tail|4096|third,after|-|1
EOF
rm -rf "$WORKDIR/ran"
mkdir "$WORKDIR/ran"
bounded_pool_run_job() {
    bounded_pool_lock "$POOL"
    cpu_used=$(awk 'FNR == 3 { sum += $0 } END { print sum + 0 }' "$POOL"/running/*)
    bounded_pool_unlock "$POOL"
    test "$cpu_used" -le 4 || exit 9
    if [ "$1" = first ] || [ "$1" = after ]; then
        mkdir "$WORKDIR/cpu-stamp" || exit 8
    fi
    sleep 0.2
    if [ "$1" = first ] || [ "$1" = after ]; then
        rmdir "$WORKDIR/cpu-stamp"
    fi
    mkdir "$WORKDIR/ran/$1"
}
bounded_pool_init "$POOL" 16384 "$QUEUE" 4
bounded_pool_start "$POOL" 4
bounded_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 5
test "$(count_entries "$POOL/held")" -eq 0

# Admission skips a CPU-heavy job for one that fits exactly, even with memory
# to spare. Releasing that reservation makes the skipped job eligible.
printf 'first|4096|-|-|3\nsecond|4096|-|-|2\nsmall|4096|-|-|1\n' > "$QUEUE"
bounded_pool_init "$POOL" 16384 "$QUEUE" 4
test "$(bounded_pool_claim "$POOL")" = 'first|4096'
test "$(bounded_pool_claim "$POOL")" = 'small|4096'
pool_status=0
bounded_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 3
test ! -s "$WORKDIR/stdout"
bounded_pool_finish "$POOL" first 0
test "$(bounded_pool_claim "$POOL")" = 'second|4096'
bounded_pool_finish "$POOL" small 0
bounded_pool_finish "$POOL" second 0
bounded_pool_require_complete "$POOL"

# A multi-worker job exceeds a one-slot caller only while running alone; the
# caller still executes the whole queue, including ordinary two-field records.
printf 'pooled|4096|-|-|2\nordinary|4096\n' > "$QUEUE"
bounded_pool_init "$POOL" 12288 "$QUEUE" 1
test "$(bounded_pool_claim "$POOL")" = 'pooled|4096'
pool_status=0
bounded_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 3
test ! -s "$WORKDIR/stdout"
bounded_pool_finish "$POOL" pooled 0
test "$(bounded_pool_claim "$POOL")" = 'ordinary|4096'
bounded_pool_finish "$POOL" ordinary 0
bounded_pool_require_complete "$POOL"

# The upper CPU boundaries are accepted, and omitting the CPU budget keeps
# memory-only callers free to run weighted records beside each other.
printf 'wide|4096|-|-|16\nordinary|4096\n' > "$QUEUE"
for cpu_budget in 16384 ''; do
    bounded_pool_init "$POOL" 8192 "$QUEUE" "$cpu_budget"
    test "$(bounded_pool_claim "$POOL")" = 'wide|4096'
    test "$(bounded_pool_claim "$POOL")" = 'ordinary|4096'
    bounded_pool_finish "$POOL" wide 0
    bounded_pool_finish "$POOL" ordinary 0
    bounded_pool_require_complete "$POOL"
done

for bad_cpu in 0 03 -1 16385 1.5 cpu; do
    reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE" "$bad_cpu"
    test ! -e "$POOL.bad"
done
for bad_weight in '' 0 02 -1 17 cpu; do
    printf 'job|4096|-|-|%s\n' "$bad_weight" > "$QUEUE"
    reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE" 4
    test ! -e "$POOL.bad"
done

# The gate inventory validates the new field even when only listing a host.
CI_REPO="$WORKDIR/ci-repo"
mkdir -p "$CI_REPO/scripts"
cp "$ROOT/scripts/ci-verify.sh" "$ROOT/scripts/lib-linux-entry.sh" \
    "$ROOT/scripts/lib-ci-timing.sh" "$ROOT/scripts/lib-benchmark.sh" \
    "$ROOT/scripts/lib-bounded-pool.sh" "$CI_REPO/scripts/"
printf 'tool\thosts\tgates\tcheck\tinstall\n' > "$CI_REPO/scripts/ci-host-tools.tsv"
for gate_cpu in 1 16 '' 0 02 -1 17 cpu; do
    printf 'id\thosts\tlabel\tneeds\tcompiler\tmemory\tcpu\tlocks\tcommand\n' > "$CI_REPO/scripts/ci-gates.tsv"
    printf 'cpu-gate\tall\tCPU gate\t-\t-\t256\t%s\t-\tgate_bootstrap_fixpoint\n' "$gate_cpu" >> "$CI_REPO/scripts/ci-gates.tsv"
    case "$gate_cpu" in
        1 | 16)
            sh "$CI_REPO/scripts/ci-verify.sh" --list-gates linux > "$WORKDIR/stdout"
            awk -F '\t' -v cpu="$gate_cpu" 'NR == 1 && $6 != "cpu" { exit 1 } NR == 2 && $6 != cpu { exit 1 } END { if (NR != 2) exit 1 }' "$WORKDIR/stdout"
            ;;
        *) reject sh "$CI_REPO/scripts/ci-verify.sh" --list-gates linux ;;
    esac
done
for bad_cpu in 0 03 -1 16385 1.5 cpu; do
    reject sh "$CI_REPO/scripts/ci-verify.sh" --cpu-slots "$bad_cpu"
    grep -F -- '--cpu-slots must be an integer' "$WORKDIR/stderr" > /dev/null
done
reject sh "$CI_REPO/scripts/ci-verify.sh" --cpu-slots

# The CPU budget defaults to the online CPU count, and a two-slot gate still
# runs under an explicit one-slot budget.
printf 'id\thosts\tlabel\tneeds\tcompiler\tmemory\tcpu\tlocks\tcommand\n' > "$CI_REPO/scripts/ci-gates.tsv"
printf 'wide-gate\tall\twide gate\t-\t-\t256\t2\t-\ttrue\n' >> "$CI_REPO/scripts/ci-gates.tsv"
printf 'narrow-gate\tall\tnarrow gate\t-\t-\t256\t1\t-\ttrue\n' >> "$CI_REPO/scripts/ci-gates.tsv"
online_cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)
for cpu_args in '' '--cpu-slots 1'; do
    # shellcheck disable=SC2086
    sh "$CI_REPO/scripts/ci-verify.sh" --jobs 2 --memory-mib 512 $cpu_args > "$WORKDIR/stdout"
    want_slots=${cpu_args#--cpu-slots }
    [ -n "$want_slots" ] || want_slots=$online_cpus
    grep -F -x "[ci-verify] CPU reservation budget: $want_slots slots" "$WORKDIR/stdout" > /dev/null
    test "$(grep -c '^\[ci-verify\] PASS ' "$WORKDIR/stdout")" -eq 2
done
echo 'build-invariance batch reuse and worker pool checks passed'
