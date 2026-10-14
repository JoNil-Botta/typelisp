#!/usr/bin/env sh

# Linux resident-memory limits for compiler gates and probes.
#
# The only enforcement backend is a transient user-systemd service: MemoryMax
# is a kernel-enforced cgroup limit over the complete process tree and
# MemorySwapMax=0 keeps the result resident. A host without a usable user
# manager fails closed; nothing falls back to an unbounded run.
#
# linux_memory_limit_sample_process_group runs beside a capped workload child
# in a delegated service (see run-memory-bounded.sh). It launches the command
# in a new process group and
# samples the group's aggregate RSS from `ps` to report a trustworthy peak,
# terminating the group if observed RSS crosses the same ceiling. A launch gate
# keeps user code suspended until process-group isolation and the first
# successful memory sample are established. It never caps virtual address
# space, which avoids the mmap-reservation failures RLIMIT_AS causes. Under
# linux_memory_limit_run_sampled a workload OOM cannot select the sampler or
# its helpers, which record the workload cgroup's exact peak before exiting.

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
    _linux_memory_limit_service_bytes=$_linux_memory_limit_bytes

    # A metrics destination belongs to this invocation, not to its workload.
    # The bounded runner's explicit sampler re-establishes its own destination
    # from an argument; ordinary nested helpers must choose a fresh one.
    set -- env -u TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE \
        -u TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE "$@"

    # Transient user services inherit the user manager's environment, not the
    # invoking gate's exports. Prepend one --setenv=name option per valid
    # environment name; omitting `=value` asks systemd-run to copy the exact
    # value from its own process environment without shell re-quoting it.
    set -- -- "$@"
    if [ "${_linux_memory_limit_sampled:-0}" -eq 1 ]; then
        # The workload keeps its exact requested ceiling. The separate sampler
        # leaf has bounded headroom outside the workload's OOM domain.
        _linux_memory_limit_service_bytes=$((_linux_memory_limit_bytes + 67108864))
        [ "$_linux_memory_limit_service_bytes" -gt "$_linux_memory_limit_bytes" ] || {
            echo "Linux memory limiting cannot reserve sampler headroom" >&2
            return 2
        }
        set -- --property=Delegate=memory --property=DelegateSubgroup=sampler "$@"
    fi
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
            --property="MemoryMax=$_linux_memory_limit_service_bytes" \
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
    _linux_memory_limit_systemd_stderr=$(mktemp \
        "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE.systemd-stderr.XXXXXX") || {
        echo "Linux memory limiting failed to create invocation stderr evidence" >&2
        return 2
    }
    # OOMPolicy=kill sets memory.oom.group, so a cgroup OOM kill takes the
    # in-cgroup sampler along with the workload, and systemd's summary can lack
    # the final peak once the cgroup is gone. ExecStopPost runs inside the
    # unit's cgroup after the kill and before systemd removes it, so it records
    # the cgroup's exact memory.peak and memory.events oom_kill count. The
    # count also catches an OOM kill whose unit systemd finished with
    # `result: signal`, because it handled the main process's exit before the
    # OOM notification. The ':' prefix keeps systemd from expanding the
    # script's variables.
    _linux_memory_limit_cgroup_peak=$(mktemp \
        "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE.cgroup-peak.XXXXXX") || {
        rm -f "$_linux_memory_limit_systemd_stderr"
        echo "Linux memory limiting failed to create cgroup peak evidence" >&2
        return 2
    }
    # The hook writes labelled lines, and its own errors, so an OOM report can
    # show what it saw: `ran`, `cgroup PATH`, `kills N` and `peak N`.
    _linux_memory_limit_record_peak='{ echo ran; while read -r line; do case $line in 0::*) cgroup="/sys/fs/cgroup${line#0::}"; case $cgroup in */.control) cgroup=${cgroup%/.control}; [ ! -d "$cgroup/workload" ] || cgroup="$cgroup/workload" ;; esac; echo "cgroup $cgroup"; kills=0; while read -r key value; do if [ "$key" = oom_kill ]; then kills=$value; fi; done < "$cgroup/memory.events"; echo "kills $kills"; read -r peak < "$cgroup/memory.peak" && echo "peak $peak" ;; esac; done < /proc/self/cgroup; } > "$TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE" 2>&1 || true'
    _linux_memory_limit_status=0
    TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE=$_linux_memory_limit_cgroup_peak \
        LC_ALL=C SYSTEMD_COLORS=0 systemd-run \
        --user \
        --wait \
        --pipe \
        --collect \
        --same-dir \
        --service-type=exec \
        --property=MemoryAccounting=yes \
        --property="MemoryMax=$_linux_memory_limit_service_bytes" \
        --property=MemorySwapMax=0 \
        --property="OOMPolicy=${_linux_memory_limit_oom_policy:-kill}" \
        --setenv=TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE \
        "--property=ExecStopPost=:/bin/sh -c '$_linux_memory_limit_record_peak'" \
        "$@" 2> "$_linux_memory_limit_systemd_stderr" ||
        _linux_memory_limit_status=$?
    cat "$_linux_memory_limit_systemd_stderr" >&2
    _linux_memory_limit_cgroup_bytes=0
    _linux_memory_limit_cgroup_kills=0
    if [ -s "$_linux_memory_limit_cgroup_peak" ]; then
        while read -r _linux_memory_limit_hook_key _linux_memory_limit_hook_value; do
            case "$_linux_memory_limit_hook_key" in
                peak) _linux_memory_limit_cgroup_bytes=$_linux_memory_limit_hook_value ;;
                kills) _linux_memory_limit_cgroup_kills=$_linux_memory_limit_hook_value ;;
            esac
        done < "$_linux_memory_limit_cgroup_peak"
    fi
    case "$_linux_memory_limit_cgroup_bytes" in
        "" | *[!0-9]*) _linux_memory_limit_cgroup_bytes=0 ;;
    esac
    case "$_linux_memory_limit_cgroup_kills" in
        "" | *[!0-9]*) _linux_memory_limit_cgroup_kills=0 ;;
    esac
    _linux_memory_limit_oom=0
    if [ "$_linux_memory_limit_cgroup_kills" -gt 0 ] ||
        grep -Eq 'result: oom-kill|result .oom-kill.' \
            "$_linux_memory_limit_systemd_stderr"; then
        _linux_memory_limit_oom=1
    fi
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
    _linux_memory_limit_summary_bytes=$_linux_memory_limit_peak_bytes
    if [ "$_linux_memory_limit_sampled_bytes" -gt "$_linux_memory_limit_peak_bytes" ]; then
        _linux_memory_limit_peak_bytes=$_linux_memory_limit_sampled_bytes
    fi
    # After an OOM kill the recorded cgroup peak is the evidence the killed
    # sampler could not write. Name every source, so a short OOM peak shows
    # which one fell short.
    if [ "$_linux_memory_limit_oom" -eq 1 ]; then
        if [ "$_linux_memory_limit_cgroup_bytes" -gt "$_linux_memory_limit_peak_bytes" ]; then
            _linux_memory_limit_peak_bytes=$_linux_memory_limit_cgroup_bytes
        fi
        echo "[memory-limit] OOM peak sources: cgroup memory.peak $_linux_memory_limit_cgroup_bytes (oom_kill $_linux_memory_limit_cgroup_kills), systemd summary $_linux_memory_limit_summary_bytes, sampler $_linux_memory_limit_sampled_bytes; stop-post hook: $(tr '\n' ' ' < "$_linux_memory_limit_cgroup_peak")" >&2
    fi
    if [ "${_linux_memory_limit_sampled:-0}" -eq 1 ] &&
        [ "$_linux_memory_limit_status" -eq 2 ] &&
        [ "$_linux_memory_limit_sampled_bytes" -eq 0 ] &&
        [ "$_linux_memory_limit_oom" -eq 0 ]; then
        # A failed sampler setup must not turn the launcher's own memory into
        # evidence that the requested workload ran under an established cap.
        _linux_memory_limit_peak_bytes=0
    fi
    rm -f "$_linux_memory_limit_systemd_stderr" "$_linux_memory_limit_cgroup_peak"
    printf '%s\n' "$_linux_memory_limit_peak_bytes" \
        > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
    if [ "$_linux_memory_limit_oom" -eq 1 ]; then
        return 137
    fi
    return "$_linux_memory_limit_status"
}

linux_memory_limit_select_backend() {
    if [ -n "$LINUX_MEMORY_LIMIT_BACKEND" ]; then
        return 0
    fi
    if ! linux_memory_limit_systemd_available; then
        echo "Linux memory limiting requires a usable user systemd manager (systemd-run --user with MemoryMax)" >&2
        return 1
    fi
    LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup
}

# The cgroup v2 directory of the calling process, in
# _linux_memory_limit_cgroup. Shell builtins only, like the two readers below:
# they run in a cgroup where the kernel may just have OOM-killed a task.
linux_memory_limit_own_cgroup() {
    _linux_memory_limit_cgroup=
    while read -r _linux_memory_limit_line; do
        case $_linux_memory_limit_line in
            0::*) _linux_memory_limit_cgroup="/sys/fs/cgroup${_linux_memory_limit_line#0::}" ;;
        esac
    done < /proc/self/cgroup
    [ -n "$_linux_memory_limit_cgroup" ]
}

# The oom_kill count of cgroup $1, in _linux_memory_limit_oom_kills.
linux_memory_limit_read_oom_kills() {
    _linux_memory_limit_oom_kills=
    [ -r "$1/memory.events" ] || return 1
    while read -r _linux_memory_limit_key _linux_memory_limit_value; do
        if [ "$_linux_memory_limit_key" = oom_kill ]; then
            _linux_memory_limit_oom_kills=$_linux_memory_limit_value
        fi
    done < "$1/memory.events"
    [ -n "$_linux_memory_limit_oom_kills" ]
}

# The larger of the sampled peak and cgroup $1's memory.peak, in bytes, into
# the metrics file, after an OOM kill in that cgroup.
linux_memory_limit_record_oom_peak() {
    _linux_memory_limit_cgroup_peak_bytes=0
    if [ -r "$1/memory.peak" ]; then
        read -r _linux_memory_limit_cgroup_peak_bytes < "$1/memory.peak" ||
            _linux_memory_limit_cgroup_peak_bytes=0
    fi
    case "$_linux_memory_limit_cgroup_peak_bytes" in
        "" | *[!0-9]*) _linux_memory_limit_cgroup_peak_bytes=0 ;;
    esac
    _linux_memory_limit_oom_peak_bytes=$((_linux_memory_limit_peak_rss * 1024))
    if [ "$_linux_memory_limit_cgroup_peak_bytes" -gt "$_linux_memory_limit_oom_peak_bytes" ]; then
        _linux_memory_limit_oom_peak_bytes=$_linux_memory_limit_cgroup_peak_bytes
    fi
    if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
        printf '%s\n' "$_linux_memory_limit_oom_peak_bytes" \
            > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
    fi
}

linux_memory_limit_process_group_rss_kib() {
    _linux_memory_limit_group=$1
    ps -e -o pid= -o pgid= -o rss= | awk \
        -v group="$_linux_memory_limit_group" '
            $2 == group { total += $3 }
            END { print total + 0 }
        '
}

linux_memory_limit_sample_process_group() {
    _linux_memory_limit_bytes=$1
    shift
    _linux_memory_limit_kib=$(((_linux_memory_limit_bytes + 1023) / 1024))
    _linux_memory_limit_poll=${TYPELISP_LINUX_MEMORY_LIMIT_POLL_SECONDS:-0.05}
    _linux_memory_limit_peak_rss=0

    # Domain controllers require an empty inner node. systemd places the
    # sampler (and timeout) in its own leaf before this code starts, so enabling
    # memory and capping its workload sibling never exposes user code unbounded.
    linux_memory_limit_own_cgroup || {
        echo "process-group sampler requires delegated cgroup v2 memory" >&2
        return 2
    }
    case $_linux_memory_limit_cgroup in
        */sampler) _linux_memory_limit_parent=${_linux_memory_limit_cgroup%/sampler} ;;
        *)
            echo "process-group sampler requires systemd DelegateSubgroup=sampler" >&2
            return 2
            ;;
    esac
    _linux_memory_limit_workload="$_linux_memory_limit_parent/workload"
    if ! {
        printf '+memory\n' > "$_linux_memory_limit_parent/cgroup.subtree_control" &&
        printf '67108864\n' > "$_linux_memory_limit_cgroup/memory.max" &&
        mkdir "$_linux_memory_limit_workload" &&
        printf '%s\n' "$_linux_memory_limit_bytes" > "$_linux_memory_limit_workload/memory.max" &&
        printf '0\n' > "$_linux_memory_limit_workload/memory.swap.max" &&
        printf '1\n' > "$_linux_memory_limit_workload/memory.oom.group" &&
        [ -w "$_linux_memory_limit_workload/cgroup.kill" ]
    }; then
        echo "process-group sampler requires writable delegated cgroup v2 memory and cgroup.kill" >&2
        return 2
    fi
    _linux_memory_limit_cgroup=$_linux_memory_limit_workload
    linux_memory_limit_read_oom_kills "$_linux_memory_limit_cgroup" || {
        echo "process-group sampler cannot read its cgroup's memory.events" >&2
        return 1
    }
    _linux_memory_limit_oom_kills_before=$_linux_memory_limit_oom_kills

    # Keep the requested command behind a filesystem gate. The waiting shell
    # gives the parent time to verify the new process group and take a positive
    # RSS sample before any user code can execute, including commands which
    # would otherwise finish between fork and the first sample.
    _linux_memory_limit_gate_dir=$(mktemp -d \
        "${TMPDIR:-/tmp}/typelisp-memory-sampler.XXXXXX") || {
        echo "process-group sampler failed to create launch gate" >&2
        return 1
    }
    _linux_memory_limit_gate="$_linux_memory_limit_gate_dir/start"
    setsid sh -c '
        gate=$1
        cgroup=$2
        shift 2
        printf "%s\n" "$$" > "$cgroup/cgroup.procs" || {
            echo "process-group sampler failed to place workload in delegated cgroup" >&2
            exit 2
        }
        while [ ! -e "$gate" ]; do sleep 0.01; done
        unset TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
        exec "$@"
    ' sh "$_linux_memory_limit_gate" "$_linux_memory_limit_cgroup" "$@" &
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
        echo "process-group sampler failed to isolate command process group" >&2
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
                echo "process-group sampler failed to read initial process memory" >&2
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
        echo "process-group sampler failed to establish initial memory measurement" >&2
        return 1
    fi
    _linux_memory_limit_peak_rss=$_linux_memory_limit_rss
    if [ "$_linux_memory_limit_rss" -gt "$_linux_memory_limit_kib" ]; then
        echo "memory limit exceeded before command launch: aggregate RSS ${_linux_memory_limit_rss} KiB > ${_linux_memory_limit_kib} KiB (process-group sampler)" >&2
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
    _linux_memory_limit_rss_excess_pending=0

    while :; do
        if linux_memory_limit_read_oom_kills "$_linux_memory_limit_cgroup" &&
            [ "$_linux_memory_limit_oom_kills" -gt "$_linux_memory_limit_oom_kills_before" ]; then
            printf '1\n' > "$_linux_memory_limit_cgroup/cgroup.kill"
            wait "$_linux_memory_limit_pid" 2>/dev/null || true
            rm -f "$_linux_memory_limit_gate"
            rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
            linux_memory_limit_record_oom_peak "$_linux_memory_limit_cgroup"
            return 137
        fi
        _linux_memory_limit_rss=$(linux_memory_limit_process_group_rss_kib \
            "$_linux_memory_limit_pid") || {
                kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
                wait "$_linux_memory_limit_pid" 2>/dev/null || true
                rm -f "$_linux_memory_limit_gate"
                rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
                echo "process-group sampler failed to read process memory" >&2
                return 1
            }
        if [ "$_linux_memory_limit_rss" -eq 0 ]; then
            break
        fi
        if [ "$_linux_memory_limit_rss" -gt "$_linux_memory_limit_peak_rss" ]; then
            _linux_memory_limit_peak_rss=$_linux_memory_limit_rss
        fi
        if [ "$_linux_memory_limit_rss" -gt "$_linux_memory_limit_kib" ]; then
            # The exact workload cgroup cap remains active while one bounded
            # resample lets its OOM state catch up with RSS collection. A
            # sustained RSS-only excess still takes the termination path.
            if [ "$_linux_memory_limit_rss_excess_pending" -eq 0 ]; then
                _linux_memory_limit_rss_excess_pending=1
                sleep 0.05
                continue
            fi
            echo "memory limit exceeded: aggregate RSS ${_linux_memory_limit_rss} KiB > ${_linux_memory_limit_kib} KiB (process-group sampler)" >&2
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
        _linux_memory_limit_rss_excess_pending=0
        sleep "$_linux_memory_limit_poll"
    done

    if wait "$_linux_memory_limit_pid"; then
        _linux_memory_limit_status=0
    else
        _linux_memory_limit_status=$?
    fi
    rm -f "$_linux_memory_limit_gate"
    rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
    # The group can empty between two polls because of an OOM kill.
    if linux_memory_limit_read_oom_kills "$_linux_memory_limit_cgroup" &&
        [ "$_linux_memory_limit_oom_kills" -gt "$_linux_memory_limit_oom_kills_before" ]; then
        printf '1\n' > "$_linux_memory_limit_cgroup/cgroup.kill"
        linux_memory_limit_record_oom_peak "$_linux_memory_limit_cgroup"
        return 137
    fi
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

    linux_memory_limit_run_systemd "$_linux_memory_limit_bytes" "$@"
}

# linux_memory_limit_run for a command that runs
# linux_memory_limit_sample_process_group (run-memory-bounded.sh
# --linux-rss-measure). Delegation isolates the capped workload from the
# sampler. OOMPolicy=continue keeps systemd from terminating the sampler when
# the workload child OOMs; the sampler records that child's peak and kills it.
linux_memory_limit_run_sampled() {
    _linux_memory_limit_sampled=1
    _linux_memory_limit_oom_policy=continue
    _linux_memory_limit_sampled_status=0
    linux_memory_limit_run "$@" || _linux_memory_limit_sampled_status=$?
    _linux_memory_limit_oom_policy=
    _linux_memory_limit_sampled=0
    return "$_linux_memory_limit_sampled_status"
}
