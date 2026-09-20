#!/usr/bin/env sh

# A chunk belongs to exactly one compiler invocation (target, cfg, backend,
# optimization and ordered roots). Only equal input paths inside that invocation
# may share an output. Keep the original case records for every byte comparison.
# There is no cross-chunk, cross-producer or on-disk cache lookup.
build_invariance_plan_chunk() {
    _bib_cases=$1
    _bib_entries=$2
    _bib_aliases=$3
    _bib_opt=$4
    _bib_output_dir=$5
    : > "$_bib_entries"
    : > "$_bib_aliases"
    awk -F '|' -v entries="$_bib_entries" -v aliases="$_bib_aliases" \
        -v opt="$_bib_opt" -v output_dir="$_bib_output_dir" '
        function fail(message) {
            print "[build-invariance] invalid chunk: " message > "/dev/stderr"
            failed = 1
            exit 1
        }
        {
            if (NF != 5 || $1 !~ /^[A-Za-z0-9_-]+$/ || $2 == "" || $3 == "")
                fail("malformed case record")
            if ($5 !~ /^[12]$/ || $5 != opt || (opt != 1 && opt != 2))
                fail("optimization identity differs")
            if ($4 != output_dir "/" $1 ".s")
                fail("output does not belong to this producer")
            if (names[$1]++) fail("duplicate logical case " $1)
            if (++count > 64) fail("more than 64 logical cases")
            if ($3 in canonical) {
                print canonical[$3] "|" $4 > aliases
            } else {
                canonical[$3] = $4
                print $3 "|" $4 > entries
            }
        }
        END {
            if (!failed && count == 0) fail("empty chunk")
        }
    ' "$_bib_cases"
}

build_invariance_require_plan() {
    _bib_require_cases=$1
    _bib_require_entries=$2
    _bib_require_aliases=$3
    build_invariance_plan_chunk "$_bib_require_cases" \
        "$_bib_require_entries.expected" "$_bib_require_aliases.expected" "$4" "$5" || return 1
    if ! cmp -s "$_bib_require_entries" "$_bib_require_entries.expected" ||
        ! cmp -s "$_bib_require_aliases" "$_bib_require_aliases.expected"; then
        echo "[build-invariance] chunk plan differs from logical coverage" >&2
        return 1
    fi
    rm -f "$_bib_require_entries.expected" "$_bib_require_aliases.expected"
}

# Compare the multiset of executed logical records with the complete prepared
# inventory, and that inventory with the authoritative corpus. Counts alone
# cannot detect a duplicated chunk substituted for a missing one.
build_invariance_require_coverage() {
    _bib_coverage_corpus=$1
    _bib_coverage_root=$2
    _bib_coverage_cases="$_bib_coverage_root/cases.txt"
    if ! awk -F '|' 'NF != 3 || $1 == "" || seen[$1]++ { exit 1 }
        { count++ } END { if (count == 0) exit 1 }' \
        "$_bib_coverage_corpus"; then
        echo "[build-invariance] malformed or duplicate corpus case" >&2
        return 1
    fi
    LC_ALL=C sort "$_bib_coverage_corpus" > "$_bib_coverage_root/coverage.corpus"
    awk -F '|' '{ print $1 "|" $2 "|" $5 }' "$_bib_coverage_cases" |
        LC_ALL=C sort > "$_bib_coverage_root/coverage.prepared"
    if ! cmp -s "$_bib_coverage_root/coverage.corpus" "$_bib_coverage_root/coverage.prepared"; then
        echo "[build-invariance] prepared inventory differs from corpus" >&2
        return 1
    fi
    : > "$_bib_coverage_root/coverage.chunks"
    for _bib_coverage_opt in 1 2; do
        for _bib_coverage_chunk in "$_bib_coverage_root/opt$_bib_coverage_opt/chunks"/cases.*.txt; do
            [ -f "$_bib_coverage_chunk" ] || continue
            cat "$_bib_coverage_chunk" >> "$_bib_coverage_root/coverage.chunks" || return 1
        done
    done
    LC_ALL=C sort "$_bib_coverage_cases" > "$_bib_coverage_root/coverage.expected"
    LC_ALL=C sort "$_bib_coverage_root/coverage.chunks" > "$_bib_coverage_root/coverage.actual"
    if ! cmp -s "$_bib_coverage_root/coverage.expected" "$_bib_coverage_root/coverage.actual"; then
        echo "[build-invariance] chunk coverage differs from prepared inventory" >&2
        return 1
    fi
}

build_invariance_copy_aliases() {
    _bib_alias_file=$1
    while IFS='|' read -r _bib_original _bib_alias; do
        if [ ! -f "$_bib_original" ] || [ ! -s "$_bib_original" ] ||
            [ -L "$_bib_original" ]; then
            echo "[build-invariance] missing fresh canonical assembly: $_bib_original" >&2
            return 1
        fi
        if [ -e "$_bib_alias" ] || [ -L "$_bib_alias" ]; then
            echo "[build-invariance] alias output already exists: $_bib_alias" >&2
            return 1
        fi
        cp "$_bib_original" "$_bib_alias" || return 1
        if ! cmp -s "$_bib_original" "$_bib_alias"; then
            echo "[build-invariance] alias assembly differs: $_bib_alias" >&2
            return 1
        fi
    done < "$_bib_alias_file"
}

# Worker pool. A queue lists every job once as `job|cap_mib`; workers claim jobs
# in queue order and a job starts only while the caps of all running jobs stay
# within the pool budget. Every job runs under its cap, so concurrent memory is
# bounded by the budget instead of by what the host happens to tolerate. State
# lives in directories whose creation is atomic: `claims/` (one per started
# job), `running/` (its cap while it runs) and `results/` (its exit status).
BUILD_INVARIANCE_POOL_LOCK_TRIES=${BUILD_INVARIANCE_POOL_LOCK_TRIES:-600}

build_invariance_pool_lock() {
    _bib_lock_tries=0
    until mkdir "$1/lock" 2>/dev/null; do
        _bib_lock_tries=$((_bib_lock_tries + 1))
        if [ "$_bib_lock_tries" -ge "$BUILD_INVARIANCE_POOL_LOCK_TRIES" ]; then
            echo "[build-invariance] pool lock was not released: $1/lock" >&2
            return 2
        fi
        sleep 0.1
    done
}

build_invariance_pool_unlock() {
    rmdir "$1/lock"
}

build_invariance_pool_require_queue() {
    _bib_queue_budget=$1
    _bib_queue=$2
    case "$_bib_queue_budget" in
        "" | *[!0-9]* | 0*)
            echo "[build-invariance] invalid pool budget: $_bib_queue_budget" >&2
            return 2
            ;;
    esac
    # Workers and the completeness check read the queue with `read` and `wc -l`,
    # which both drop a final record that lacks its newline; awk below would
    # still count it, so such a queue must not start a pool.
    if [ -s "$_bib_queue" ] && [ -n "$(tail -c 1 "$_bib_queue")" ]; then
        echo "[build-invariance] invalid pool queue: last record is not newline-terminated" >&2
        return 2
    fi
    awk -F '|' -v budget="$_bib_queue_budget" '
        function fail(message) {
            print "[build-invariance] invalid pool queue: " message > "/dev/stderr"
            failed = 1
            exit 2
        }
        {
            if (NF != 2 || $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/)
                fail("malformed job record")
            if ($2 !~ /^[1-9][0-9]*$/) fail("malformed cap for " $1)
            if ($2 + 0 > budget + 0) fail("cap of " $1 " exceeds the pool budget")
            if (seen[$1]++) fail("duplicate job " $1)
            count++
        }
        END { if (!failed && count == 0) fail("empty queue") }
    ' "$_bib_queue"
}

build_invariance_pool_init() {
    _bib_pool=$1
    _bib_pool_budget=$2
    _bib_pool_queue=$3
    build_invariance_pool_require_queue "$_bib_pool_budget" "$_bib_pool_queue" || return 2
    rm -rf "$_bib_pool"
    mkdir -p "$_bib_pool/claims" "$_bib_pool/running" "$_bib_pool/results"
    printf '%s\n' "$_bib_pool_budget" > "$_bib_pool/budget"
    cp "$_bib_pool_queue" "$_bib_pool/queue"
}

# Prints `job|cap_mib` for the first unclaimed job that fits the budget.
# Returns 1 once every job is claimed and 3 while unclaimed jobs must wait for
# running ones; 2 reports a broken pool.
build_invariance_pool_claim() {
    _bib_claim_pool=$1
    if [ -e "$_bib_claim_pool/abort" ]; then
        echo "[build-invariance] pool was aborted; no further job starts" >&2
        return 2
    fi
    build_invariance_pool_lock "$_bib_claim_pool" || return 2
    _bib_claim_budget=$(cat "$_bib_claim_pool/budget")
    _bib_claim_used=0
    for _bib_claim_running in "$_bib_claim_pool/running"/*; do
        [ -f "$_bib_claim_running" ] || continue
        _bib_claim_used=$((_bib_claim_used + $(cat "$_bib_claim_running")))
    done
    _bib_claim_status=1
    while IFS='|' read -r _bib_claim_job _bib_claim_cap; do
        [ ! -d "$_bib_claim_pool/claims/$_bib_claim_job" ] || continue
        _bib_claim_status=3
        [ $((_bib_claim_used + _bib_claim_cap)) -le "$_bib_claim_budget" ] || continue
        if ! mkdir "$_bib_claim_pool/claims/$_bib_claim_job" ||
            ! printf '%s\n' "$_bib_claim_cap" > "$_bib_claim_pool/running/$_bib_claim_job"; then
            _bib_claim_status=2
            break
        fi
        printf '%s|%s\n' "$_bib_claim_job" "$_bib_claim_cap"
        _bib_claim_status=0
        break
    done < "$_bib_claim_pool/queue"
    build_invariance_pool_unlock "$_bib_claim_pool" || return 2
    return "$_bib_claim_status"
}

build_invariance_pool_finish() {
    _bib_finish_pool=$1
    _bib_finish_job=$2
    _bib_finish_status=$3
    build_invariance_pool_lock "$_bib_finish_pool" || return 2
    _bib_finish_result=0
    if [ ! -f "$_bib_finish_pool/running/$_bib_finish_job" ] ||
        [ -e "$_bib_finish_pool/results/$_bib_finish_job" ]; then
        echo "[build-invariance] pool job finished without running once: $_bib_finish_job" >&2
        _bib_finish_result=2
    else
        # Waiters poll for the result, so it must appear complete or not at all.
        printf '%s\n' "$_bib_finish_status" > "$_bib_finish_pool/result.$_bib_finish_job.tmp"
        mv "$_bib_finish_pool/result.$_bib_finish_job.tmp" \
            "$_bib_finish_pool/results/$_bib_finish_job"
        rm -f "$_bib_finish_pool/running/$_bib_finish_job"
    fi
    build_invariance_pool_unlock "$_bib_finish_pool" || return 2
    return "$_bib_finish_result"
}

# A drained pool proves nothing by itself: a worker that died, a job that never
# started and a result that belongs to no queued job must all fail here.
build_invariance_pool_require_complete() {
    _bib_complete_pool=$1
    if [ -e "$_bib_complete_pool/abort" ] || [ -e "$_bib_complete_pool/lock" ]; then
        echo "[build-invariance] pool was aborted or left locked" >&2
        return 1
    fi
    for _bib_complete_running in "$_bib_complete_pool/running"/*; do
        [ -e "$_bib_complete_running" ] || continue
        echo "[build-invariance] pool job never finished: ${_bib_complete_running##*/}" >&2
        return 1
    done
    while IFS='|' read -r _bib_complete_job _bib_complete_cap; do
        if [ ! -d "$_bib_complete_pool/claims/$_bib_complete_job" ] ||
            [ ! -f "$_bib_complete_pool/results/$_bib_complete_job" ] ||
            [ "$(cat "$_bib_complete_pool/results/$_bib_complete_job")" != 0 ]; then
            echo "[build-invariance] pool job has no successful result: $_bib_complete_job" >&2
            return 1
        fi
    done < "$_bib_complete_pool/queue"
    _bib_complete_jobs=$(wc -l < "$_bib_complete_pool/queue" | tr -d ' ')
    for _bib_complete_kind in claims results; do
        _bib_complete_count=$(find "$_bib_complete_pool/$_bib_complete_kind" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
        if [ "$_bib_complete_count" -ne "$_bib_complete_jobs" ]; then
            echo "[build-invariance] pool $_bib_complete_kind do not match the queue: $_bib_complete_count of $_bib_complete_jobs" >&2
            return 1
        fi
    done
}

# Workers run the caller's `build_invariance_pool_run_job JOB CAP_MIB` in
# subshells. A job that fails, or exits its worker, aborts the pool: jobs that
# are already running finish, and no further job starts.
build_invariance_pool_worker_exit() {
    if [ "$1" -ne 0 ]; then
        : > "$_bib_worker_pool/abort"
        if [ -n "$_bib_worker_job" ]; then
            build_invariance_pool_finish "$_bib_worker_pool" "$_bib_worker_job" "$1" || true
        fi
    fi
}

build_invariance_pool_worker() {
    _bib_worker_pool=$1
    _bib_worker_job=
    trap 'build_invariance_pool_worker_exit $?' EXIT
    while :; do
        _bib_worker_claim_status=0
        _bib_worker_claimed=$(build_invariance_pool_claim "$_bib_worker_pool") ||
            _bib_worker_claim_status=$?
        case "$_bib_worker_claim_status" in
            0) ;;
            1) break ;;
            3)
                sleep 1
                continue
                ;;
            *) exit 1 ;;
        esac
        _bib_worker_job=${_bib_worker_claimed%%|*}
        # Not part of a condition, so the caller's `set -e` stays in force
        # inside the job.
        build_invariance_pool_run_job "$_bib_worker_job" "${_bib_worker_claimed##*|}"
        _bib_worker_status=$?
        [ "$_bib_worker_status" -eq 0 ] || exit "$_bib_worker_status"
        build_invariance_pool_finish "$_bib_worker_pool" "$_bib_worker_job" 0 || exit 1
        _bib_worker_job=
    done
}

build_invariance_pool_start() {
    _bib_start_pool=$1
    _bib_start_workers=$2
    BUILD_INVARIANCE_POOL_PIDS=
    while [ "$_bib_start_workers" -gt 0 ]; do
        _bib_start_workers=$((_bib_start_workers - 1))
        ( build_invariance_pool_worker "$_bib_start_pool" ) &
        BUILD_INVARIANCE_POOL_PIDS="$BUILD_INVARIANCE_POOL_PIDS $!"
    done
}

# Block until every named job has succeeded. A failed job, an aborted pool and
# workers that are all gone without the result fail instead of waiting forever.
build_invariance_pool_wait_for() {
    _bib_wait_pool=$1
    shift
    while :; do
        _bib_wait_missing=
        for _bib_wait_job in "$@"; do
            if [ ! -f "$_bib_wait_pool/results/$_bib_wait_job" ]; then
                _bib_wait_missing=$_bib_wait_job
            elif [ "$(cat "$_bib_wait_pool/results/$_bib_wait_job")" != 0 ]; then
                echo "[build-invariance] pool job failed: $_bib_wait_job" >&2
                return 1
            fi
        done
        [ -n "$_bib_wait_missing" ] || return 0
        if [ -e "$_bib_wait_pool/abort" ]; then
            echo "[build-invariance] worker pool aborted before $_bib_wait_missing finished" >&2
            return 1
        fi
        _bib_wait_alive=0
        for _bib_wait_pid in $BUILD_INVARIANCE_POOL_PIDS; do
            if kill -0 "$_bib_wait_pid" 2>/dev/null; then
                _bib_wait_alive=1
            fi
        done
        if [ "$_bib_wait_alive" -eq 0 ] &&
            [ ! -f "$_bib_wait_pool/results/$_bib_wait_missing" ]; then
            echo "[build-invariance] every pool worker exited without a result for $_bib_wait_missing" >&2
            return 1
        fi
        sleep 1
    done
}

build_invariance_pool_join() {
    _bib_join_status=0
    for _bib_join_pid in $BUILD_INVARIANCE_POOL_PIDS; do
        wait "$_bib_join_pid" || _bib_join_status=1
    done
    BUILD_INVARIANCE_POOL_PIDS=
    if [ "$_bib_join_status" -ne 0 ]; then
        echo "[build-invariance] a pool worker failed" >&2
        return 1
    fi
    build_invariance_pool_require_complete "$1"
}

# For the caller's own failure path: leave no compile running behind it.
build_invariance_pool_stop() {
    : > "$1/abort"
    for _bib_stop_pid in $BUILD_INVARIANCE_POOL_PIDS; do
        wait "$_bib_stop_pid" 2>/dev/null || true
    done
    BUILD_INVARIANCE_POOL_PIDS=
}
