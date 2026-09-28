#!/usr/bin/env sh

# Bounded worker pool shared by CI work that runs independent jobs at once
# (ci-verify.sh gates, build-invariance chunks, integration batch chunks).
#
# Callers set BOUNDED_POOL_LABEL (the `[label]` prefix of every diagnostic) and
# define `bounded_pool_run_job JOB CAP_MIB`, which runs one job and returns its
# status. The pool itself enforces no memory limit: it only admits a job while
# the caps of all running jobs fit the budget, so a caller that promises a hard
# bound runs each job under the cap it was admitted with.
BOUNDED_POOL_LABEL=${BOUNDED_POOL_LABEL:-pool}

# Worker pool. A queue lists every job once as `job|cap_mib`, optionally
# followed by `|need,...` (earlier jobs that must succeed before it starts, or
# `-`) and `|lock,...` (shared resources no two running jobs may hold at once).
# Workers claim the first job in queue order whose needs have succeeded, whose
# locks are free, and whose cap fits the pool budget beside the caps of all
# running jobs. Needs name earlier jobs only, so the first unclaimed job always
# becomes claimable once the running jobs finish, and one worker runs the queue
# in order. State lives in directories whose creation is atomic: `claims/` (one
# per started job), `running/` (its cap and locks while it runs), `held/` (one
# per held lock) and `results/` (its exit status).
BOUNDED_POOL_LOCK_TRIES=${BOUNDED_POOL_LOCK_TRIES:-600}

bounded_pool_lock() {
    _bp_lock_tries=0
    until mkdir "$1/lock" 2>/dev/null; do
        _bp_lock_tries=$((_bp_lock_tries + 1))
        if [ "$_bp_lock_tries" -ge "$BOUNDED_POOL_LOCK_TRIES" ]; then
            echo "[$BOUNDED_POOL_LABEL] pool lock was not released: $1/lock" >&2
            return 2
        fi
        sleep 0.1
    done
}

bounded_pool_unlock() {
    rmdir "$1/lock"
}

bounded_pool_require_queue() {
    _bp_queue_budget=$1
    _bp_queue=$2
    case "$_bp_queue_budget" in
        "" | *[!0-9]* | 0*)
            echo "[$BOUNDED_POOL_LABEL] invalid pool budget: $_bp_queue_budget" >&2
            return 2
            ;;
    esac
    # Workers and the completeness check read the queue with `read` and `wc -l`,
    # which both drop a final record that lacks its newline; awk below would
    # still count it, so such a queue must not start a pool.
    if [ -s "$_bp_queue" ] && [ -n "$(tail -c 1 "$_bp_queue")" ]; then
        echo "[$BOUNDED_POOL_LABEL] invalid pool queue: last record is not newline-terminated" >&2
        return 2
    fi
    awk -F '|' -v budget="$_bp_queue_budget" -v label="$BOUNDED_POOL_LABEL" '
        function fail(message) {
            print "[" label "] invalid pool queue: " message > "/dev/stderr"
            failed = 1
            exit 2
        }
        {
            if (NF < 2 || NF > 4 || $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/)
                fail("malformed job record")
            if ($2 !~ /^[1-9][0-9]*$/) fail("malformed cap for " $1)
            if ($2 + 0 > budget + 0) fail("cap of " $1 " exceeds the pool budget")
            if (seen[$1]++) fail("duplicate job " $1)
            if (NF >= 3 && $3 != "-") {
                needs = split($3, list, ",")
                if (needs == 0) fail("empty needs for " $1)
                for (n = 1; n <= needs; n++)
                    if (!(list[n] in seen) || list[n] == $1)
                        fail($1 " needs an unknown or later job: " list[n])
            }
            if (NF == 4) {
                locks = split($4, list, ",")
                if (locks == 0) fail("empty locks for " $1)
                delete lock_seen
                for (n = 1; n <= locks; n++)
                    if (list[n] !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || lock_seen[list[n]]++)
                        fail("malformed or duplicate lock for " $1 ": " list[n])
            }
            count++
        }
        END { if (!failed && count == 0) fail("empty queue") }
    ' "$_bp_queue"
}

bounded_pool_init() {
    _bp_pool=$1
    _bp_pool_budget=$2
    _bp_pool_queue=$3
    bounded_pool_require_queue "$_bp_pool_budget" "$_bp_pool_queue" || return 2
    rm -rf "$_bp_pool"
    mkdir -p "$_bp_pool/claims" "$_bp_pool/running" "$_bp_pool/held" "$_bp_pool/results"
    printf '%s\n' "$_bp_pool_budget" > "$_bp_pool/budget"
    cp "$_bp_pool_queue" "$_bp_pool/queue"
}

# Succeeds when every job of the comma-separated list succeeded.
bounded_pool_needs_met() {
    _bp_needs_results=$1/results
    _bp_needs_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086
    set -- $2
    IFS=$_bp_needs_ifs
    for _bp_needs_job in "$@"; do
        [ -f "$_bp_needs_results/$_bp_needs_job" ] || return 1
        read -r _bp_needs_status < "$_bp_needs_results/$_bp_needs_job" || return 1
        [ "$_bp_needs_status" = 0 ] || return 1
    done
}

# Succeeds when no running job holds a lock of the comma-separated list.
bounded_pool_locks_free() {
    _bp_free_held=$1/held
    _bp_free_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086
    set -- $2
    IFS=$_bp_free_ifs
    for _bp_free_lock in "$@"; do
        [ ! -d "$_bp_free_held/$_bp_free_lock" ] || return 1
    done
}

# Creates (take) or removes (release) the held entry of each listed lock.
bounded_pool_locks_update() {
    _bp_update_held=$1/held
    _bp_update_action=$2
    _bp_update_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086
    set -- $3
    IFS=$_bp_update_ifs
    for _bp_update_lock in "$@"; do
        case "$_bp_update_action" in
            take) mkdir "$_bp_update_held/$_bp_update_lock" || return 1 ;;
            release) rmdir "$_bp_update_held/$_bp_update_lock" || return 1 ;;
        esac
    done
}

# Prints `job|cap_mib` for the first unclaimed job whose needs succeeded, whose
# locks are free and that fits the budget. Returns 1 once every job is claimed
# and 3 while unclaimed jobs must wait for running ones; 2 reports a broken
# pool.
bounded_pool_claim() {
    _bp_claim_pool=$1
    if [ -e "$_bp_claim_pool/abort" ]; then
        echo "[$BOUNDED_POOL_LABEL] pool was aborted; no further job starts" >&2
        return 2
    fi
    bounded_pool_lock "$_bp_claim_pool" || return 2
    read -r _bp_claim_budget < "$_bp_claim_pool/budget"
    _bp_claim_used=0
    for _bp_claim_running in "$_bp_claim_pool/running"/*; do
        [ -f "$_bp_claim_running" ] || continue
        read -r _bp_claim_running_cap < "$_bp_claim_running"
        _bp_claim_used=$((_bp_claim_used + _bp_claim_running_cap))
    done
    _bp_claim_status=1
    while IFS='|' read -r _bp_claim_job _bp_claim_cap _bp_claim_needs _bp_claim_locks; do
        [ ! -d "$_bp_claim_pool/claims/$_bp_claim_job" ] || continue
        _bp_claim_status=3
        [ -z "$_bp_claim_needs" ] || [ "$_bp_claim_needs" = - ] ||
            bounded_pool_needs_met "$_bp_claim_pool" "$_bp_claim_needs" || continue
        [ $((_bp_claim_used + _bp_claim_cap)) -le "$_bp_claim_budget" ] || continue
        [ -z "$_bp_claim_locks" ] ||
            bounded_pool_locks_free "$_bp_claim_pool" "$_bp_claim_locks" || continue
        if ! mkdir "$_bp_claim_pool/claims/$_bp_claim_job" ||
            ! printf '%s\n%s\n' "$_bp_claim_cap" "$_bp_claim_locks" \
                > "$_bp_claim_pool/running/$_bp_claim_job" ||
            ! bounded_pool_locks_update "$_bp_claim_pool" take "$_bp_claim_locks"; then
            _bp_claim_status=2
            break
        fi
        printf '%s|%s\n' "$_bp_claim_job" "$_bp_claim_cap"
        _bp_claim_status=0
        break
    done < "$_bp_claim_pool/queue"
    bounded_pool_unlock "$_bp_claim_pool" || return 2
    return "$_bp_claim_status"
}

bounded_pool_finish() {
    _bp_finish_pool=$1
    _bp_finish_job=$2
    _bp_finish_status=$3
    bounded_pool_lock "$_bp_finish_pool" || return 2
    _bp_finish_result=0
    if [ ! -f "$_bp_finish_pool/running/$_bp_finish_job" ] ||
        [ -e "$_bp_finish_pool/results/$_bp_finish_job" ]; then
        echo "[$BOUNDED_POOL_LABEL] pool job finished without running once: $_bp_finish_job" >&2
        _bp_finish_result=2
    else
        # Waiters poll for the result, so it must appear complete or not at all.
        printf '%s\n' "$_bp_finish_status" > "$_bp_finish_pool/result.$_bp_finish_job.tmp"
        mv "$_bp_finish_pool/result.$_bp_finish_job.tmp" \
            "$_bp_finish_pool/results/$_bp_finish_job"
        _bp_finish_locks=
        { read -r _bp_finish_cap && read -r _bp_finish_locks; } \
            < "$_bp_finish_pool/running/$_bp_finish_job" || true
        bounded_pool_locks_update "$_bp_finish_pool" release "$_bp_finish_locks" ||
            _bp_finish_result=2
        rm -f "$_bp_finish_pool/running/$_bp_finish_job"
    fi
    bounded_pool_unlock "$_bp_finish_pool" || return 2
    return "$_bp_finish_result"
}

# A drained pool proves nothing by itself: a worker that died, a job that never
# started and a result that belongs to no queued job must all fail here.
bounded_pool_require_complete() {
    _bp_complete_pool=$1
    if [ -e "$_bp_complete_pool/abort" ] || [ -e "$_bp_complete_pool/lock" ]; then
        echo "[$BOUNDED_POOL_LABEL] pool was aborted or left locked" >&2
        return 1
    fi
    for _bp_complete_running in "$_bp_complete_pool/running"/*; do
        [ -e "$_bp_complete_running" ] || continue
        echo "[$BOUNDED_POOL_LABEL] pool job never finished: ${_bp_complete_running##*/}" >&2
        return 1
    done
    for _bp_complete_held in "$_bp_complete_pool/held"/*; do
        [ -e "$_bp_complete_held" ] || continue
        echo "[$BOUNDED_POOL_LABEL] pool lock was never released: ${_bp_complete_held##*/}" >&2
        return 1
    done
    while IFS='|' read -r _bp_complete_job _bp_complete_cap; do
        if [ ! -d "$_bp_complete_pool/claims/$_bp_complete_job" ] ||
            [ ! -f "$_bp_complete_pool/results/$_bp_complete_job" ] ||
            [ "$(cat "$_bp_complete_pool/results/$_bp_complete_job")" != 0 ]; then
            echo "[$BOUNDED_POOL_LABEL] pool job has no successful result: $_bp_complete_job" >&2
            return 1
        fi
    done < "$_bp_complete_pool/queue"
    _bp_complete_jobs=$(wc -l < "$_bp_complete_pool/queue" | tr -d ' ')
    for _bp_complete_kind in claims results; do
        _bp_complete_count=$(find "$_bp_complete_pool/$_bp_complete_kind" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
        if [ "$_bp_complete_count" -ne "$_bp_complete_jobs" ]; then
            echo "[$BOUNDED_POOL_LABEL] pool $_bp_complete_kind do not match the queue: $_bp_complete_count of $_bp_complete_jobs" >&2
            return 1
        fi
    done
}

# Workers run the caller's `bounded_pool_run_job JOB CAP_MIB` in
# subshells. A job that fails, or exits its worker, aborts the pool: jobs that
# are already running finish, and no further job starts.
bounded_pool_worker_exit() {
    if [ "$1" -ne 0 ]; then
        : > "$_bp_worker_pool/abort"
        if [ -n "$_bp_worker_job" ]; then
            bounded_pool_finish "$_bp_worker_pool" "$_bp_worker_job" "$1" || true
        fi
    fi
}

bounded_pool_worker() {
    _bp_worker_pool=$1
    _bp_worker_job=
    trap 'bounded_pool_worker_exit $?' EXIT
    while :; do
        _bp_worker_claim_status=0
        _bp_worker_claimed=$(bounded_pool_claim "$_bp_worker_pool") ||
            _bp_worker_claim_status=$?
        case "$_bp_worker_claim_status" in
            0) ;;
            1) break ;;
            3)
                sleep 1
                continue
                ;;
            *) exit 1 ;;
        esac
        _bp_worker_job=${_bp_worker_claimed%%|*}
        # Not part of a condition, so the caller's `set -e` stays in force
        # inside the job.
        bounded_pool_run_job "$_bp_worker_job" "${_bp_worker_claimed##*|}"
        _bp_worker_status=$?
        [ "$_bp_worker_status" -eq 0 ] || exit "$_bp_worker_status"
        bounded_pool_finish "$_bp_worker_pool" "$_bp_worker_job" 0 || exit 1
        _bp_worker_job=
    done
}

bounded_pool_start() {
    _bp_start_pool=$1
    _bp_start_workers=$2
    BOUNDED_POOL_PIDS=
    while [ "$_bp_start_workers" -gt 0 ]; do
        _bp_start_workers=$((_bp_start_workers - 1))
        ( bounded_pool_worker "$_bp_start_pool" ) &
        BOUNDED_POOL_PIDS="$BOUNDED_POOL_PIDS $!"
    done
}

# Block until every named job has succeeded. A failed job, an aborted pool and
# workers that are all gone without the result fail instead of waiting forever.
bounded_pool_wait_for() {
    _bp_wait_pool=$1
    shift
    while :; do
        _bp_wait_missing=
        for _bp_wait_job in "$@"; do
            if [ ! -f "$_bp_wait_pool/results/$_bp_wait_job" ]; then
                _bp_wait_missing=$_bp_wait_job
            elif [ "$(cat "$_bp_wait_pool/results/$_bp_wait_job")" != 0 ]; then
                echo "[$BOUNDED_POOL_LABEL] pool job failed: $_bp_wait_job" >&2
                return 1
            fi
        done
        [ -n "$_bp_wait_missing" ] || return 0
        if [ -e "$_bp_wait_pool/abort" ]; then
            echo "[$BOUNDED_POOL_LABEL] worker pool aborted before $_bp_wait_missing finished" >&2
            return 1
        fi
        _bp_wait_alive=0
        for _bp_wait_pid in $BOUNDED_POOL_PIDS; do
            if kill -0 "$_bp_wait_pid" 2>/dev/null; then
                _bp_wait_alive=1
            fi
        done
        if [ "$_bp_wait_alive" -eq 0 ] &&
            [ ! -f "$_bp_wait_pool/results/$_bp_wait_missing" ]; then
            echo "[$BOUNDED_POOL_LABEL] every pool worker exited without a result for $_bp_wait_missing" >&2
            return 1
        fi
        sleep 1
    done
}

bounded_pool_join() {
    _bp_join_status=0
    for _bp_join_pid in $BOUNDED_POOL_PIDS; do
        wait "$_bp_join_pid" || _bp_join_status=1
    done
    BOUNDED_POOL_PIDS=
    if [ "$_bp_join_status" -ne 0 ]; then
        echo "[$BOUNDED_POOL_LABEL] a pool worker failed" >&2
        return 1
    fi
    bounded_pool_require_complete "$1"
}

# For the caller's own failure path: leave no compile running behind it.
bounded_pool_stop() {
    : > "$1/abort"
    for _bp_stop_pid in $BOUNDED_POOL_PIDS; do
        wait "$_bp_stop_pid" 2>/dev/null || true
    done
    BOUNDED_POOL_PIDS=
}
