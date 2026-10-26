#!/usr/bin/env sh

# Linux resident-memory limits for compiler gates and probes.
#
# The only enforcement backend is cgroup v2 memory under the user systemd
# manager: memory.max is a kernel-enforced limit over the complete process tree
# and swap is disabled so the result stays resident. A host without a usable
# user manager that delegates memory fails closed; nothing falls back to an
# unbounded run.
#
# Invocation hierarchy (#7793). A top-level invocation is a transient service
# with its memory controller delegated to it (Delegate=memory and
# DelegateSubgroup=, systemd 254 or newer). Its workload runs in the leaf
# `workload/tlmem-run` of the unit's cgroup; `workload` carries the requested
# memory.max with memory.swap.max=0 and memory.oom.group=1. A call made from a
# `tlmem-run` leaf is nested. It starts no unit, because the user manager would
# place one beside the outer unit and outside its cap. Instead it creates its
# own node `tlmem-<pid>-<n>` beside that leaf, runs its command there under its
# own limits, and removes the node afterwards. Every enclosing workload node
# therefore charges, caps and measures all of its nested calls, concurrent ones
# included. Inner limits still apply, the outer cap bounds their aggregate, and
# memory.peak is a measured peak of the whole subtree. An outer OOM, timeout or
# unit stop terminates the nested work along with the outer workload. Units use
# OOMPolicy=continue because systemd counts an inner node's OOM kill as one of
# its own; memory.oom.group on each workload node still makes an OOM at that
# node's limit fatal to its whole subtree.
#
# The caller's own cgroup from /proc/self/cgroup is the authority, and a
# workload cannot lose it by clearing its environment. Every workload inherits
# TYPELISP_LINUX_MEMORY_LIMIT_NODE, which serves only to detect a lost
# hierarchy: a caller that inherited it but is not in a `tlmem-run` leaf fails
# closed instead of starting a unit outside the cap.
#
# linux_memory_limit_sample_process_group runs beside a capped workload node
# in a delegated cgroup (see run-memory-bounded.sh). It launches the command
# in a new process group and
# samples the group's aggregate RSS from `ps` to report a trustworthy peak,
# terminating the group if observed RSS crosses the same ceiling. A launch gate
# keeps user code suspended until process-group isolation and the first
# successful memory sample are established. It never caps virtual address
# space, which avoids the mmap-reservation failures RLIMIT_AS causes. Under
# linux_memory_limit_run_sampled a workload OOM cannot select the sampler or
# its helpers, which record the workload node's exact peak before exiting.

LINUX_MEMORY_LIMIT_BACKEND=${LINUX_MEMORY_LIMIT_BACKEND:-}
_linux_memory_limit_sampled=0
_linux_memory_limit_node_count=0

# Configure the new, empty cgroup $1 as a workload node: memory.max $2, no
# swap, memory.oom.group $3, the memory controller for its children, and its
# first leaf $4. A top-level unit's launch program runs it too.
_linux_memory_limit_node_program='echo "$2" > "$1/memory.max" &&
    echo 0 > "$1/memory.swap.max" &&
    echo "$3" > "$1/memory.oom.group" &&
    echo +memory > "$1/cgroup.subtree_control" &&
    mkdir "$1/$4"'

# The main process of a top-level direct unit, started in its
# DelegateSubgroup=launch leaf: build the workload node, move into its
# tlmem-run leaf and exec the command. Arguments: the node program, the limit
# in bytes, then the command. Nothing has run if it exits 2 with a diagnostic.
_linux_memory_limit_launch_program='cgroup=
while read -r line; do
    case $line in 0::*) cgroup="/sys/fs/cgroup${line#0::}" ;; esac
done < /proc/self/cgroup
case $cgroup in
    */launch) unit=${cgroup%/launch} ;;
    *)
        echo "Linux memory limiting requires systemd DelegateSubgroup=launch" >&2
        exit 2
        ;;
esac
if ! { echo +memory > "$unit/cgroup.subtree_control" &&
    mkdir "$unit/workload" &&
    sh -c "$1" sh "$unit/workload" "$2" 1 tlmem-run &&
    echo "$$" > "$unit/workload/tlmem-run/cgroup.procs"; }; then
    echo "Linux memory limiting failed to establish its workload cgroup in $unit" >&2
    exit 2
fi
TYPELISP_LINUX_MEMORY_LIMIT_NODE=$unit/workload
export TYPELISP_LINUX_MEMORY_LIMIT_NODE
shift 2
exec "$@"'

# Move into leaf $1 of a nested node and exec the command, exporting node $2
# as the workload node unless it is empty. Nothing has run if it exits 2 with a
# diagnostic.
_linux_memory_limit_enter_program='echo "$$" > "$1/cgroup.procs" || {
    echo "Linux memory limiting failed to enter its nested cgroup $1" >&2
    exit 2
}
if [ -n "$2" ]; then
    TYPELISP_LINUX_MEMORY_LIMIT_NODE=$2
    export TYPELISP_LINUX_MEMORY_LIMIT_NODE
fi
shift 2
exec "$@"'

linux_memory_limit_validate_bytes() {
    case "$1" in
        "" | *[!0-9]* | 0)
            echo "Linux memory limit must be a positive byte count: $1" >&2
            return 2
            ;;
    esac
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

# The workload node that encloses a nested caller, in _linux_memory_limit_node:
# the parent of the caller's tlmem-run leaf, or empty at top level. Fails
# closed when an inherited TYPELISP_LINUX_MEMORY_LIMIT_NODE shows the caller
# belongs to a bounded workload whose leaf its cgroup no longer is.
linux_memory_limit_enclosing_node() {
    _linux_memory_limit_node=
    if linux_memory_limit_own_cgroup; then
        case $_linux_memory_limit_cgroup in
            */tlmem-run)
                _linux_memory_limit_node=${_linux_memory_limit_cgroup%/tlmem-run}
                return 0
                ;;
        esac
    fi
    [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_NODE:-}" ] || return 0
    echo "Linux memory limiting cannot nest inside bounded workload $TYPELISP_LINUX_MEMORY_LIMIT_NODE: this process runs in ${_linux_memory_limit_cgroup:-an unknown cgroup}, not in its tlmem-run leaf, and starting a separate unit would escape that cap" >&2
    return 2
}

linux_memory_limit_systemd_available() {
    linux_memory_limit_enclosing_node || return 1
    if [ -n "$_linux_memory_limit_node" ]; then
        # A nested call starts no unit. It needs an enclosing node that
        # gives its children the memory controller.
        [ -w "$_linux_memory_limit_node/cgroup.procs" ] || return 1
        read -r _linux_memory_limit_controllers \
            < "$_linux_memory_limit_node/cgroup.subtree_control" || return 1
        case " $_linux_memory_limit_controllers " in
            *" memory "*) return 0 ;;
        esac
        return 1
    fi
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
        --expand-environment=no \
        --property=MemoryAccounting=yes \
        --property=MemoryMax=67108864 \
        --property=MemorySwapMax=0 \
        --property=OOMPolicy=continue \
        --property=Delegate=memory \
        --property=DelegateSubgroup=launch \
        -- sh -c "$_linux_memory_limit_launch_program" sh \
        "$_linux_memory_limit_node_program" 67108864 true >/dev/null 2>&1
}

# The memory.peak of cgroup $1 in _linux_memory_limit_peak_read, or 0.
linux_memory_limit_read_peak() {
    _linux_memory_limit_peak_read=0
    if [ -r "$1/memory.peak" ]; then
        read -r _linux_memory_limit_peak_read < "$1/memory.peak" ||
            _linux_memory_limit_peak_read=0
    fi
    case "$_linux_memory_limit_peak_read" in
        "" | *[!0-9]*) _linux_memory_limit_peak_read=0 ;;
    esac
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

# Report an invocation's result: write its peak to the metrics file, if any,
# and return its status, or 137 after an OOM kill of its own processes.
# Arguments: status, OOM (0 or 1), the unit's or node's summary peak and its
# label, the workload node's memory.peak and oom_kill count, and the raw
# evidence that produced them.
linux_memory_limit_finish() {
    _linux_memory_limit_finish_status=$1
    _linux_memory_limit_oom=$2
    _linux_memory_limit_summary_bytes=$3
    _linux_memory_limit_summary_label=$4
    _linux_memory_limit_cgroup_bytes=$5
    _linux_memory_limit_cgroup_kills=$6
    _linux_memory_limit_evidence=$7
    case "$_linux_memory_limit_summary_bytes" in
        "" | *[!0-9]*) _linux_memory_limit_summary_bytes=0 ;;
    esac
    case "$_linux_memory_limit_cgroup_bytes" in
        "" | *[!0-9]*) _linux_memory_limit_cgroup_bytes=0 ;;
    esac
    case "$_linux_memory_limit_cgroup_kills" in
        "" | *[!0-9]*) _linux_memory_limit_cgroup_kills=0 ;;
    esac
    if [ "$_linux_memory_limit_cgroup_kills" -gt 0 ]; then
        _linux_memory_limit_oom=1
    fi
    _linux_memory_limit_sampled_bytes=0
    if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ] &&
        [ -s "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE" ]; then
        _linux_memory_limit_sampled_bytes=$(sed -n '1p' \
            "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE")
        case "$_linux_memory_limit_sampled_bytes" in
            "" | *[!0-9]*) _linux_memory_limit_sampled_bytes=0 ;;
        esac
    fi
    _linux_memory_limit_peak_bytes=$_linux_memory_limit_summary_bytes
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
        echo "[memory-limit] OOM peak sources: cgroup memory.peak $_linux_memory_limit_cgroup_bytes (oom_kill $_linux_memory_limit_cgroup_kills), $_linux_memory_limit_summary_label $_linux_memory_limit_summary_bytes, sampler $_linux_memory_limit_sampled_bytes; $_linux_memory_limit_evidence" >&2
    fi
    if [ "$_linux_memory_limit_sampled" -eq 1 ] &&
        [ "$_linux_memory_limit_finish_status" -eq 2 ] &&
        [ "$_linux_memory_limit_sampled_bytes" -eq 0 ] &&
        [ "$_linux_memory_limit_oom" -eq 0 ]; then
        # A failed sampler setup must not turn the launcher's own memory into
        # evidence that the requested workload ran under an established cap.
        _linux_memory_limit_peak_bytes=0
    fi
    if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
        printf '%s\n' "$_linux_memory_limit_peak_bytes" \
            > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
    fi
    if [ "$_linux_memory_limit_oom" -eq 1 ]; then
        return 137
    fi
    return "$_linux_memory_limit_finish_status"
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
    if [ "$_linux_memory_limit_sampled" -eq 1 ]; then
        # The workload keeps its exact requested ceiling. The separate sampler
        # leaf has bounded headroom outside the workload's OOM domain.
        _linux_memory_limit_service_bytes=$((_linux_memory_limit_bytes + 67108864))
        [ "$_linux_memory_limit_service_bytes" -gt "$_linux_memory_limit_bytes" ] || {
            echo "Linux memory limiting cannot reserve sampler headroom" >&2
            return 2
        }
        _linux_memory_limit_subgroup=sampler
    else
        set -- sh -c "$_linux_memory_limit_launch_program" sh \
            "$_linux_memory_limit_node_program" "$_linux_memory_limit_bytes" "$@"
        _linux_memory_limit_subgroup=launch
    fi

    # Transient user services inherit the user manager's environment, not the
    # invoking gate's exports. Prepend one --setenv=name option per valid
    # environment name; omitting `=value` asks systemd-run to copy the exact
    # value from its own process environment without shell re-quoting it.
    # --expand-environment=no passes the command's arguments through as
    # given, exactly as a nested call runs them.
    set -- --expand-environment=no \
        --property=Delegate=memory \
        "--property=DelegateSubgroup=$_linux_memory_limit_subgroup" -- "$@"
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
            --property=OOMPolicy=continue \
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
    # An OOM kill at the workload node's limit takes the whole node, and with
    # it the sampler's view, and systemd's summary can lack the final peak
    # once the cgroup is gone. ExecStopPost runs in the unit's `.control`
    # subgroup after the kill and before systemd removes the cgroup, so it
    # records the workload node's exact memory.peak and the oom_kill count of
    # its own tlmem-run leaf. The leaf's count also catches an OOM kill that
    # ended the main process before systemd saw an OOM event, and it ignores a
    # nested node's own OOM, which the hierarchical count of `workload`
    # includes. The ':' prefix keeps systemd from expanding the script's
    # variables.
    _linux_memory_limit_cgroup_peak=$(mktemp \
        "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE.cgroup-peak.XXXXXX") || {
        rm -f "$_linux_memory_limit_systemd_stderr"
        echo "Linux memory limiting failed to create cgroup peak evidence" >&2
        return 2
    }
    # The hook writes labelled lines, and its own errors, so an OOM report can
    # show what it saw: `ran`, `cgroup PATH`, `kills N` and `peak N`.
    _linux_memory_limit_record_peak='{ echo ran; while read -r line; do case $line in 0::*) cgroup="/sys/fs/cgroup${line#0::}"; cgroup="${cgroup%/.control}/workload"; echo "cgroup $cgroup"; kills=0; while read -r key value; do if [ "$key" = oom_kill ]; then kills=$value; fi; done < "$cgroup/tlmem-run/memory.events"; echo "kills $kills"; read -r peak < "$cgroup/memory.peak" && echo "peak $peak" ;; esac; done < /proc/self/cgroup; } > "$TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE" 2>&1 || true'
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
        --property=OOMPolicy=continue \
        --setenv=TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE \
        "--property=ExecStopPost=:/bin/sh -c '$_linux_memory_limit_record_peak'" \
        "$@" 2> "$_linux_memory_limit_systemd_stderr" ||
        _linux_memory_limit_status=$?
    cat "$_linux_memory_limit_systemd_stderr" >&2
    _linux_memory_limit_hook_bytes=0
    _linux_memory_limit_hook_kills=0
    if [ -s "$_linux_memory_limit_cgroup_peak" ]; then
        while read -r _linux_memory_limit_hook_key _linux_memory_limit_hook_value; do
            case "$_linux_memory_limit_hook_key" in
                peak) _linux_memory_limit_hook_bytes=$_linux_memory_limit_hook_value ;;
                kills) _linux_memory_limit_hook_kills=$_linux_memory_limit_hook_value ;;
            esac
        done < "$_linux_memory_limit_cgroup_peak"
    fi
    _linux_memory_limit_systemd_oom=0
    if grep -Eq 'result: oom-kill|result .oom-kill.' \
        "$_linux_memory_limit_systemd_stderr"; then
        _linux_memory_limit_systemd_oom=1
    fi
    _linux_memory_limit_summary=$(awk '
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
    _linux_memory_limit_hook_text="stop-post hook: $(tr '\n' ' ' < "$_linux_memory_limit_cgroup_peak")"
    rm -f "$_linux_memory_limit_systemd_stderr" "$_linux_memory_limit_cgroup_peak"
    linux_memory_limit_finish "$_linux_memory_limit_status" \
        "$_linux_memory_limit_systemd_oom" \
        "$_linux_memory_limit_summary" "systemd summary" \
        "$_linux_memory_limit_hook_bytes" "$_linux_memory_limit_hook_kills" \
        "$_linux_memory_limit_hook_text"
}

# Kill everything left in nested node $1, which this invocation created, wait
# until it is empty and remove it with every cgroup below it.
linux_memory_limit_release_node() {
    case "${1:?}" in
        /sys/fs/cgroup/*/tlmem-[0-9]*-[0-9]*) ;;
        *)
            echo "Linux memory limiting refused to release a cgroup it does not own: $1" >&2
            return 1
            ;;
    esac
    [ -d "$1" ] || return 0
    printf '1\n' > "$1/cgroup.kill" 2>/dev/null || true
    _linux_memory_limit_release_attempt=0
    while :; do
        _linux_memory_limit_populated=1
        if [ -r "$1/cgroup.events" ]; then
            while read -r _linux_memory_limit_key _linux_memory_limit_value; do
                if [ "$_linux_memory_limit_key" = populated ]; then
                    _linux_memory_limit_populated=$_linux_memory_limit_value
                fi
            done < "$1/cgroup.events"
        fi
        [ "$_linux_memory_limit_populated" != 0 ] || break
        [ "$_linux_memory_limit_release_attempt" -lt 200 ] || break
        _linux_memory_limit_release_attempt=$((_linux_memory_limit_release_attempt + 1))
        sleep 0.05
    done
    find "$1" -depth -type d -exec rmdir -- {} + 2>/dev/null || {
        echo "Linux memory limiting could not remove nested cgroup $1; its enclosing workload's teardown removes it" >&2
        return 1
    }
}

# A nested call: run the command in a new node beside the caller's tlmem-run
# leaf, inside workload node $_linux_memory_limit_node. The caller waits for
# it like any child process, so its streams, environment, working directory
# and status pass through unchanged.
linux_memory_limit_run_nested() {
    _linux_memory_limit_bytes=$1
    shift
    _linux_memory_limit_node_bytes=$_linux_memory_limit_bytes
    _linux_memory_limit_node_oom_group=1
    _linux_memory_limit_node_leaf=tlmem-run
    if [ "$_linux_memory_limit_sampled" -eq 1 ]; then
        # The sampled shape of a top-level unit: a sampler leaf with bounded
        # headroom beside the workload node the sampler creates.
        _linux_memory_limit_node_bytes=$((_linux_memory_limit_bytes + 67108864))
        [ "$_linux_memory_limit_node_bytes" -gt "$_linux_memory_limit_bytes" ] || {
            echo "Linux memory limiting cannot reserve sampler headroom" >&2
            return 2
        }
        _linux_memory_limit_node_oom_group=0
        _linux_memory_limit_node_leaf=sampler
    fi
    # printf, not the special builtin `:`, whose redirection error would end
    # a POSIX shell instead of failing this call closed.
    if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ] &&
        ! printf '' 2>/dev/null > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"; then
        echo "Linux memory limiting failed to create invocation peak evidence: $TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE" >&2
        return 2
    fi

    # The caller's own process ID keeps concurrent callers apart, including
    # subshells that share $$; the count separates its successive calls.
    _linux_memory_limit_owner_pid=$(exec sh -c 'echo "$PPID"')
    _linux_memory_limit_attempt=0
    while :; do
        _linux_memory_limit_node_count=$((_linux_memory_limit_node_count + 1))
        _linux_memory_limit_nested="$_linux_memory_limit_node/tlmem-$_linux_memory_limit_owner_pid-$_linux_memory_limit_node_count"
        if mkdir "$_linux_memory_limit_nested" 2>/dev/null; then
            break
        fi
        _linux_memory_limit_attempt=$((_linux_memory_limit_attempt + 1))
        if [ ! -d "$_linux_memory_limit_nested" ] ||
            [ "$_linux_memory_limit_attempt" -ge 64 ]; then
            echo "Linux memory limiting failed to create a nested cgroup in $_linux_memory_limit_node" >&2
            return 2
        fi
    done
    if ! sh -c "$_linux_memory_limit_node_program" sh "$_linux_memory_limit_nested" \
        "$_linux_memory_limit_node_bytes" "$_linux_memory_limit_node_oom_group" \
        "$_linux_memory_limit_node_leaf"; then
        echo "Linux memory limiting failed to configure nested cgroup $_linux_memory_limit_nested" >&2
        linux_memory_limit_release_node "$_linux_memory_limit_nested" || true
        return 2
    fi

    _linux_memory_limit_workload=$_linux_memory_limit_nested
    _linux_memory_limit_node_env=$_linux_memory_limit_nested
    if [ "$_linux_memory_limit_sampled" -eq 1 ]; then
        _linux_memory_limit_workload="$_linux_memory_limit_nested/workload"
        _linux_memory_limit_node_env=
    fi
    _linux_memory_limit_status=0
    sh -c "$_linux_memory_limit_enter_program" sh \
        "$_linux_memory_limit_nested/$_linux_memory_limit_node_leaf" \
        "$_linux_memory_limit_node_env" \
        env -u TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE \
        -u TYPELISP_LINUX_MEMORY_LIMIT_CGROUP_PEAK_FILE "$@" ||
        _linux_memory_limit_status=$?

    linux_memory_limit_read_oom_kills "$_linux_memory_limit_workload/tlmem-run" ||
        _linux_memory_limit_oom_kills=0
    linux_memory_limit_read_peak "$_linux_memory_limit_workload"
    _linux_memory_limit_workload_peak=$_linux_memory_limit_peak_read
    linux_memory_limit_read_peak "$_linux_memory_limit_nested"
    _linux_memory_limit_nested_peak=$_linux_memory_limit_peak_read
    linux_memory_limit_release_node "$_linux_memory_limit_nested" || true
    linux_memory_limit_finish "$_linux_memory_limit_status" 0 \
        "$_linux_memory_limit_nested_peak" "node memory.peak" \
        "$_linux_memory_limit_workload_peak" "$_linux_memory_limit_oom_kills" \
        "nested node: $_linux_memory_limit_nested"
}

linux_memory_limit_select_backend() {
    if [ -n "$LINUX_MEMORY_LIMIT_BACKEND" ]; then
        return 0
    fi
    if ! linux_memory_limit_systemd_available; then
        echo "Linux memory limiting requires a usable user systemd manager (systemd-run --user with MemoryMax and delegated memory, systemd 254 or newer) or an enclosing bounded workload" >&2
        return 1
    fi
    LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup
}

# The larger of the sampled peak and cgroup $1's memory.peak, in bytes, into
# the metrics file, after an OOM kill in that cgroup.
linux_memory_limit_record_oom_peak() {
    linux_memory_limit_read_peak "$1"
    _linux_memory_limit_oom_peak_bytes=$((_linux_memory_limit_peak_rss * 1024))
    if [ "$_linux_memory_limit_peak_read" -gt "$_linux_memory_limit_oom_peak_bytes" ]; then
        _linux_memory_limit_oom_peak_bytes=$_linux_memory_limit_peak_read
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

    # Domain controllers require an empty inner node. The sampler (and
    # timeout) start in their own leaf, placed there by systemd or by a
    # nested call before this code runs, so enabling memory and capping the
    # workload node beside it never exposes user code unbounded.
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
    # The workload node holds the requested command's leaf and every nested
    # call it makes. The sampler watches the leaf's own OOM kills: an OOM at
    # the node's limit kills the whole node, leaf included, while a nested
    # call's OOM at its own limit leaves the leaf running.
    _linux_memory_limit_workload="$_linux_memory_limit_parent/workload"
    _linux_memory_limit_leaf="$_linux_memory_limit_workload/tlmem-run"
    if ! {
        printf '+memory\n' > "$_linux_memory_limit_parent/cgroup.subtree_control" &&
        printf '67108864\n' > "$_linux_memory_limit_cgroup/memory.max" &&
        mkdir "$_linux_memory_limit_workload" &&
        sh -c "$_linux_memory_limit_node_program" sh "$_linux_memory_limit_workload" \
            "$_linux_memory_limit_bytes" 1 tlmem-run &&
        [ -w "$_linux_memory_limit_workload/cgroup.kill" ]
    }; then
        echo "process-group sampler requires writable delegated cgroup v2 memory and cgroup.kill" >&2
        return 2
    fi
    linux_memory_limit_read_oom_kills "$_linux_memory_limit_leaf" || {
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
        leaf=$2
        node=$3
        shift 3
        printf "%s\n" "$$" > "$leaf/cgroup.procs" || {
            echo "process-group sampler failed to place workload in delegated cgroup" >&2
            exit 2
        }
        while [ ! -e "$gate" ]; do sleep 0.01; done
        unset TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
        TYPELISP_LINUX_MEMORY_LIMIT_NODE=$node
        export TYPELISP_LINUX_MEMORY_LIMIT_NODE
        exec "$@"
    ' sh "$_linux_memory_limit_gate" "$_linux_memory_limit_leaf" \
        "$_linux_memory_limit_workload" "$@" &
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
        if linux_memory_limit_read_oom_kills "$_linux_memory_limit_leaf" &&
            [ "$_linux_memory_limit_oom_kills" -gt "$_linux_memory_limit_oom_kills_before" ]; then
            printf '1\n' > "$_linux_memory_limit_workload/cgroup.kill"
            wait "$_linux_memory_limit_pid" 2>/dev/null || true
            rm -f "$_linux_memory_limit_gate"
            rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
            linux_memory_limit_record_oom_peak "$_linux_memory_limit_workload"
            return 137
        fi
        if [ "$_linux_memory_limit_rss_excess_pending" -gt 0 ]; then
            echo "memory limit exceeded: aggregate RSS $_linux_memory_limit_rss_excess_pending KiB > ${_linux_memory_limit_kib} KiB (process-group sampler)" >&2
            kill -TERM "-$_linux_memory_limit_pid" 2>/dev/null || true
            sleep 0.1
            kill -KILL "-$_linux_memory_limit_pid" 2>/dev/null || true
            # Nested calls and detached descendants live outside the process
            # group; the workload's termination covers them too.
            printf '1\n' > "$_linux_memory_limit_workload/cgroup.kill" 2>/dev/null || true
            wait "$_linux_memory_limit_pid" 2>/dev/null || true
            rm -f "$_linux_memory_limit_gate"
            rmdir "$_linux_memory_limit_gate_dir" 2>/dev/null || true
            if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
                printf '%s\n' "$((_linux_memory_limit_peak_rss * 1024))" \
                    > "$TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE"
            fi
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
            # The exact workload cap remains active during one bounded OOM
            # recheck. A known RSS breach needs no further memory samples.
            _linux_memory_limit_rss_excess_pending=$_linux_memory_limit_rss
            sleep 0.05
            continue
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
    # The group can empty between two polls because of an OOM kill.
    if linux_memory_limit_read_oom_kills "$_linux_memory_limit_leaf" &&
        [ "$_linux_memory_limit_oom_kills" -gt "$_linux_memory_limit_oom_kills_before" ]; then
        printf '1\n' > "$_linux_memory_limit_workload/cgroup.kill"
        linux_memory_limit_record_oom_peak "$_linux_memory_limit_workload"
        return 137
    fi
    # The process-group samples miss nested calls, which run in their own
    # groups; the workload node's memory.peak is the measured peak of the
    # complete subtree.
    linux_memory_limit_read_peak "$_linux_memory_limit_workload"
    _linux_memory_limit_final_peak=$((_linux_memory_limit_peak_rss * 1024))
    if [ "$_linux_memory_limit_peak_read" -gt "$_linux_memory_limit_final_peak" ]; then
        _linux_memory_limit_final_peak=$_linux_memory_limit_peak_read
    fi
    if [ -n "${TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE:-}" ]; then
        printf '%s\n' "$_linux_memory_limit_final_peak" \
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
    linux_memory_limit_enclosing_node || return 2
    if [ -n "$_linux_memory_limit_node" ]; then
        linux_memory_limit_run_nested "$_linux_memory_limit_bytes" "$@"
        return $?
    fi
    linux_memory_limit_select_backend || return $?

    linux_memory_limit_run_systemd "$_linux_memory_limit_bytes" "$@"
}

# linux_memory_limit_run for a command that runs
# linux_memory_limit_sample_process_group (run-memory-bounded.sh
# --linux-rss-measure). Delegation isolates the capped workload node from the
# sampler. OOMPolicy=continue, which every unit uses, keeps systemd from
# terminating the sampler when the workload OOMs; the sampler records the
# workload's peak and kills it.
linux_memory_limit_run_sampled() {
    _linux_memory_limit_sampled=1
    _linux_memory_limit_sampled_status=0
    linux_memory_limit_run "$@" || _linux_memory_limit_sampled_status=$?
    _linux_memory_limit_sampled=0
    return "$_linux_memory_limit_sampled_status"
}
