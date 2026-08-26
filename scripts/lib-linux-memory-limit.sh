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
# process group once observed RSS crosses the configured ceiling. A launch
# gate keeps user code suspended until process-group isolation and the first
# successful memory sample are established.

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

    if [ -z "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
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
        return $?
    fi

    # With --wait, systemd reports a post-run MemoryPeak. Some managers account
    # only the service launcher in that summary, while the service is not a
    # descendant that an outer wait4(2) measurement can cover. Preserve the
    # larger in-cgroup process-group sample when the bounded runner supplies
    # one; direct callers still get the systemd evidence.
    _linux_memory_limit_systemd_stderr="$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE.systemd-stderr"
    rm -f "$_linux_memory_limit_systemd_stderr"
    _linux_memory_limit_status=0
    LC_ALL=C SYSTEMD_COLORS=0 systemd-run \
        --user \
        --wait \
        --pipe \
        --collect \
        --same-dir \
        --service-type=exec \
        --property=MemoryAccounting=yes \
        --property="MemoryMax=$_linux_memory_limit_bytes" \
        --property=MemorySwapMax=0 \
        --property=OOMPolicy=kill \
        "$@" 2> "$_linux_memory_limit_systemd_stderr" ||
        _linux_memory_limit_status=$?
    cat "$_linux_memory_limit_systemd_stderr" >&2
    _linux_memory_limit_peak_bytes=$(awk '
        /^[[:space:]]*Memory peak: / { raw = $3 }
        END {
            if (raw == "") exit 1
            suffix = substr(raw, length(raw), 1)
            if (suffix ~ /[0-9]/) {
                value = raw + 0
                factor = 1
            } else {
                value = substr(raw, 1, length(raw) - 1) + 0
                if (suffix == "B") factor = 1
                else if (suffix == "K") factor = 1024
                else if (suffix == "M") factor = 1024 * 1024
                else if (suffix == "G") factor = 1024 * 1024 * 1024
                else if (suffix == "T") factor = 1024 * 1024 * 1024 * 1024
                else exit 1
            }
            printf "%.0f\n", value * factor
        }
    ' "$_linux_memory_limit_systemd_stderr" 2>/dev/null || true)
    _linux_memory_limit_sampled_bytes=0
    if [ -s "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE" ]; then
        _linux_memory_limit_sampled_bytes=$(sed -n '1p' \
            "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE")
        case "$_linux_memory_limit_sampled_bytes" in
            "" | *[!0-9]*) _linux_memory_limit_sampled_bytes=0 ;;
        esac
    fi
    case "$_linux_memory_limit_peak_bytes" in
        "" | *[!0-9]*) _linux_memory_limit_peak_bytes=0 ;;
    esac
    if [ "$_linux_memory_limit_sampled_bytes" -gt "$_linux_memory_limit_peak_bytes" ]; then
        _linux_memory_limit_peak_bytes=$_linux_memory_limit_sampled_bytes
    fi
    printf '%s\n' "$_linux_memory_limit_peak_bytes" \
        > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
    if grep -Eq 'result: oom-kill|result .oom-kill.' \
        "$_linux_memory_limit_systemd_stderr"; then
        rm -f "$_linux_memory_limit_systemd_stderr"
        return 137
    fi
    rm -f "$_linux_memory_limit_systemd_stderr"
    return "$_linux_memory_limit_status"
}

linux_memory_limit_watchdog_available() {
    [ -d /proc ] || return 1
    command -v setsid >/dev/null 2>&1 || return 1
    command -v ps >/dev/null 2>&1 || return 1
    command -v awk >/dev/null 2>&1 || return 1
    command -v sleep >/dev/null 2>&1 || return 1
    command -v mktemp >/dev/null 2>&1 || return 1
    command -v rm >/dev/null 2>&1 || return 1
    command -v rmdir >/dev/null 2>&1 || return 1
    command -v sh >/dev/null 2>&1 || return 1
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
    _linux_memory_limit_peak_rss=0

    # Keep the requested command behind a filesystem gate. The waiting shell
    # gives the parent time to verify the new process group and take a positive
    # RSS sample before any user code can execute, including commands which
    # would otherwise finish between fork and the first watchdog poll.
    _linux_memory_limit_gate_dir=$(mktemp -d \
        "${TMPDIR:-/tmp}/typelisp-memory-watchdog.XXXXXX") || {
        echo "RSS watchdog failed to create launch gate" >&2
        return 1
    }
    _linux_memory_limit_gate="$_linux_memory_limit_gate_dir/start"
    setsid sh -c '
        gate=$1
        shift
        while [ ! -e "$gate" ]; do sleep 0.01; done
        exec "$@"
    ' sh "$_linux_memory_limit_gate" "$@" &
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
        if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
            printf '0\n' > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
        fi
        rm -f "$_linux_memory_limit_gate"
        rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
        return "$_linux_memory_limit_status"
    fi
    if [ "$_linux_memory_limit_pgid" -ne "$_linux_memory_limit_pid" ]; then
        kill "$_linux_memory_limit_pid" 2>/dev/null || true
        wait "$_linux_memory_limit_pid" 2>/dev/null || true
        rm -f "$_linux_memory_limit_gate"
        rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
        echo "RSS watchdog failed to isolate command process group" >&2
        return 1
    fi

    _linux_memory_limit_sample_attempt=0
    _linux_memory_limit_rss=0
    while [ "$_linux_memory_limit_rss" -eq 0 ] \
        && [ "$_linux_memory_limit_sample_attempt" -lt 20 ]; do
        _linux_memory_limit_rss=$(linux_memory_limit_process_group_rss_kib \
            "$_linux_memory_limit_pid") || {
                kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
                wait "$_linux_memory_limit_pid" 2>/dev/null || true
                rm -f "$_linux_memory_limit_gate"
                rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
                echo "RSS watchdog failed to read initial process memory" >&2
                return 1
            }
        if [ "$_linux_memory_limit_rss" -eq 0 ]; then
            sleep 0.01
        fi
        _linux_memory_limit_sample_attempt=$((_linux_memory_limit_sample_attempt + 1))
    done
    if [ "$_linux_memory_limit_rss" -eq 0 ]; then
        kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
        wait "$_linux_memory_limit_pid" 2>/dev/null || true
        rm -f "$_linux_memory_limit_gate"
        rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
        echo "RSS watchdog failed to establish initial memory measurement" >&2
        return 1
    fi
    _linux_memory_limit_peak_rss=$_linux_memory_limit_rss
    if [ "$_linux_memory_limit_rss" -gt "$_linux_memory_limit_kib" ]; then
        echo "memory limit exceeded before command launch: aggregate RSS ${_linux_memory_limit_rss} KiB > ${_linux_memory_limit_kib} KiB (rss-watchdog fallback)" >&2
        kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
        wait "$_linux_memory_limit_pid" 2>/dev/null || true
        rm -f "$_linux_memory_limit_gate"
        rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
        if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
            printf '%s\n' "$((_linux_memory_limit_peak_rss * 1024))" \
                > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
        fi
        return 137
    fi
    : > "$_linux_memory_limit_gate"

    while :; do
        _linux_memory_limit_rss=$(linux_memory_limit_process_group_rss_kib \
            "$_linux_memory_limit_pid") || {
                kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
                wait "$_linux_memory_limit_pid" 2>/dev/null || true
                rm -f "$_linux_memory_limit_gate"
                rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
                echo "RSS watchdog failed to read process memory" >&2
                return 1
            }
        if [ "$_linux_memory_limit_rss" -eq 0 ]; then
            break
        fi
        if [ "$_linux_memory_limit_rss" -gt "$_linux_memory_limit_peak_rss" ]; then
            _linux_memory_limit_peak_rss=$_linux_memory_limit_rss
        fi
        if [ "$_linux_memory_limit_rss" -gt "$_linux_memory_limit_kib" ]; then
            echo "memory limit exceeded: aggregate RSS ${_linux_memory_limit_rss} KiB > ${_linux_memory_limit_kib} KiB (rss-watchdog fallback)" >&2
            kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
            sleep 0.1
            kill -KILL "-$_linux_memory_limit_pid" 2>/dev/null || true
            wait "$_linux_memory_limit_pid" 2>/dev/null || true
            rm -f "$_linux_memory_limit_gate"
            rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
            if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
                printf '%s\n' "$((_linux_memory_limit_peak_rss * 1024))" \
                    > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
            fi
            return 137
        fi
        sleep "$_linux_memory_limit_poll"
    done

    if wait "$_linux_memory_limit_pid"; then
        _linux_memory_limit_status=0
    else
        _linux_memory_limit_status=$?
    fi
    rm -f "$_linux_memory_limit_gate"
    rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
    if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
        printf '%s\n' "$((_linux_memory_limit_peak_rss * 1024))" \
            > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
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
