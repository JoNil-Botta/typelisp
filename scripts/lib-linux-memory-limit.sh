#!/usr/bin/env sh

# Linux resident-memory limits for focused compiler probes.
#
# Prefer a transient user-systemd service: MemoryMax is a kernel-enforced
# cgroup limit over the complete process tree and MemorySwapMax=0 keeps the
# result resident. GitHub-hosted runners and minimal Linux environments may
# have systemd-run installed without a usable user manager, so auto-detection
# probes the complete invocation before selecting it.
#
# The fallback launches the command in a new process group and samples that
# group's aggregate RSS from `ps`. It does not cap virtual address space and
# therefore avoids the mmap-reservation failures caused by RLIMIT_AS. The
# fallback can briefly overshoot between samples, but terminates the complete
# process group once observed RSS crosses the configured ceiling.

LINUX_MEMORY_LIMIT_BACKEND=${LINUX_MEMORY_LIMIT_BACKEND:-}

linux_memory_limit_validate_bytes() {
    case "$1" in
        "" | *[!0-9]* | 0)
            echo "Linux memory limit must be a positive byte count: $1" >&2
            return 2
            ;;
    esac
}

linux_memory_limit_systemd_available() {
    command -v systemd-run >/dev/null 2>&1 || return 1
    command -v env >/dev/null 2>&1 || return 1
    command -v sed >/dev/null 2>&1 || return 1
    systemd-run \
        --user \
        --quiet \
        --wait \
        --pipe \
        --collect \
        --same-dir \
        --service-type=exec \
        --property=MemoryAccounting=yes \
        --property=MemoryMax=67108864 \
        --property=MemorySwapMax=0 \
        --property=OOMPolicy=kill \
        -- true >/dev/null 2>&1
}

linux_memory_limit_run_systemd() {
    _linux_memory_limit_bytes=$1
    shift

    # Transient user services inherit the user manager's environment, not the
    # invoking gate's exports. Prepend one --setenv=name option per valid
    # environment name; omitting `=value` asks systemd-run to copy the exact
    # value from its own process environment without shell re-quoting it.
    set -- -- "$@"
    for _linux_memory_limit_env_name in $(env | sed -n \
        's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
        set -- "--setenv=$_linux_memory_limit_env_name" "$@"
    done

    systemd-run \
        --user \
        --quiet \
        --wait \
        --pipe \
        --collect \
        --same-dir \
        --service-type=exec \
        --property=MemoryAccounting=yes \
        --property="MemoryMax=$_linux_memory_limit_bytes" \
        --property=MemorySwapMax=0 \
        --property=OOMPolicy=kill \
        "$@"
}

linux_memory_limit_watchdog_available() {
    [ -d /proc ] || return 1
    command -v setsid >/dev/null 2>&1 || return 1
    command -v ps >/dev/null 2>&1 || return 1
    command -v awk >/dev/null 2>&1 || return 1
    command -v sleep >/dev/null 2>&1 || return 1
    ps -e -o pid= -o pgid= -o rss= >/dev/null 2>&1
}

linux_memory_limit_select_backend() {
    if [ -n "$LINUX_MEMORY_LIMIT_BACKEND" ]; then
        return 0
    fi

    _linux_memory_limit_requested=${TYPELISP_LINUX_MEMORY_LIMIT_BACKEND:-auto}
    case "$_linux_memory_limit_requested" in
        auto)
            if linux_memory_limit_systemd_available; then
                LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup
            elif linux_memory_limit_watchdog_available; then
                LINUX_MEMORY_LIMIT_BACKEND=rss-watchdog
            else
                echo "Linux memory limiting requires a usable user systemd manager or setsid/ps/awk RSS watchdog" >&2
                return 1
            fi
            ;;
        systemd-user-cgroup)
            if ! linux_memory_limit_systemd_available; then
                echo "requested Linux memory-limit backend is unavailable: systemd-user-cgroup" >&2
                return 1
            fi
            LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup
            ;;
        rss-watchdog)
            if ! linux_memory_limit_watchdog_available; then
                echo "requested Linux memory-limit backend is unavailable: rss-watchdog" >&2
                return 1
            fi
            LINUX_MEMORY_LIMIT_BACKEND=rss-watchdog
            ;;
        *)
            echo "unknown TYPELISP_LINUX_MEMORY_LIMIT_BACKEND: $_linux_memory_limit_requested" >&2
            return 2
            ;;
    esac
}

linux_memory_limit_process_group_rss_kib() {
    _linux_memory_limit_group=$1
    ps -e -o pid= -o pgid= -o rss= | awk \
        -v group="$_linux_memory_limit_group" '
            $2 == group { total += $3 }
            END { print total + 0 }
        '
}

linux_memory_limit_run_watchdog() {
    _linux_memory_limit_bytes=$1
    shift
    _linux_memory_limit_kib=$(((_linux_memory_limit_bytes + 1023) / 1024))
    _linux_memory_limit_poll=${TYPELISP_LINUX_MEMORY_LIMIT_POLL_SECONDS:-0.05}

    setsid "$@" &
    _linux_memory_limit_pid=$!
    _linux_memory_limit_pgid=$(ps -o pgid= -p "$_linux_memory_limit_pid" 2>/dev/null \
        | awk 'NR == 1 { print $1 }')
    _linux_memory_limit_isolation_attempt=0
    while [ -n "$_linux_memory_limit_pgid" ] \
        && [ "$_linux_memory_limit_pgid" -ne "$_linux_memory_limit_pid" ] \
        && [ "$_linux_memory_limit_isolation_attempt" -lt 20 ]; do
        # The parent can briefly observe the forked child before `setsid`
        # replaces it. Wait for the new session instead of treating that race
        # as a missing platform capability.
        sleep 0.01
        _linux_memory_limit_isolation_attempt=$((_linux_memory_limit_isolation_attempt + 1))
        _linux_memory_limit_pgid=$(ps -o pgid= -p "$_linux_memory_limit_pid" 2>/dev/null \
            | awk 'NR == 1 { print $1 }')
    done

    if [ -z "$_linux_memory_limit_pgid" ]; then
        if wait "$_linux_memory_limit_pid"; then
            _linux_memory_limit_status=0
        else
            _linux_memory_limit_status=$?
        fi
        return "$_linux_memory_limit_status"
    fi
    if [ "$_linux_memory_limit_pgid" -ne "$_linux_memory_limit_pid" ]; then
        kill "$_linux_memory_limit_pid" 2>/dev/null || true
        wait "$_linux_memory_limit_pid" 2>/dev/null || true
        echo "RSS watchdog failed to isolate command process group" >&2
        return 1
    fi

    while :; do
        _linux_memory_limit_rss=$(linux_memory_limit_process_group_rss_kib \
            "$_linux_memory_limit_pid") || {
                kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
                wait "$_linux_memory_limit_pid" 2>/dev/null || true
                echo "RSS watchdog failed to read process memory" >&2
                return 1
            }
        if [ "$_linux_memory_limit_rss" -eq 0 ]; then
            break
        fi
        if [ "$_linux_memory_limit_rss" -gt "$_linux_memory_limit_kib" ]; then
            echo "memory limit exceeded: aggregate RSS ${_linux_memory_limit_rss} KiB > ${_linux_memory_limit_kib} KiB (rss-watchdog fallback)" >&2
            kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
            sleep 0.1
            kill -KILL "-$_linux_memory_limit_pid" 2>/dev/null || true
            wait "$_linux_memory_limit_pid" 2>/dev/null || true
            return 137
        fi
        sleep "$_linux_memory_limit_poll"
    done

    if wait "$_linux_memory_limit_pid"; then
        _linux_memory_limit_status=0
    else
        _linux_memory_limit_status=$?
    fi
    return "$_linux_memory_limit_status"
}

linux_memory_limit_run() {
    if [ "$#" -lt 2 ]; then
        echo "usage: linux_memory_limit_run <bytes> <command> [arg ...]" >&2
        return 2
    fi
    _linux_memory_limit_bytes=$1
    shift
    linux_memory_limit_validate_bytes "$_linux_memory_limit_bytes" || return $?
    linux_memory_limit_select_backend || return $?

    case "$LINUX_MEMORY_LIMIT_BACKEND" in
        systemd-user-cgroup)
            linux_memory_limit_run_systemd "$_linux_memory_limit_bytes" "$@"
            ;;
        rss-watchdog)
            linux_memory_limit_run_watchdog "$_linux_memory_limit_bytes" "$@"
            ;;
        *)
            echo "invalid selected Linux memory-limit backend: $LINUX_MEMORY_LIMIT_BACKEND" >&2
            return 2
            ;;
    esac
}
