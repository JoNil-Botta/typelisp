#!/usr/bin/env sh

# Shared synthetic completions for the three existing pool reader self-tests.
# Each case gets fresh, caller-owned paths; no compiler or cleanup is needed.
BOUNDED_COMPLETION_CASES='success command-1 command-2 command-7 cancelled signal timeout oom missing-report missing-status empty-report malformed duplicate status-mismatch false-success lost-failure wrong-limit wrong-host wrong-backend zero-peak missing-peak bad-peak bad-status'

bounded_completion_fixture() {
    _bc_report=$1
    _bc_status_file=$2
    _bc_host=$3
    _bc_cap=$4
    _bc_case=$5
    [ ! -e "$_bc_report" ] || mv "$_bc_report" "$_bc_report.previous"
    [ ! -e "$_bc_status_file" ] || mv "$_bc_status_file" "$_bc_status_file.previous"
    _bc_reason=success
    _bc_status=0
    BOUNDED_COMPLETION_ELIGIBLE=0
    case $_bc_case in
        success) BOUNDED_COMPLETION_ELIGIBLE=1 ;;
        command-*)
            _bc_reason=command-failure
            _bc_status=${_bc_case#command-}
            BOUNDED_COMPLETION_ELIGIBLE=1
            ;;
        cancelled) _bc_reason=wrapper-failure; _bc_status=2 ;;
        signal) _bc_reason=command-failure; _bc_status=143 ;;
        timeout) _bc_reason=timeout; _bc_status=124 ;;
        oom) _bc_reason=memory-limit; _bc_status=137 ;;
    esac
    if [ "$_bc_case" != missing-status ]; then
        printf '%s\n' "$_bc_status" > "$_bc_status_file"
    fi
    [ "$_bc_case" != missing-report ] || return 0
    _bc_backend=systemd-user-cgroup
    [ "$_bc_host" != windows ] || _bc_backend=job-object
    cat > "$_bc_report" <<EOF
schema_version=1
host=$_bc_host
backend=$_bc_backend
reason=$_bc_reason
exit_code=$_bc_status
limit_bytes=$((_bc_cap * 1024 * 1024))
peak_memory_bytes=1048576
wall_ms=1
EOF
    case $_bc_case in
        empty-report) : > "$_bc_report" ;;
        malformed) printf 'invalid completion\n' > "$_bc_report" ;;
        duplicate) printf 'reason=success\n' >> "$_bc_report" ;;
        status-mismatch) printf '2\n' > "$_bc_status_file" ;;
        false-success) sed 's/reason=success/reason=command-failure/' "$_bc_report" > "$_bc_report.tmp" ;;
        lost-failure) sed 's/exit_code=0/exit_code=2/' "$_bc_report" > "$_bc_report.tmp"; printf '2\n' > "$_bc_status_file" ;;
        wrong-limit) sed 's/^limit_bytes=.*/limit_bytes=1/' "$_bc_report" > "$_bc_report.tmp" ;;
        wrong-host) sed 's/^host=.*/host=foreign/' "$_bc_report" > "$_bc_report.tmp" ;;
        wrong-backend) sed 's/^backend=.*/backend=unbounded/' "$_bc_report" > "$_bc_report.tmp" ;;
        zero-peak) sed 's/^peak_memory_bytes=.*/peak_memory_bytes=0/' "$_bc_report" > "$_bc_report.tmp" ;;
        missing-peak) sed '/^peak_memory_bytes=/d' "$_bc_report" > "$_bc_report.tmp" ;;
        bad-peak) sed 's/^peak_memory_bytes=.*/peak_memory_bytes=invalid/' "$_bc_report" > "$_bc_report.tmp" ;;
        bad-status) printf 'invalid\n' > "$_bc_status_file" ;;
    esac
    [ ! -f "$_bc_report.tmp" ] || mv "$_bc_report.tmp" "$_bc_report"
    if [ "$_bc_host" = windows ]; then
        awk '{ printf "%s\r\n", $0 }' "$_bc_report" > "$_bc_report.crlf"
        mv "$_bc_report.crlf" "$_bc_report"
    fi
}

# Drive the real inline/manifest job callback through the shared pool. Only the
# timed command is planted, so no shell-script compiler needs a Windows job.
# With one worker, an invalid first completion must leave job two unclaimed.
bounded_completion_worker_fixture() (
    _bc_kind=$1
    WORKDIR=$2
    HOST_OS=$3
    _bc_worker_cap=$4
    _bc_worker_case=$5
    COMPILER=uncallable-compiler
    TYPELISP_CI_TIMING=0
    INLINE_TEST_POOL_DIR="$WORKDIR/pool"
    MANIFEST_POOL_DIR="$WORKDIR/pool"
    MANIFEST_POOL_ENFORCE_CAPS=1
    BATCH_CHUNK_DIR=$WORKDIR
    batch_chunk_count=2
    _bc_first=chunk-001
    _bc_second=chunk-002
    if [ "$_bc_kind" = manifest ]; then _bc_first=chunk-1; _bc_second=chunk-2; fi
    mkdir -p "$WORKDIR"
    printf '%s|%s\n%s|%s\n' "$_bc_first" "$_bc_worker_cap" \
        "$_bc_second" "$_bc_worker_cap" > "$WORKDIR/queue"
    ci_timing_run() {
        printf '%s\n' "$_pool_job" >> "$WORKDIR/started"
        _bc_worker_mode=success
        [ "$_pool_job" != "$_bc_first" ] || _bc_worker_mode=$_bc_worker_case
        _bc_worker_report="$WORKDIR/$_pool_job.memory"
        if [ "$_bc_kind" = manifest ]; then
            _bc_worker_report="$_chunk.memory"
            printf 'compiler output\n' > "$_chunk.out"
            printf 'compiler diagnostic\n' > "$_chunk.err"
        fi
        bounded_completion_fixture "$_bc_worker_report" "$WORKDIR/wait-$_pool_job" \
            "$HOST_OS" "$_bc_worker_cap" "$_bc_worker_mode"
        case $_bc_worker_mode in missing-status | bad-status) return 2 ;; esac
        return "$(cat "$WORKDIR/wait-$_pool_job")"
    }
    bounded_pool_init "$WORKDIR/pool" "$_bc_worker_cap" "$WORKDIR/queue" || exit 1
    bounded_pool_start "$WORKDIR/pool" 1
    _bc_worker_rc=0
    bounded_pool_join "$WORKDIR/pool" || _bc_worker_rc=$?
    case $_bc_worker_case in
        success | command-*)
            [ "$_bc_worker_rc" -eq 0 ] && [ -d "$WORKDIR/pool/claims/$_bc_second" ] || exit 1
            ;;
        *)
            [ "$_bc_worker_rc" -ne 0 ] && [ -e "$WORKDIR/pool/abort" ] &&
                [ ! -e "$WORKDIR/pool/claims/$_bc_second" ] || exit 1
            ;;
    esac
)
