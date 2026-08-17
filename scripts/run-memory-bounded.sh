#!/usr/bin/env sh
set -eu

# Cross-host fail-closed process-tree memory cap with a stable report.
#
# Linux uses lib-linux-memory-limit.sh (user cgroup or aggregate-RSS watchdog)
# and GNU time for the observed peak. Windows delegates to the suspended-start
# Job Object wrapper. A missing enforcement/measurement backend is a wrapper
# failure, never an unbounded fallback.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-memory-bounded.sh --limit-mib N --report PATH [--timeout-seconds N] [--working-directory DIR] -- COMMAND [ARG ...]

Exit codes: wrapped status; 124 timeout; 137 memory limit; 2 wrapper/setup failure.
EOF
}

if [ "${1:-}" = --linux-rss-measure ]; then
    shift
    limit_bytes=$1
    metrics_file=$2
    shift 2
    . "$ROOT/scripts/lib-linux-memory-limit.sh"
    TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE=$metrics_file
    export TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
    measure_status=0
    linux_memory_limit_run_watchdog "$limit_bytes" "$@" || measure_status=$?
    exit "$measure_status"
fi

if [ "${1:-}" = --linux-exec ]; then
    shift
    limit_bytes=$1
    timeout_seconds=$2
    backend=$3
    metrics_file=$4
    shift 4
    . "$ROOT/scripts/lib-linux-memory-limit.sh"
    LINUX_MEMORY_LIMIT_BACKEND=$backend
    TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE=$metrics_file
    export LINUX_MEMORY_LIMIT_BACKEND
    export TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE
    if [ "$backend" = systemd-user-cgroup ]; then
        # systemd's MemoryPeak summary can account only the service launcher on
        # some managers. Keep the hard cgroup cap, and measure the isolated
        # descendant group from inside that same cgroup for trustworthy RSS.
        set -- "$ROOT/scripts/run-memory-bounded.sh" --linux-rss-measure \
            "$limit_bytes" "$metrics_file" "$@"
    fi
    if [ "$timeout_seconds" -gt 0 ]; then
        exec_status=0
        linux_memory_limit_run "$limit_bytes" \
            timeout --signal=TERM --kill-after=5s "$timeout_seconds" \
            "$@" || exec_status=$?
        exit "$exec_status"
    fi
    exec_status=0
    linux_memory_limit_run "$limit_bytes" "$@" || exec_status=$?
    exit "$exec_status"
fi

limit_mib=
timeout_seconds=0
report=
working_directory=$PWD
while [ "$#" -gt 0 ]; do
    case "$1" in
        --limit-mib)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            limit_mib=$2
            shift 2
            ;;
        --timeout-seconds)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            timeout_seconds=$2
            shift 2
            ;;
        --report)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            report=$2
            shift 2
            ;;
        --working-directory)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            working_directory=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

case "$limit_mib" in
    "" | *[!0-9]* | 0)
        echo "bounded-run limit must be a positive MiB count: $limit_mib" >&2
        exit 2
        ;;
esac
case "$timeout_seconds" in
    "" | *[!0-9]*)
        echo "bounded-run timeout must be zero or a positive second count: $timeout_seconds" >&2
        exit 2
        ;;
esac
[ -n "$report" ] || {
    echo "bounded-run report path is required" >&2
    exit 2
}
[ "$#" -gt 0 ] || {
    echo "bounded-run command is required" >&2
    exit 2
}
[ -d "$working_directory" ] || {
    echo "bounded-run working directory does not exist: $working_directory" >&2
    exit 2
}

case "$report" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) report="$PWD/$report" ;;
esac
mkdir -p "$(dirname -- "$report")"
rm -f "$report"

case "$(uname -s)" in
    Linux*) host=linux ;;
    MINGW* | MSYS* | CYGWIN*) host=windows ;;
    *)
        echo "bounded-run unsupported host: $(uname -s)" >&2
        exit 2
        ;;
esac

limit_bytes=$((limit_mib * 1024 * 1024))
write_wrapper_failure_report() {
    _failure_backend=$1
    cat > "$report" <<EOF
schema_version=1
host=$host
backend=$_failure_backend
reason=wrapper-failure
exit_code=2
limit_bytes=$limit_bytes
peak_memory_bytes=0
wall_ms=0
EOF
}

if [ "$host" = windows ]; then
    if command -v powershell.exe >/dev/null 2>&1; then
        ps=powershell.exe
    elif command -v pwsh >/dev/null 2>&1; then
        ps=pwsh
    else
        echo "bounded-run Windows Job Object backend requires PowerShell" >&2
        write_wrapper_failure_report job-object
        exit 2
    fi
    # PowerShell's CreateProcess call needs a native executable path. MSYS does
    # not reliably rewrite the first wrapped-command argument after `--`.
    # Convert only that executable; bash/compiler arguments intentionally keep
    # their caller-visible spelling.
    case "$1" in
        /*)
            if command -v cygpath >/dev/null 2>&1; then
                command_exe=$(cygpath -w "$1")
                shift
                set -- "$command_exe" "$@"
            fi
            ;;
    esac
    set +e
    "$ps" -NoProfile -ExecutionPolicy Bypass \
        -File "$ROOT/scripts/run-bounded-process.ps1" \
        -LimitMiB "$limit_mib" \
        -TimeoutSeconds "$timeout_seconds" \
        -ReportPath "$report" \
        -WorkingDirectory "$working_directory" \
        -- "$@"
    status=$?
    set -e
    [ -s "$report" ] || {
        echo "bounded-run Windows backend wrote no report: $report" >&2
        exit 2
    }
    exit "$status"
fi

case "$1" in
    */*) command_available=$([ -x "$1" ] && printf yes || true) ;;
    *) command_available=$(command -v "$1" >/dev/null 2>&1 && printf yes || true) ;;
esac
if [ "$command_available" != yes ]; then
    echo "bounded-run command is unavailable: $1" >&2
    write_wrapper_failure_report unavailable
    exit 2
fi

command -v /usr/bin/time >/dev/null 2>&1 || {
    echo "bounded-run Linux measurement requires /usr/bin/time" >&2
    write_wrapper_failure_report unavailable
    exit 2
}
if [ "$timeout_seconds" -gt 0 ]; then
    command -v timeout >/dev/null 2>&1 || {
        echo "bounded-run Linux timeout requires GNU timeout" >&2
        write_wrapper_failure_report unavailable
        exit 2
    }
fi

. "$ROOT/scripts/lib-linux-memory-limit.sh"
LINUX_MEMORY_LIMIT_BACKEND=
if ! linux_memory_limit_select_backend; then
    write_wrapper_failure_report unavailable
    exit 2
fi
backend=$LINUX_MEMORY_LIMIT_BACKEND
export LINUX_MEMORY_LIMIT_BACKEND
time_file="$report.time"
metrics_file="$report.memory"
rm -f "$time_file" "$metrics_file"

set +e
(
    cd "$working_directory"
    /usr/bin/time \
        -f 'wall_seconds=%e\npeak_rss_kib=%M' \
        -o "$time_file" \
        "$ROOT/scripts/run-memory-bounded.sh" \
        --linux-exec "$limit_bytes" "$timeout_seconds" "$backend" \
        "$metrics_file" "$@"
)
status=$?
set -e

wall_seconds=$(sed -n 's/^wall_seconds=//p' "$time_file" 2>/dev/null || true)
peak_rss_kib=$(sed -n 's/^peak_rss_kib=//p' "$time_file" 2>/dev/null || true)
case "$wall_seconds:$peak_rss_kib" in
    *[!0-9.:]* | :* | *:)
        echo "bounded-run Linux measurement backend produced malformed output" >&2
        write_wrapper_failure_report "$backend"
        exit 2
        ;;
esac
wall_ms=$(awk -v seconds="$wall_seconds" 'BEGIN { printf "%.0f", seconds * 1000 }')
peak_memory_bytes=$((peak_rss_kib * 1024))
if [ -s "$metrics_file" ]; then
    measured_peak=$(sed -n '1p' "$metrics_file")
    case "$measured_peak" in
        "" | *[!0-9]*)
            echo "bounded-run Linux memory backend produced malformed peak evidence" >&2
            write_wrapper_failure_report "$backend"
            exit 2
            ;;
    esac
    peak_memory_bytes=$measured_peak
else
    echo "bounded-run Linux memory backend wrote no peak evidence" >&2
    write_wrapper_failure_report "$backend"
    exit 2
fi

reason=success
if [ "$status" -eq 124 ]; then
    reason=timeout
    echo "[bounded] timeout after ${timeout_seconds}s; terminated complete process tree" >&2
elif [ "$status" -eq 137 ]; then
    reason=memory-limit
    echo "[bounded] memory limit exceeded under $backend (cap ${limit_bytes} bytes)" >&2
elif [ "$status" -ne 0 ]; then
    reason=command-failure
fi

cat > "$report" <<EOF
schema_version=1
host=linux
backend=$backend
reason=$reason
exit_code=$status
limit_bytes=$limit_bytes
peak_memory_bytes=$peak_memory_bytes
wall_ms=$wall_ms
EOF
rm -f "$time_file" "$metrics_file"
echo "[bounded] reason=$reason exit=$status peak_rss_bytes=$peak_memory_bytes cap_bytes=$limit_bytes wall_ms=$wall_ms backend=$backend" >&2
exit "$status"
