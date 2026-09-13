#!/usr/bin/env sh
# Private synchronization helpers for the package-lock CLI fixtures.
# Caller supplies fail() and WORKDIR with <label>.out/.err captures.

package_lock_wait_ready() {
    if [ "$_wait_kind" = stage ]; then
        _wait_stage=$(find "$_wait_path" -maxdepth 1 -type f -name 'typelisp.lock.stage.*' -print -quit)
        [ -n "$_wait_stage" ]
    else
        [ -f "$_wait_path" ] && grep -F -- "$_wait_text" "$_wait_path" >/dev/null
    fi
}

package_lock_wait_failure() {
    for _wait_stream in out err; do
        if [ -f "$WORKDIR/$_wait_label.$_wait_stream" ]; then
            echo "$_wait_label.$_wait_stream:" >&2
            sed 's/^/  /' "$WORKDIR/$_wait_label.$_wait_stream" >&2 || true
        fi
    done
    fail "$*"
}

package_lock_wait_output() {
    _wait_kind=$1
    _wait_path=$2
    _wait_text=$3
    _wait_pid=$4
    _wait_label=$5
    if [ "$_wait_kind" = stage ]; then
        _wait_action='publishing its staging file'
        _wait_timeout='publish a staging file'
    else
        _wait_action='committing the expected lock'
        _wait_timeout='commit the expected lock'
    fi
    _wait_attempt=0
    while [ "$_wait_attempt" -lt 600 ]; do
        package_lock_wait_ready && return 0
        if ! kill -0 "$_wait_pid" 2>/dev/null; then
            # The writer may publish and exit after our first observation.
            # Recheck the exact predicate after observing termination. The
            # caller still waits for and verifies each child's final status.
            package_lock_wait_ready && return 0
            package_lock_wait_failure "$_wait_label exited before $_wait_action"
        fi
        sleep 0.1
        _wait_attempt=$((_wait_attempt + 1))
    done
    package_lock_wait_failure "$_wait_label did not $_wait_timeout within 60s"
}

wait_for_package_lock_stage() {
    package_lock_wait_output stage "$1" '' "$2" "$3"
}

wait_for_package_lock_text() {
    package_lock_wait_output text "$1" "$2" "$3" "$4"
}
