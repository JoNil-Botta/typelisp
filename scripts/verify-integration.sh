#!/usr/bin/env sh
set -eu
# Compile helpers redirect their streams per case; gate failures must still
# reach the gate's console instead of disappearing inside a build log.
exec 9>&2

# verify-integration.sh - manifest-driven native integration runner.
#
# The runner builds each listed TypeLisp program to a native executable, runs
# it, and checks exit code, stdout, and stderr. Linux
# uses the explicit compile -> as -> ld flow; Windows Git Bash/MSYS/Cygwin uses
# bounded native-link and persistent execution queues so independent links can
# overlap while full Windows exit values and byte streams survive without a
# PowerShell launch per manifest case.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-source-location.sh"
. "$ROOT/scripts/lib-ci-timing.sh"
BOUNDED_POOL_LABEL=integration
. "$ROOT/scripts/lib-bounded-pool.sh"

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-integration.sh [--shard NAME] [--backend-cmp-mem-fold-parity-only | --self-test-batch-observability | --self-test-empty-compile-diagnostic | --self-test-signal-notice-capture | --self-test-path-normalization | --validate-manifest-only]

Runs manifest-driven native integration tests.
--shard NAME runs one shard of the corpus (see integration_shards): its batch
groups only, staged in its own work root, so CI can run the shards as separate
gates on one host. Without it the whole corpus runs in one work root.
--backend-cmp-mem-fold-parity-only runs the opt0/opt2 backend memory-fold
runtime-parity matrix without building the rest of the integration corpus.
--self-test-batch-observability exercises the batch sentinel selection and
per-chunk timing row without invoking a compiler or native toolchain.
--self-test-empty-compile-diagnostic exercises the compile-failure diagnostic
helper without invoking a compiler or native toolchain.
--self-test-signal-notice-capture exercises Linux signal exit, shell-notice
capture and the per-case deadline without invoking a compiler or native
toolchain.
--self-test-path-normalization exercises Windows diagnostic checkout-prefix and
CRLF normalization without invoking a compiler or native toolchain.
--validate-manifest-only validates the host manifest and exits before builds.
EOF
}

# The corpus runs as shards, one gate each: name|work root suffix|batch groups.
# A shard lists its heaviest group first, so the batch pool's longest chunk
# starts on an idle worker instead of trailing the queue. The `-` suffix marks
# the canonical shard: it keeps target/integration-verify/HOST/, which later
# gates reuse, and runs every host-level check that needs that root or an
# already-built default-level corpus binary (the host fixture corpora, the
# Windows runner differential).
integration_shards() {
    cat <<'EOF'
default|-|stage-stdlib embedded embedded-scalar
opt-levels|-opt-levels|stage-stdlib-opt0 stage-stdlib-opt1 stage-stdlib-opt2 embedded-opt0 embedded-opt1 embedded-opt2
EOF
}

# integration_resolve_shard NAME: set INTEGRATION_BATCH_GROUPS (the groups this
# run compiles, stages and runs), INTEGRATION_ALL_GROUPS (every group a shard
# names), INTEGRATION_SHARD_SUFFIX and INTEGRATION_SHARD_CANONICAL. An empty
# NAME is the whole corpus in one work root. A group named by two shards is
# refused here and integration_select_shard refuses a manifest group that no
# shard names, so a new batch group cannot fall out of CI.
integration_resolve_shard() {
    _shard_want=${1:-}
    _shard_all=
    _shard_sel=
    _shard_suffix=
    _shard_canonical=0
    _shard_canonicals=0
    _shard_matched=0
    while IFS='|' read -r _shard_name _shard_root _shard_groups; do
        case "$_shard_name" in
            "" | \#*) continue ;;
        esac
        case "$_shard_root" in
            -) _shard_canonicals=$((_shard_canonicals + 1)) ;;
        esac
        for _shard_group in $_shard_groups; do
            case " $_shard_all " in
                *" $_shard_group "*)
                    echo "integration shard $_shard_name repeats batch group: $_shard_group" >&2
                    return 1
                    ;;
            esac
            _shard_all="$_shard_all $_shard_group"
        done
        if [ "$_shard_name" = "$_shard_want" ]; then
            _shard_matched=1
            _shard_sel=" $_shard_groups"
            case "$_shard_root" in
                -)
                    _shard_suffix=
                    _shard_canonical=1
                    ;;
                *) _shard_suffix=$_shard_root ;;
            esac
        fi
    done <<EOF
$(integration_shards)
EOF
    # The canonical (`-`) shard keeps the historical work root the host fixture
    # corpora and the Windows runner differential need, so the table must name
    # exactly one; zero or two would silently drop or duplicate those checks.
    if [ "$_shard_canonicals" -ne 1 ]; then
        echo "integration_shards: expected exactly one canonical ('-') shard, found $_shard_canonicals" >&2
        return 1
    fi
    if [ -z "$_shard_want" ]; then
        _shard_sel=$_shard_all
        _shard_canonical=1
    elif [ "$_shard_matched" -eq 0 ]; then
        echo "unknown integration shard: $_shard_want" >&2
        echo "expected one of: $(integration_shards | awk -F '|' '!/^#/ {printf "%s ", $1}')" >&2
        return 1
    fi
    INTEGRATION_BATCH_GROUPS=${_shard_sel# }
    INTEGRATION_ALL_GROUPS=${_shard_all# }
    INTEGRATION_SHARD_SUFFIX=$_shard_suffix
    INTEGRATION_SHARD_CANONICAL=$_shard_canonical
}

SELF_TEST_BATCH_OBSERVABILITY=0
SELF_TEST_EMPTY_COMPILE_DIAGNOSTIC=0
SELF_TEST_SIGNAL_NOTICE_CAPTURE=0
SELF_TEST_PATH_NORMALIZATION=0
SELF_TEST_WITHOUT_COMPILER=0
VALIDATE_MANIFEST_ONLY=0
BACKEND_CMP_MEM_FOLD_PARITY_ONLY=0
# Each self-test runs as its own gate beside the corpus, so it keeps its own
# work root; the corpus root holds artifacts later gates reuse.
WORK_SUFFIX=
# `--shard NAME` carries its value, so it is read before the single-option
# cases below, which then see what follows it.
INTEGRATION_SHARD_NAME=
if [ "${1:-}" = --shard ]; then
    [ "$#" -ge 2 ] || { usage; exit 2; }
    INTEGRATION_SHARD_NAME=$2
    shift 2
fi
case "${1:-}" in
    "")
        ;;
    --backend-cmp-mem-fold-parity-only)
        BACKEND_CMP_MEM_FOLD_PARITY_ONLY=1
        shift
        ;;
    --self-test-batch-observability)
        SELF_TEST_BATCH_OBSERVABILITY=1
        SELF_TEST_WITHOUT_COMPILER=1
        WORK_SUFFIX=-self-test-batch-observability
        shift
        ;;
    --self-test-empty-compile-diagnostic)
        SELF_TEST_EMPTY_COMPILE_DIAGNOSTIC=1
        SELF_TEST_WITHOUT_COMPILER=1
        WORK_SUFFIX=-self-test-empty-compile-diagnostic
        shift
        ;;
    --self-test-signal-notice-capture)
        SELF_TEST_SIGNAL_NOTICE_CAPTURE=1
        SELF_TEST_WITHOUT_COMPILER=1
        WORK_SUFFIX=-self-test-signal-notice-capture
        shift
        ;;
    --self-test-path-normalization)
        SELF_TEST_PATH_NORMALIZATION=1
        SELF_TEST_WITHOUT_COMPILER=1
        WORK_SUFFIX=-self-test-path-normalization
        shift
        ;;
    --validate-manifest-only)
        VALIDATE_MANIFEST_ONLY=1
        shift
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
if [ "$#" -ne 0 ]; then
    usage
    exit 2
fi
if [ -n "$INTEGRATION_SHARD_NAME" ] && [ "$SELF_TEST_WITHOUT_COMPILER" -eq 1 ]; then
    echo "[integration] --shard runs a corpus shard, not a self-test mode" >&2
    exit 2
fi
integration_resolve_shard "$INTEGRATION_SHARD_NAME" || exit 2
if [ -n "$INTEGRATION_SHARD_NAME" ]; then
    WORK_SUFFIX=$INTEGRATION_SHARD_SUFFIX
fi

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "integration verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ "$SELF_TEST_WITHOUT_COMPILER" -eq 0 ]; then
    if [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        # Local-development fallback: fetch the published
        # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi

    if [ ! -x "$COMPILER" ]; then
        echo "typelisp compiler is not executable: $COMPILER" >&2
        exit 1
    fi
else
    COMPILER=${TYPELISP_BIN:-typelisp}
fi
# Resolve the host stdlib archive once; the per-case
# `$(linux_stdlib_archive_for_asm ...)` subshells inherit the cached answer.
[ "$HOST_OS" != linux ] || stdlib_archive_resolve_triple x86_64-unknown-linux-gnu "${COMPILER:-}"

# A signal-shaped crash from a manifest binary is a real compiler/runtime bug,
# not a flake — run each build/emit exactly once and let the crash fail CI (see
# the no-retry policy in scripts/ci-verify.sh).

# Run a `typelisp build`/`compile` invocation once. Output flows to the caller's
# streams; sets `build_rc` to its exit code.
run_build() {
    set +e
    "$@"
    build_rc=$?
    set -e
}

# Run a `$COMPILER run <fixture.tl> …` emit step and abort on any failure (these
# fixtures emit assembly deterministically; a non-zero exit is a real bug).
run_fixture() {
    run_build "$@"
    if [ "$build_rc" -ne 0 ]; then
        echo "FAIL: fixture run '$*' exited $build_rc" >&2
        exit 1
    fi
}

# Run a Linux manifest binary under a child shell that remains alive long
# enough to observe and report a signal-shaped exit. The child shell's own
# crash notice goes to a diagnostic-only stream, while the program's stderr
# stays isolated for the manifest comparison. Ending with an explicit exit
# prevents shells from replacing themselves with the manifest binary.
ensure_linux_signal_exit_diagnostic() {
    _rc=$1
    _run_shell_stderr=$2

    # POSIX leaves signal-notice text to the shell, and some shells emit
    # nothing for this nested-exec shape. Preserve a real notice when one was
    # captured; otherwise retain the portable 128+signal evidence in the same
    # diagnostic-only stream used by failed manifest cases.
    if [ "$_rc" -gt 128 ] && [ "$_rc" -le 255 ] &&
        [ ! -s "$_run_shell_stderr" ]; then
        _signal=$((_rc - 128))
        printf 'program terminated by signal %s (exit %s); shell emitted no notice\n' \
            "$_signal" "$_rc" > "$_run_shell_stderr"
    fi
}

# Every manifest case run has this wall-clock deadline, far above the slowest
# case, so a hung case fails its own row instead of the whole CI job.
INTEGRATION_CASE_TIMEOUT_SECONDS=300
case_timed_out=0

# GNU timeout puts the case in a new process group and, at the deadline, sends
# SIGKILL to that whole group, so neither the case nor a descendant that
# ignores SIGTERM outlives it. The case execs from an inner shell, so timeout's
# own diagnostics go to the shell stream, never the compared program stderr.
# case_timed_out is set when the run ended by SIGKILL (137) no earlier than
# the deadline, less one tick of the centisecond clock.
run_linux_manifest_program() {
    _bin=$1
    _stdout=$2
    _stderr=$3
    _run_shell_stderr=$4
    shift 4

    ci_timing_set_now_ms
    _run_started=$CI_TIMING_NOW_MS
    # A deadline that owns the case's process group. GNU timeout returns 137
    # and kills the group; uutils timeout 0.10 returns 124 and leaves the
    # group's descendants, so the shell takes the deadline itself.
    # The subshell's stderr silenced the shell's job notice when the deadline
    # kills the background case; its case's own streams stay explicit files.
    _rc=0
    (
        setsid sh -c '
            _stdout=$1
            _stderr=$2
            shift 2
            ( exec "$@" ) > "$_stdout" 2> "$_stderr"
        ' typelisp-integration-case "$_stdout" "$_stderr" "$_bin" "$@" \
            2> "$_run_shell_stderr" &
        _case_pid=$!
        (
            _ticks=0
            _limit=$((INTEGRATION_CASE_TIMEOUT_SECONDS * 20))
            while [ "$_ticks" -lt "$_limit" ]; do
                sleep 0.05
                _ticks=$((_ticks + 1))
            done
            kill -KILL "-$_case_pid" 2>/dev/null || true
        ) &
        _case_watchdog=$!
        _case_status=0
        wait "$_case_pid" || _case_status=$?
        kill "$_case_watchdog" 2>/dev/null || true
        wait "$_case_watchdog" 2>/dev/null || true
        exit "$_case_status"
    ) 2>/dev/null || _rc=$?
    ci_timing_set_now_ms
    case_timed_out=0
    if [ "$_rc" -eq 137 ] &&
        [ $((CI_TIMING_NOW_MS - _run_started)) -ge $((INTEGRATION_CASE_TIMEOUT_SECONDS * 1000 - 10)) ]; then
        case_timed_out=1
    fi
    ensure_linux_signal_exit_diagnostic "$_rc" "$_run_shell_stderr"
    return "$_rc"
}

# A case stopped at its deadline fails its own row with the output it wrote.
report_case_timeout() {
    echo "FAIL: $1 ($2)" >&2
    show_stream_if_nonempty stdout "$3"
    show_stream_if_nonempty stderr "$4"
}

if [ "$SELF_TEST_WITHOUT_COMPILER" -eq 0 ]; then
    if [ "$HOST_OS" = linux ]; then
        command -v as >/dev/null 2>&1 || {
            echo "missing assembler: as" >&2
            exit 1
        }
        command -v ld >/dev/null 2>&1 || {
            echo "missing linker: ld" >&2
            exit 1
        }
        command -v timeout >/dev/null 2>&1 || {
            echo "missing GNU timeout for the per-case deadline" >&2
            exit 1
        }
    else
        command -v powershell.exe >/dev/null 2>&1 || {
            echo "missing powershell.exe for Windows exit-code capture" >&2
            exit 1
        }
        command -v cygpath >/dev/null 2>&1 || {
            echo "missing cygpath for Windows path conversion" >&2
            exit 1
        }
        command -v clang >/dev/null 2>&1 || {
            echo "missing assembler: clang" >&2
            exit 1
        }
        command -v lld-link >/dev/null 2>&1 || {
            echo "missing linker: lld-link" >&2
            exit 1
        }
    fi
fi

. "$ROOT/scripts/lib-manifest.sh"
MANIFEST_DIR="$ROOT/tests/integration/manifest.d"
WORKDIR="$ROOT/target/integration-verify/$HOST_OS$WORK_SUFFIX"
_work_root_owned=0
case "$WORKDIR" in
    "$ROOT/target/integration-verify/"linux | "$ROOT/target/integration-verify/"windows | \
        "$ROOT/target/integration-verify/"linux-self-test-* | "$ROOT/target/integration-verify/"windows-self-test-*)
        _work_root_owned=1 ;;
esac
if [ "$_work_root_owned" -eq 0 ] && [ -n "$INTEGRATION_SHARD_SUFFIX" ] &&
    [ "$WORKDIR" = "$ROOT/target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX" ]; then
    _work_root_owned=1
fi
if [ "$_work_root_owned" -eq 0 ]; then
    echo "FAIL: unowned integration scratch root: $WORKDIR" >&2
    exit 1
fi
[ ! -L "$WORKDIR" ] || exit 1
rm -rf -- "${WORKDIR:?}"
mkdir -p "$WORKDIR"
source_location_self_test "$WORKDIR/source-location-self-test"
# This host's rows of the shared manifest, one per name and opt level, in this
# shard's own work root: a shard stages, compiles and runs its rows under
# target/integration-verify/HOST<shard suffix>, the spelling the compiler and a
# manifest's $SRC placeholder use, so two shards never share a staged case.
# validate_manifest below checks every row of them; integration_select_shard
# derives the rows this shard runs.
COMBINED_MANIFEST="$WORKDIR/manifest.combined"
manifest_concat_dir "$MANIFEST_DIR" > "$COMBINED_MANIFEST"
HOST_MANIFEST="$WORKDIR/manifest.normalized"
awk -v host="$HOST_OS" -v work_root="target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX" \
    -f "$ROOT/scripts/expand-integration-manifest.awk" "$COMBINED_MANIFEST" \
    > "$HOST_MANIFEST"

# Batch chunks compile in a bounded pool (scripts/lib-bounded-pool.sh):
# TYPELISP_INTEGRATION_WORKERS compiler processes at once (1-4; default 3 on
# Linux, 4 on Windows), each under an enforced memory cap and timeout (a user
# cgroup on Linux, a Job Object on Windows), so at most workers x cap MiB of
# caps run concurrently. On Windows the measured chunk peak is ~1,238 MiB, so
# 4 x 2,560 MiB = 10,240 MiB stays well within 14,336 MiB with >2x headroom.
if [ "$HOST_OS" = windows ]; then
    INTEGRATION_DEFAULT_WORKERS=4
    INTEGRATION_POOL_CHUNK_CAP_MIB=2560
else
    INTEGRATION_DEFAULT_WORKERS=3
    INTEGRATION_POOL_CHUNK_CAP_MIB=4096
fi
INTEGRATION_POOL_WORKERS=${TYPELISP_INTEGRATION_WORKERS:-$INTEGRATION_DEFAULT_WORKERS}
case "$INTEGRATION_POOL_WORKERS" in
    1 | 2 | 3 | 4) ;;
    *)
        echo "invalid TYPELISP_INTEGRATION_WORKERS: $INTEGRATION_POOL_WORKERS (expected 1-4)" >&2
        exit 2
        ;;
esac
INTEGRATION_POOL_BUDGET_MIB=$((INTEGRATION_POOL_WORKERS * INTEGRATION_POOL_CHUNK_CAP_MIB))
INTEGRATION_BATCH_CHUNK_MAX_WEIGHT=550000
INTEGRATION_LOCAL_FILTER_ACTIVE=0
INTEGRATION_POOL_JOB_TIMEOUT_SECONDS=900
# Internal: only the batch observability self-test turns enforcement off, on
# Windows, where the Job Object wrapper cannot launch its shell-script compiler.
INTEGRATION_POOL_ENFORCE_CAPS=1
INTEGRATION_BATCH_DEFER_WINDOWS_PLAN=0
INTEGRATION_POOL_DIR=
INTEGRATION_POOL_WALL_MS=0
INTEGRATION_POOL_PEAK_BYTES=0
INTEGRATION_POOL_PEAK_LABEL=

# A default-level group keeps the compiler's default argv. Pinned groups carry
# their explicit level through both the batch and standalone assembly oracle.
integration_batch_group_run() {
    _compile_group=$1
    shift
    set -- "$@" --verify-ir
    case "$_compile_group" in
        embedded | stage-stdlib) ;;
        embedded-scalar)
            set -- "$@" --backend-mode scalar
            ;;
        embedded-opt0 | stage-stdlib-opt0 | embedded-opt1 | stage-stdlib-opt1 | embedded-opt2 | stage-stdlib-opt2)
            set -- "$@" --opt-level "${_compile_group##*opt}"
            ;;
        *)
            echo "[integration] invalid batch group: $_compile_group" >&2
            return 1
            ;;
    esac
    case "$_compile_group" in
        embedded | embedded-scalar | embedded-opt*)
            # shellcheck disable=SC2086
            "$@" $INTEGRATION_BATCH_TARGET_ARGS --stdlib-root "$ROOT/src"
            ;;
        stage-stdlib | stage-stdlib-opt*)
            # shellcheck disable=SC2086
            "$@" $INTEGRATION_BATCH_TARGET_ARGS --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src"
            ;;
    esac
}

# Compile one batch chunk. The timing row deliberately describes the actual
# compiler process rather than attributing its elapsed time to individual
# cases, which would turn a measurement into a derived estimate.
#
# This half runs inside a pool worker, so it touches no shared counter: it
# leaves the compiler's status, its elapsed time and, when CAP_MIB is set, the
# memory report of its bounded run in the chunk's own files. The parent reads
# them back in chunk order through integration_batch_settle_chunk.
integration_batch_compile_chunk() {
    _chunk_list=$1
    _chunk_label=$2
    _chunk_cap=$3
    shift 3
    _chunk_stdout="$WORKDIR/batch-$_chunk_label.stdout"
    _chunk_stderr="$WORKDIR/batch-$_chunk_label.stderr"
    _chunk_status="$WORKDIR/batch-$_chunk_label.status"
    _chunk_elapsed="$WORKDIR/batch-$_chunk_label.elapsed-ms"
    _chunk_report="$WORKDIR/batch-$_chunk_label.memory"
    : > "$_chunk_status"
    : > "$_chunk_elapsed"
    : > "$_chunk_report"
    if [ "$HOST_OS" = windows ]; then
        _chunk_plan="$WORKDIR/batch-$_chunk_label.plan"
        : > "$_chunk_plan"
        set -- "$COMPILER" compile --batch "$_chunk_list" \
            --windows-coff-plan "$_chunk_plan" "$@"
    else
        set -- "$COMPILER" compile --batch "$_chunk_list" "$@"
    fi
    if [ -n "$_chunk_cap" ]; then
        set -- "$ROOT/scripts/run-memory-bounded.sh" \
            --limit-mib "$_chunk_cap" --report "$_chunk_report" \
            --timeout-seconds "$INTEGRATION_POOL_JOB_TIMEOUT_SECONDS" -- "$@"
    fi
    ci_timing_set_now_ms
    _chunk_started=$CI_TIMING_NOW_MS
    set +e
    ci_timing_run "batch-$_chunk_label" compile "$@" \
        > "$_chunk_stdout" 2> "$_chunk_stderr"
    _chunk_rc=$?
    set -e
    ci_timing_set_now_ms
    printf '%s\n' "$((CI_TIMING_NOW_MS - _chunk_started))" > "$_chunk_elapsed"
    printf '%s\n' "$_chunk_rc" > "$_chunk_status"
}

# Account for one compiled chunk in the parent, in chunk order: counters,
# Windows plan registration, and the standalone fallback of a failed chunk.
# Cancellation, invalid completion, memory cap, timeout or missing status fails
# the gate before any standalone diagnostic fallback.
integration_batch_settle_chunk() {
    _chunk_list=$1
    _chunk_label=$2
    _chunk_cap=$3
    INTEGRATION_BATCH_CHUNKS=$((INTEGRATION_BATCH_CHUNKS + 1))
    _chunk_stderr="$WORKDIR/batch-$_chunk_label.stderr"
    _chunk_status="$WORKDIR/batch-$_chunk_label.status"
    _chunk_elapsed="$WORKDIR/batch-$_chunk_label.elapsed-ms"
    _chunk_report="$WORKDIR/batch-$_chunk_label.memory"
    _chunk_plan=
    [ "$HOST_OS" != windows ] || _chunk_plan="$WORKDIR/batch-$_chunk_label.plan"
    if [ ! -s "$_chunk_status" ] || [ ! -s "$_chunk_elapsed" ]; then
        echo "FAIL: batch chunk $_chunk_label left no compile status" >&2
        exit 1
    fi
    IFS= read -r _chunk_rc < "$_chunk_status" || return 1
    if [ -n "$_chunk_cap" ]; then
        if ! bounded_pool_read_report "$_chunk_report" "$_chunk_rc" "$_chunk_cap" "$HOST_OS"; then
            echo "FAIL: batch chunk $_chunk_label $BOUNDED_POOL_REPORT_FAILURE" \
                "(reason=$BOUNDED_POOL_REPORT_REASON, exit=$_chunk_rc, reported-exit=$BOUNDED_POOL_REPORT_EXIT_CODE, cap $_chunk_cap MiB," \
                "timeout $INTEGRATION_POOL_JOB_TIMEOUT_SECONDS s)" >&2
            sed 's/^/  /' "$_chunk_stderr" >&2 || true
            exit 1
        fi
        _chunk_peak=$BOUNDED_POOL_REPORT_PEAK
        if [ "$_chunk_peak" -gt "$INTEGRATION_POOL_PEAK_BYTES" ]; then
            INTEGRATION_POOL_PEAK_BYTES=$_chunk_peak
            INTEGRATION_POOL_PEAK_LABEL=$_chunk_label
        fi
    fi
    if [ "$HOST_OS" = windows ]; then
        IFS= read -r _chunk_elapsed_ms < "$_chunk_elapsed" || return 1
        WINDOWS_MANIFEST_BATCH_COMPILE_MS=$((
            WINDOWS_MANIFEST_BATCH_COMPILE_MS + _chunk_elapsed_ms
        ))
        WINDOWS_MANIFEST_BATCH_COMPILES=$((WINDOWS_MANIFEST_BATCH_COMPILES + 1))
    fi
    if [ "$_chunk_rc" -eq 0 ]; then
        if [ "$HOST_OS" = windows ]; then
            if [ "${INTEGRATION_BATCH_DEFER_WINDOWS_PLAN:-0}" -eq 1 ]; then
                printf '%s|%s|%s\n' "$_chunk_list" "$_chunk_plan" "$_chunk_label" \
                    >> "$WORKDIR/batch-pool.windows-plans" || return 1
            else
                integration_windows_register_plan \
                    "$_chunk_list" "$_chunk_plan" "$_chunk_label" || return 1
            fi
        fi
        return 0
    fi
    INTEGRATION_BATCH_FAILED_CHUNKS=$((INTEGRATION_BATCH_FAILED_CHUNKS + 1))
    echo "[integration] batch chunk $_chunk_label exited $_chunk_rc;" \
        "replaying its entries standalone (diagnostic-only; batch failure remains fatal)" >&2
    [ -z "$_chunk_cap" ] || echo "[integration] reported workload exit=$BOUNDED_POOL_REPORT_EXIT_CODE" >&2
    sed 's/^/  /' "$_chunk_stderr" >&2 || true
    while IFS='|' read -r _batch_src _batch_artifact1 _batch_artifact2 _batch_mode; do
        [ -n "$_batch_artifact1" ] || continue
        integration_remove_batch_artifact "$_batch_artifact1" || return 1
        printf '%s\n' "$_chunk_label" > "${_batch_owned_artifact%/*}/batch-diagnostic-only" || return 1
        if [ -n "$_batch_artifact2" ]; then
            integration_remove_batch_artifact "$_batch_artifact2" || return 1
            _batch_case_path=${_batch_src%/*}
            _batch_case=${_batch_case_path##*/}
            integration_remove_batch_artifact "$WORKDIR/$_batch_case/windows-coff.artifact" || return 1
        fi
    done < "$_chunk_list"
    [ -z "$_chunk_plan" ] || integration_remove_batch_artifact "$_chunk_plan" || return 1
    return 0
}

integration_batch_require_success() {
    [ "$INTEGRATION_BATCH_FAILED_CHUNKS" -eq 0 ] || {
        echo "FAIL: $INTEGRATION_BATCH_FAILED_CHUNKS batch chunk(s) failed; standalone replay was diagnostic-only" >&9
        return 1
    }
}

# A successful diagnostic replay can explain a batch failure, but its output
# must not supply passing native evidence for that failed attempt.
integration_diagnostic_only() {
    [ -f "$1/batch-diagnostic-only" ] || return 1
    echo "[integration] $2: diagnostic-only compile completed; no passing native result is published" >&9 || exit 1
    return 0
}

integration_remove_batch_artifact() {
    case $1 in
        /*) _batch_owned_artifact=$1 ;;
        *) _batch_owned_artifact="$ROOT/$1" ;;
    esac
    case $_batch_owned_artifact in
        */../* | */./*) return 1 ;;
        "${WORKDIR:?}"/*) rm -f -- "${_batch_owned_artifact:?}" ;;
        *) echo "FAIL: unowned batch artifact: $_batch_owned_artifact" >&2; return 1 ;;
    esac
}

# Standalone diagnostics (including failed batch entries) retain the chunk's
# process-tree cap, swap policy and deadline. Refuse invalid completion before
# an emitted assembly file or a user-facing compile diagnostic can be used.
integration_standalone_compile() {
    _standalone_report=$1
    shift
    if [ -f "${_standalone_report%/*}/batch-diagnostic-only" ]; then
        echo "[integration] diagnostic-only bounded replay; original batch failure remains fatal" >&9
    fi
    _standalone_rc=0
    "$ROOT/scripts/run-memory-bounded.sh" \
        --limit-mib "$INTEGRATION_POOL_CHUNK_CAP_MIB" --report "$_standalone_report" \
        --timeout-seconds "$INTEGRATION_POOL_JOB_TIMEOUT_SECONDS" -- "$@" || _standalone_rc=$?
    if ! bounded_pool_read_report "$_standalone_report" "$_standalone_rc" \
        "$INTEGRATION_POOL_CHUNK_CAP_MIB" "$HOST_OS"; then
        echo "FAIL: standalone compile has no eligible bounded completion" \
            "(reason=$BOUNDED_POOL_REPORT_REASON, exit=$_standalone_rc," \
            "cap $INTEGRATION_POOL_CHUNK_CAP_MIB MiB, timeout $INTEGRATION_POOL_JOB_TIMEOUT_SECONDS s)" >&9
        exit 1
    fi
    return "$_standalone_rc"
}

# Compile and account for one chunk in this process, without a cap: the serial
# route that the batch observability self-test pins next to the pooled one.
integration_batch_run_chunk() {
    _run_chunk_list=$1
    _run_chunk_label=$2
    shift 2
    integration_batch_compile_chunk "$_run_chunk_list" "$_run_chunk_label" '' "$@"
    integration_batch_settle_chunk "$_run_chunk_list" "$_run_chunk_label" ''
}

# The pool's job callback (see lib-bounded-pool.sh). A job is one chunk named
# `batch-<group>-<index>`; its list sits at `$WORKDIR/<job>.list`, and its
# timing rows go to a private file that integration_batch_run_pool merges in
# queue order, so the published rows do not depend on scheduling.
bounded_pool_run_job() {
    _pool_job=$1
    _pool_cap=$2
    [ "$INTEGRATION_POOL_ENFORCE_CAPS" -eq 1 ] || _pool_cap=
    _pool_label=${_pool_job#batch-}
    if ci_timing_enabled; then
        TYPELISP_CI_TIMING_FILE="$INTEGRATION_POOL_DIR/timing/$_pool_job.tsv"
    fi
    integration_batch_group_run "${_pool_label%-*}" \
        integration_batch_compile_chunk "$WORKDIR/$_pool_job.list" \
        "$_pool_label" "$_pool_cap" || return 1
    if [ -n "$_pool_cap" ] && ! bounded_pool_read_report "$WORKDIR/$_pool_job.memory" \
        "$(cat "$WORKDIR/$_pool_job.status")" "$_pool_cap" "$HOST_OS"; then
        echo "FAIL: batch chunk $_pool_label $BOUNDED_POOL_REPORT_FAILURE" \
            "(reason=$BOUNDED_POOL_REPORT_REASON, reported-exit=$BOUNDED_POOL_REPORT_EXIT_CODE)" >&2
        sed 's/^/  /' "$WORKDIR/$_pool_job.stderr" >&2 || true
        return 1
    fi
}

# Publish the jobs' private timing rows in queue order. A passing pool requires
# a row from every job; a failing one still publishes what ran.
integration_batch_merge_pool_timing() {
    ci_timing_enabled || return 0
    _merge_mode=$1
    set --
    while IFS='|' read -r _merge_job _merge_cap; do
        _merge_rows="$INTEGRATION_POOL_DIR/timing/$_merge_job.tsv"
        if [ -s "$_merge_rows" ]; then
            set -- "$@" "$_merge_rows"
        elif [ "$_merge_mode" = required ]; then
            echo "FAIL: batch pool job published no timing row: $_merge_job" >&2
            exit 1
        fi
    done < "$INTEGRATION_POOL_DIR/queue" || return 1
    if [ "$#" -gt 0 ]; then
        cat "$@" >> "$TYPELISP_CI_TIMING_FILE" || return 1
    fi
}

# Compile every chunk queued in QUEUE (`batch-<group>-<index>|<cap MiB>` rows)
# in the bounded pool, then settle them in queue order. The pool proves one
# successful job per queued chunk; a chunk whose compiler failed is still a
# successful job, and settling sends its entries to the standalone replay.
integration_batch_run_pool() {
    _pool_queue=$1
    INTEGRATION_POOL_DIR="$WORKDIR/batch-pool"
    bounded_pool_init "$INTEGRATION_POOL_DIR" "$INTEGRATION_POOL_BUDGET_MIB" \
        "$_pool_queue" || exit 1
    mkdir -p "$INTEGRATION_POOL_DIR/timing" || return 1
    _pool_count=$(wc -l < "$_pool_queue") || return 1
    echo "[integration] batch pool: $_pool_count chunk(s)," \
        "$INTEGRATION_POOL_WORKERS worker(s)," \
        "$INTEGRATION_POOL_BUDGET_MIB MiB of enforced caps at once"
    ci_timing_set_now_ms || return 1
    _pool_started=$CI_TIMING_NOW_MS
    bounded_pool_start "$INTEGRATION_POOL_DIR" "$INTEGRATION_POOL_WORKERS" || return 1
    if ! bounded_pool_join "$INTEGRATION_POOL_DIR"; then
        integration_batch_merge_pool_timing available
        echo "FAIL: integration batch pool did not complete every chunk" >&2
        exit 1
    fi
    ci_timing_set_now_ms || return 1
    INTEGRATION_POOL_WALL_MS=$((INTEGRATION_POOL_WALL_MS + CI_TIMING_NOW_MS - _pool_started))
    _pool_settle_started=$CI_TIMING_NOW_MS
    integration_batch_merge_pool_timing required || return 1
    if ci_timing_enabled; then
        ci_timing_record_elapsed manifest batch-pool \
            "$((_pool_settle_started - _pool_started))" 0 || return 1
    fi
    _pool_win_plans="$WORKDIR/batch-pool.windows-plans"
    : > "$_pool_win_plans" || return 1
    INTEGRATION_BATCH_DEFER_WINDOWS_PLAN=1
    while IFS='|' read -r _pool_job _pool_cap; do
        [ "$INTEGRATION_POOL_ENFORCE_CAPS" -eq 1 ] || _pool_cap=
        integration_batch_settle_chunk "$WORKDIR/$_pool_job.list" \
            "${_pool_job#batch-}" "$_pool_cap" || {
            INTEGRATION_BATCH_DEFER_WINDOWS_PLAN=0
            return 1
        }
    done < "$_pool_queue" || {
        INTEGRATION_BATCH_DEFER_WINDOWS_PLAN=0
        return 1
    }
    INTEGRATION_BATCH_DEFER_WINDOWS_PLAN=0
    if [ "$HOST_OS" = windows ] && [ -s "$_pool_win_plans" ]; then
        integration_windows_register_plans_batch "$_pool_win_plans" || return 1
    fi
    if ci_timing_enabled; then
        ci_timing_set_now_ms || return 1
        ci_timing_record_elapsed manifest batch-settle \
            "$((CI_TIMING_NOW_MS - _pool_settle_started))" 0
    fi
}

integration_batch_sentinel_entry() {
    sed -n '$p' "$1"
}

WINDOWS_RUNNER_WIN=
WINDOWS_LEGACY_RUNNER_WIN=
WINDOWS_LINKER_WIN=
WINDOWS_LLD_LINK_WIN=
WINDOWS_CLANG_WIN=
WINDOWS_WORKDIR_WIN=
WINDOWS_CHECKOUT_ROOT_NATIVE=
WINDOWS_ASSEMBLE_REQUEST=
WINDOWS_ASSEMBLE_REQUEST_WIN=
WINDOWS_ASSEMBLE_RESULTS=
WINDOWS_ASSEMBLE_RESULTS_WIN=
WINDOWS_ASSEMBLE_SUMMARY=
WINDOWS_ASSEMBLE_SUMMARY_WIN=
WINDOWS_ASSEMBLE_RUNNER_STDOUT=
WINDOWS_ASSEMBLE_RUNNER_STDERR=
WINDOWS_ASSEMBLE_CASES=
WINDOWS_LINK_REQUEST=
WINDOWS_LINK_REQUEST_WIN=
WINDOWS_LINK_RESULTS=
WINDOWS_LINK_RESULTS_WIN=
WINDOWS_LINK_SUMMARY=
WINDOWS_LINK_SUMMARY_WIN=
WINDOWS_LINK_RUNNER_STDOUT=
WINDOWS_LINK_RUNNER_STDERR=
WINDOWS_LINK_CASES=
WINDOWS_QUEUE=
WINDOWS_QUEUE_WIN=
WINDOWS_RESULTS=
WINDOWS_RESULTS_WIN=
WINDOWS_ASSERTIONS=
WINDOWS_ASSERTIONS_WIN=
WINDOWS_SUMMARY=
WINDOWS_SUMMARY_WIN=
WINDOWS_RUNNER_STDOUT=
WINDOWS_RUNNER_STDERR=
WINDOWS_QUEUED_CASES=
WINDOWS_COFF_ARTIFACTS=
WINDOWS_COFF_FALLBACK_REASONS=
WINDOWS_ASSEMBLE_REQUESTS=0
WINDOWS_LINK_REQUESTS=0
WINDOWS_MANIFEST_QUEUED=0
WINDOWS_QUEUE_REQUESTS=0
WINDOWS_MANIFEST_COMPILE_MS=0
WINDOWS_MANIFEST_BATCH_COMPILE_MS=0
WINDOWS_MANIFEST_PLAN_PROCESS_MS=0
WINDOWS_MANIFEST_ASSEMBLE_MS=0
WINDOWS_MANIFEST_ASSEMBLE_WALL_MS=0
WINDOWS_MANIFEST_ASSEMBLE_HELPER_MS=0
WINDOWS_MANIFEST_FALLBACK_ASSEMBLE_MS=0
WINDOWS_MANIFEST_FORCED_ASSEMBLE_MS=0
WINDOWS_MANIFEST_STANDALONE_ASSEMBLE_MS=0
WINDOWS_MANIFEST_LINK_MS=0
WINDOWS_MANIFEST_LINK_WALL_MS=0
WINDOWS_MANIFEST_LINK_HELPER_MS=0
WINDOWS_MANIFEST_LINK_PREP_MS=0
WINDOWS_MANIFEST_LINK_RESULT_PROCESS_MS=0
WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS=0
WINDOWS_MANIFEST_RUN_MS=0
WINDOWS_MANIFEST_RESULT_PROCESS_MS=0
WINDOWS_MANIFEST_ASSERT_MS=0
WINDOWS_MANIFEST_ASSERT_REPORT_MS=0
WINDOWS_MANIFEST_COMPILES=0
WINDOWS_MANIFEST_BATCH_COMPILES=0
WINDOWS_MANIFEST_PLAN_ROWS=0
WINDOWS_MANIFEST_DIRECT_OBJECTS=0
WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES=0
WINDOWS_MANIFEST_FORCED_ASSEMBLIES=0
WINDOWS_MANIFEST_ASSEMBLES=0
WINDOWS_MANIFEST_CDEP_ASSEMBLES=0
WINDOWS_MANIFEST_LINKS=0
WINDOWS_MANIFEST_ASSERTS=0
WINDOWS_ASSEMBLE_POWERSHELL_STARTS=0
WINDOWS_LINK_POWERSHELL_STARTS=0
WINDOWS_MANIFEST_POWERSHELL_STARTS=0
WINDOWS_MANIFEST_CYGPATH_CONVERSIONS=0
WINDOWS_DIRECT_POWERSHELL_STARTS=0
WINDOWS_DIRECT_CYGPATH_CONVERSIONS=0
WINDOWS_DIFFERENTIAL_POWERSHELL_STARTS=0
WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS=0
# Eight link/assemble jobs matches the faster median for the Windows COFF
# toolchain queue. Four runner jobs parallelizes independent `.exe` execution
# (LPT order, with serial/lock-group isolation for self-tests and shared paths).
WINDOWS_LINK_JOBS=${TYPELISP_WINDOWS_LINK_JOBS:-8}
WINDOWS_ASSEMBLE_JOBS=${TYPELISP_WINDOWS_ASSEMBLE_JOBS:-$WINDOWS_LINK_JOBS}
WINDOWS_RUNNER_JOBS=${TYPELISP_WINDOWS_RUNNER_JOBS:-4}

if [ "$HOST_OS" = windows ] && [ "$SELF_TEST_WITHOUT_COMPILER" -eq 0 ]; then
    for _win_jobs_pair in \
        "TYPELISP_WINDOWS_LINK_JOBS:$WINDOWS_LINK_JOBS" \
        "TYPELISP_WINDOWS_ASSEMBLE_JOBS:$WINDOWS_ASSEMBLE_JOBS" \
        "TYPELISP_WINDOWS_RUNNER_JOBS:$WINDOWS_RUNNER_JOBS"; do
        _win_jobs_var=${_win_jobs_pair%%:*}
        _win_jobs_val=${_win_jobs_pair#*:}
        case "$_win_jobs_val" in
            "" | *[!0-9]* | 0)
                echo "$_win_jobs_var must be an integer from 1 to 64" >&2
                exit 2
                ;;
        esac
        if [ "$_win_jobs_val" -gt 64 ]; then
            echo "$_win_jobs_var must be an integer from 1 to 64" >&2
            exit 2
        fi
    done
    WINDOWS_RUNNER_WIN=$(cygpath -aw "$ROOT/scripts/windows-integration-runner.ps1")
    WINDOWS_LEGACY_RUNNER_WIN=$(cygpath -aw "$ROOT/scripts/windows-integration-legacy-runner.ps1")
    WINDOWS_LINKER_WIN=$(cygpath -aw "$ROOT/scripts/windows-integration-linker.ps1")
    WINDOWS_LLD_LINK_WIN=$(cygpath -aw "$(command -v lld-link)")
    WINDOWS_CLANG_WIN=$(cygpath -aw "$(command -v clang)")
    WINDOWS_WORKDIR_WIN=$(cygpath -aw "$WORKDIR")
    WINDOWS_CHECKOUT_ROOT_NATIVE=$(cygpath -am "$ROOT")
    WINDOWS_ASSEMBLE_REQUEST="$WORKDIR/windows-integration-assemble.requests"
    WINDOWS_ASSEMBLE_REQUEST_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration-assemble.requests"
    WINDOWS_ASSEMBLE_RESULTS="$WORKDIR/windows-integration-assemble.results"
    WINDOWS_ASSEMBLE_RESULTS_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration-assemble.results"
    WINDOWS_ASSEMBLE_SUMMARY="$WORKDIR/windows-integration-assemble.summary"
    WINDOWS_ASSEMBLE_SUMMARY_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration-assemble.summary"
    WINDOWS_ASSEMBLE_RUNNER_STDOUT="$WORKDIR/windows-integration-assembler.stdout"
    WINDOWS_ASSEMBLE_RUNNER_STDERR="$WORKDIR/windows-integration-assembler.stderr"
    WINDOWS_ASSEMBLE_CASES="$WORKDIR/windows-integration-assemble.cases"
    WINDOWS_LINK_REQUEST="$WORKDIR/windows-integration-links.requests"
    WINDOWS_LINK_REQUEST_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration-links.requests"
    WINDOWS_LINK_RESULTS="$WORKDIR/windows-integration-links.results"
    WINDOWS_LINK_RESULTS_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration-links.results"
    WINDOWS_LINK_SUMMARY="$WORKDIR/windows-integration-links.summary"
    WINDOWS_LINK_SUMMARY_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration-links.summary"
    WINDOWS_LINK_RUNNER_STDOUT="$WORKDIR/windows-integration-linker.stdout"
    WINDOWS_LINK_RUNNER_STDERR="$WORKDIR/windows-integration-linker.stderr"
    WINDOWS_LINK_CASES="$WORKDIR/windows-integration-links.cases"
    WINDOWS_QUEUE="$WORKDIR/windows-integration.requests"
    WINDOWS_QUEUE_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration.requests"
    WINDOWS_RESULTS="$WORKDIR/windows-integration.results"
    WINDOWS_RESULTS_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration.results"
    WINDOWS_ASSERTIONS="$WORKDIR/windows-integration.assertions"
    WINDOWS_ASSERTIONS_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration.assertions"
    WINDOWS_SUMMARY="$WORKDIR/windows-integration.summary"
    WINDOWS_SUMMARY_WIN="$WINDOWS_WORKDIR_WIN\\windows-integration.summary"
    WINDOWS_RUNNER_STDOUT="$WORKDIR/windows-integration-runner.stdout"
    WINDOWS_RUNNER_STDERR="$WORKDIR/windows-integration-runner.stderr"
    WINDOWS_QUEUED_CASES="$WORKDIR/windows-integration.queued"
    WINDOWS_COFF_ARTIFACTS="$WORKDIR/windows-coff.artifacts"
    WINDOWS_COFF_FALLBACK_REASONS="$WORKDIR/windows-coff-fallback-reasons.txt"
    printf 'tlwinlink1\000' > "$WINDOWS_ASSEMBLE_REQUEST"
    : > "$WINDOWS_ASSEMBLE_CASES"
    printf 'tlwinlink1\000' > "$WINDOWS_LINK_REQUEST"
    : > "$WINDOWS_LINK_CASES"
    printf 'tlwinq4\000' > "$WINDOWS_QUEUE"
    : > "$WINDOWS_QUEUED_CASES"
    : > "$WINDOWS_COFF_ARTIFACTS"
    : > "$WINDOWS_COFF_FALLBACK_REASONS"
    # The two queue helpers, lld-link, clang, their common work root, and the
    # sysroot stdlib archive are the only manifest path conversions. Per-case
    # inputs/outputs are constructed from validated case names below.
    WINDOWS_MANIFEST_CYGPATH_CONVERSIONS=5
    stdlib_archive_resolve_triple x86_64-pc-windows-msvc "${COMPILER:-}"
    WINDOWS_STDLIB_ARCHIVE_WIN=""
    if [ -n "$STDLIB_ARCHIVE_PATH" ]; then
        WINDOWS_STDLIB_ARCHIVE_WIN=$(cygpath -aw "$STDLIB_ARCHIVE_PATH")
        WINDOWS_MANIFEST_CYGPATH_CONVERSIONS=6
    fi
    WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS=1
fi

# Validate and register Windows COFF plan files for one or more passing batch
# chunks in a single awk invocation via scripts/validate-windows-coff-plan.awk
# (avoiding per-chunk awk forks and per-case NTFS marker files). Each input line
# in PLAN_LIST is:
#   batch_list_path|plan_path|chunk_label
integration_windows_register_plans_batch() {
    _win_plans_list=$1
    [ -s "$_win_plans_list" ] || return 0
    ci_timing_set_now_ms || return 1
    _windows_plan_started=$CI_TIMING_NOW_MS
    _win_forced_list=$(windows_manifest_assembly_assertion_cases | tr '\n' ' ')
    _win_artifacts_file=${WINDOWS_COFF_ARTIFACTS:-$WORKDIR/windows-coff.artifacts}
    _win_reasons_file=${WINDOWS_COFF_FALLBACK_REASONS:-$WORKDIR/windows-coff-fallback-reasons.txt}
    _win_counts_file="$WORKDIR/windows-coff-register.counts"
    if ! awk -f "$ROOT/scripts/validate-windows-coff-plan.awk" \
        -v multi=1 \
        -v root="$ROOT" \
        -v expected_prefix="target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX/" \
        -v forced_list="$_win_forced_list" \
        -v artifacts_out="$_win_artifacts_file" \
        -v reasons_out="$_win_reasons_file" \
        -v counts_out="$_win_counts_file" \
        "$_win_plans_list"; then
        return 1
    fi

    IFS='|' read -r _reg_rows _reg_direct _reg_fallback _reg_forced < "$_win_counts_file" || return 1
    WINDOWS_MANIFEST_PLAN_ROWS=$((WINDOWS_MANIFEST_PLAN_ROWS + _reg_rows))
    WINDOWS_MANIFEST_DIRECT_OBJECTS=$((WINDOWS_MANIFEST_DIRECT_OBJECTS + _reg_direct))
    WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES=$((WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES + _reg_fallback))
    WINDOWS_MANIFEST_FORCED_ASSEMBLIES=$((WINDOWS_MANIFEST_FORCED_ASSEMBLIES + _reg_forced))

    ci_timing_set_now_ms || return 1
    _windows_plan_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_PLAN_PROCESS_MS=$((
        WINDOWS_MANIFEST_PLAN_PROCESS_MS +
        _windows_plan_finished -
        _windows_plan_started
    ))
}

integration_windows_register_plan() {
    _windows_plan_batch=$1
    _windows_plan_result=$2
    _windows_plan_label=$3
    _windows_plan_single="$WORKDIR/batch-$_windows_plan_label.single-plan"
    printf '%s|%s|%s\n' "$_windows_plan_batch" "$_windows_plan_result" "$_windows_plan_label" \
        > "$_windows_plan_single" || return 1
    integration_windows_register_plans_batch "$_windows_plan_single"
}

deps_or_empty() {
    case "$1" in
        "" | -) ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Fixture staging is planned, then executed by one native helper (#8395). The
# path rules below append `source<TAB>destination` lines, relative to ROOT
# (the working directory), to $STAGE_PLAN instead of forking mkdir/cp and
# command substitutions per file; tools/integration-staging/stage.tl then
# creates the directories and writes the files in plan order. Relative paths
# need no host translation, so Windows converts no path per file.
STAGE_TAB=$(printf '\t')
STAGE_NL='
'

stage_plan_path() {
    case "$1" in
        *"$STAGE_TAB"* | *"$STAGE_NL"*)
            echo "integration staging path contains a tab or newline: $1" >&2
            return 1
            ;;
        "$ROOT"/*) STAGE_PLAN_PATH=${1#"$ROOT"/} ;;
        *)
            echo "integration staging path is outside the repository root: $1" >&2
            return 1
            ;;
    esac
}

stage_plan_copy() {
    stage_plan_path "$1" || return 1
    _plan_source=$STAGE_PLAN_PATH
    stage_plan_path "$2" || return 1
    printf '%s\t%s\n' "$_plan_source" "$STAGE_PLAN_PATH" >> "$STAGE_PLAN"
}

. "$ROOT/scripts/lib-integration-deps.sh"

compile_linux_c_deps() {
    _deps=$1
    _case_dir=$2
    _build_stdout=$3
    _build_stderr=$4
    _objs=

    for _dep in $(deps_or_empty "$_deps"); do
        case "$_dep" in
            *.c)
                if ! command -v cc >/dev/null 2>&1; then
                    echo "missing C compiler: cc" >> "$_build_stderr"
                    return 1
                fi
                _base=$(basename -- "$_dep" .c)
                _src="$_case_dir/$_dep"
                _obj="$_case_dir/$_base.native.o"
                if ! cc -std=c99 -Wall -Wextra -c "$_src" -o "$_obj" \
                    >> "$_build_stdout" 2>> "$_build_stderr"; then
                    return 1
                fi
                _objs="${_objs:+$_objs }$_obj"
                ;;
        esac
    done

    printf '%s\n' "$_objs"
}

# Linux rooted-filesystem fixtures are owned by verify-fs-rooted-linux.sh.
# That gate supplies the descriptor-relative test root, fault hooks, and the
# native assembler/linker flow that these fixtures require; on Windows the
# rooted Linux API and its openat2 boundary are intentionally not applicable.
fs_rooted_linux_gate_cases() {
    cat <<'EOF'
fs_rooted_linux_direct
fs_rooted_linux_native
fs_rooted_linux_publication
fs_rooted_linux_reopen_directory
fs_rooted_linux_read_into
fs_rooted_linux_read_reuse
fs_rooted_linux_source
fs_rooted_linux_guard
EOF
}

# Linux process fault-injection fixtures are owned by
# verify-process-runtime-linux.sh. That gate supplies the current-tree
# `process-linux-test-hooks` cfg and checks the exact syscall failure matrix;
# on Windows the Linux syscall boundary is intentionally not applicable.
process_runtime_linux_gate_cases() {
    cat <<'EOF'
process_runtime_linux_failures
process_runtime_linux_hooks
EOF
}

# Cases covered by the selfhost-native generated-program gate rather than the
# seed-backed integration manifests.
# Immutable-reference native smoke fixtures are covered by
# verify-native-link-linux.sh until the published stage0 includes #1720.
# embedded_stdlib_diagnostic_parity is an expected-failure input compared in
# both source-root and no-root modes by verify-stage0-smoke.sh.
selfhost_native_manifest_cases() {
    cat <<'EOF'
embedded_stdlib_diagnostic_parity
ref_fixed_array_return
ref_param_identity
ref_return
ref_tuple_return
EOF
}

# This partial-gang fixture intentionally has selectors that are valid only
# within an AVX2/AVX-512 gang. The scalar backend has one active lane and must
# reject selectors 1 and 2, so verify-spmd-simd.sh owns its SIMD-only run.
spmd_simd_manifest_cases() {
    cat <<'EOF'
spmd_shuffle_tail_selector
EOF
}

# This compiler-only debug fixture needs the current-tree
# `compiler-arena-debug` cfg plus multiple expected exits and stderr streams.
# The seed-backed integration manifest cannot express that matrix; the runtime
# emitter tests cover both targets; verify-compiler-arena-debug.sh runs this
# native matrix on each host in CI.
compiler_cfg_native_fixture_cases() {
    cat <<'EOF'
compiler_arena_debug
EOF
}

# The Windows no-libc gate owns these fixtures. It runs the shadow-identity
# program with a preloaded application-directory DLL and records the timing
# program's output; neither setup fits the seed-backed integration manifest.
# On Linux the Windows loader and Winsock boundary are not applicable.
winsock_no_libc_gate_cases() {
    cat <<'EOF'
winsock_capability_measure
winsock_shadow_identity
EOF
}

# Windows COFF-plan rows use forced assembly only when an integration assertion
# needs to inspect the textual backend artifact. Keep the human-readable reason
# beside the classification so summary output explains every intentional clang
# assembler launch.
windows_manifest_assembly_requirement_rows() {
    cat <<'EOF'
stdlib_string|stdlib-helper-symbol-elision
string_eq|stdlib-helper-symbol-elision
u64_float_casts|u64-float-cast-instruction-shape
EOF
}

# This list is deliberately independent of the plan classification above. The
# validator compares the two sets so adding or deleting an assembly assertion
# cannot silently leave a stale force-assembly exemption.
windows_manifest_assembly_assertion_cases() {
    cat <<'EOF'
stdlib_string
string_eq
u64_float_casts
EOF
}

windows_manifest_assembly_reason() {
    case "$1" in
        stdlib_string | string_eq)
            printf '%s\n' stdlib-helper-symbol-elision
            ;;
        u64_float_casts)
            printf '%s\n' u64-float-cast-instruction-shape
            ;;
        *)
            return 1
            ;;
    esac
}

validate_windows_manifest_assembly_requirements() {
    _requirements="$WORKDIR/windows-assembly-requirements.txt"
    _assertions="$WORKDIR/windows-assembly-assertions.txt"
    windows_manifest_assembly_requirement_rows > "$_requirements"
    windows_manifest_assembly_assertion_cases > "$_assertions"
    awk -F '|' \
        -v requirements_file="$_requirements" \
        -v assertions_file="$_assertions" '
        function report(message) {
            print message > "/dev/stderr"
            failed = 1
        }
        FILENAME == requirements_file {
            if (NF != 2 || $1 !~ /^[A-Za-z0-9_]+$/ || $2 !~ /^[a-z0-9-]+$/) {
                report("invalid Windows assembly requirement row: " $0)
            } else if (requirement[$1] != "") {
                report("duplicate Windows assembly requirement: " $1)
            } else {
                requirement[$1] = $2
            }
            next
        }
        FILENAME == assertions_file {
            if (NF != 1 || $1 !~ /^[A-Za-z0-9_]+$/) {
                report("invalid Windows assembly assertion row: " $0)
            } else if (assertion[$1]++) {
                report("duplicate Windows assembly assertion: " $1)
            }
            next
        }
        {
            if ($0 != "" && $0 !~ /^#/) manifest_case[$1]++
        }
        END {
            for (name in requirement) {
                if (!assertion[name]) {
                    report("Windows assembly requirement has no text assertion: " name)
                }
                if (manifest_case[name] != 1) {
                    report("Windows assembly requirement is stale or ambiguous in the manifest: " name)
                }
            }
            for (name in assertion) {
                if (requirement[name] == "") {
                    report("Windows assembly text assertion lacks a force-assembly reason: " name)
                }
            }
            exit failed
        }
    ' "$_requirements" "$_assertions" "$HOST_MANIFEST"
}

validate_manifest() {
    _known="$WORKDIR/manifest-known.txt"
    _known_sorted="$WORKDIR/manifest-known.sorted"
    _actual="$WORKDIR/integration-sources.txt"
    _catalog="$WORKDIR/repository-files.txt"
    : > "$_known" || return 1

    find benchmarks examples src stdlib tests/fixtures tests/integration tests/safety -type f -print \
        > "$_catalog" || return 1
    awk -v root="$ROOT" -v catalog="$_catalog" -v known_out="$_known" \
        -f "$ROOT/scripts/validate-integration-manifest.awk" \
        "$_catalog" "$HOST_MANIFEST" || return 1
    # The other host's rows are validated too and cover their own sources.
    _other_host=windows
    [ "$HOST_OS" = linux ] || _other_host=linux
    awk -v host="$_other_host" -v work_root="target/integration-verify/$_other_host" \
        -f "$ROOT/scripts/expand-integration-manifest.awk" \
        "$COMBINED_MANIFEST" > "$WORKDIR/manifest.$_other_host" || return 1
    awk -v root="$ROOT" -v catalog="$_catalog" -v known_out="$_known.$_other_host" \
        -f "$ROOT/scripts/validate-integration-manifest.awk" \
        "$_catalog" "$WORKDIR/manifest.$_other_host" || return 1
    cat "$_known.$_other_host" >> "$_known" || return 1

    if [ "$HOST_OS" = windows ]; then
        validate_windows_manifest_assembly_requirements || return 1
    fi
    fs_rooted_linux_gate_cases >> "$_known" || return 1
    process_runtime_linux_gate_cases >> "$_known" || return 1
    selfhost_native_manifest_cases >> "$_known" || return 1
    spmd_simd_manifest_cases >> "$_known" || return 1
    compiler_cfg_native_fixture_cases >> "$_known" || return 1
    winsock_no_libc_gate_cases >> "$_known" || return 1

    find tests/integration -type f -name '*.tl' > "$_actual.paths" || return 1
    sed 's#^tests/integration/##; s#\.tl$##' "$_actual.paths" > "$_actual.names" || return 1
    sort "$_actual.names" > "$_actual" || return 1
    sort -u "$_known" > "$_known_sorted" || return 1
    if ! cmp -s "$_actual" "$_known_sorted"; then
        echo "integration manifest is out of date for $HOST_OS" >&2
        echo "every tests/integration/**/*.tl file must be a manifest case, dependency, or documented host exception" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_known_sorted" "$_actual" >&2 || true
        fi
        exit 1
    fi
}

write_expected_stream() {
    _spec=$1
    case "$_spec" in
        *'@loc{'*) _spec=$(resolve_source_locations "$_spec") || exit 1 ;;
    esac
    _out=$2
    case "$_spec" in
        "" | -)
            : > "$_out"
            ;;
        @*)
            _expected="$ROOT/${_spec#@}"
            if [ ! -f "$_expected" ]; then
                echo "missing expected stream file: ${_spec#@}" >&2
                exit 1
            fi
            cp "$_expected" "$_out"
            ;;
        *)
            printf '%b' "$_spec" > "$_out"
            ;;
    esac
}

integration_escape_sed_bre() {
    printf '%s' "$1" | sed 's/[][\\.^$*]/\\&/g; s/#/\\#/g'
}

normalize_windows_stream() {
    _in=$1
    _out=$2
    _root_native=$3
    _root_forward=$(printf '%s' "$_root_native" | tr '\\' '/')
    case "$_root_forward" in
        [A-Za-z]:/*) ;;
        *)
            echo "invalid native Windows checkout root: $_root_native" >&2
            return 1
            ;;
    esac
    case "$_root_forward" in
        */) _root_forward=${_root_forward%/} ;;
    esac

    _drive=$(printf '%.1s' "$_root_forward")
    _drive_lower=$(printf '%s' "$_drive" | tr '[:upper:]' '[:lower:]')
    _drive_upper=$(printf '%s' "$_drive" | tr '[:lower:]' '[:upper:]')
    _forward_tail=${_root_forward#?}
    _root_backward=$(printf '%s' "$_root_forward" | tr '/' '\\')
    _backward_tail=${_root_backward#?}
    _forward_pattern=$(integration_escape_sed_bre "$_forward_tail")
    _backward_pattern=$(integration_escape_sed_bre "$_backward_tail")

    # Runtime source diagnostics begin with `tl: <path>`. Match only that path
    # position and require a separator after the literal checkout root, so a
    # message mentioning the checkout, an external absolute path, or a sibling
    # such as `TypeLisp-other` remains byte-for-byte unchanged. The suffix is
    # deliberately not rewritten: only the runner-owned absolute prefix is
    # normalized away.
    tr -d '\r' < "$_in" |
        sed \
            -e "s#^tl: [${_drive_lower}${_drive_upper}]${_forward_pattern}[/\\\\]#tl: #" \
            -e "s#^tl: [${_drive_lower}${_drive_upper}]${_backward_pattern}[/\\\\]#tl: #" \
            > "$_out"
}

normalized_stream() {
    _in=$1
    _out=$2
    if [ "$HOST_OS" = windows ]; then
        normalize_windows_stream "$_in" "$_out" "$WINDOWS_CHECKOUT_ROOT_NATIVE"
    else
        cp "$_in" "$_out"
    fi
}

windows_queue_decode() {
    case "$1" in
        "~") printf '%s' "" ;;
        *) printf '%s' "$1" | base64 -d ;;
    esac
}

# Append one native-path request to the NUL-delimited UTF-8 queue (`tlwinq4`).
# NUL cannot occur in a Windows path or process argument, so this preserves the
# already split argument vector without launching per-field base64/tr helpers.
windows_queue_append_request() {
    _queue=$1
    _label=$2
    _exe=$3
    _stdout=$4
    _stderr=$5
    _code=$6
    _expected_exit=$7
    _expected_stdout=$8
    _expected_stderr=$9
    shift 9
    _lock_group=$1
    shift 1
    if [ ! -s "$_queue" ]; then
        printf 'tlwinq4\000' > "$_queue"
    fi
    printf '%s\000' \
        "$_label" \
        "$_exe" \
        "$_stdout" \
        "$_stderr" \
        "$_code" \
        "$INTEGRATION_CASE_TIMEOUT_SECONDS" \
        "$_expected_exit" \
        "$_expected_stdout" \
        "$_expected_stderr" \
        "$_lock_group" \
        "$#" \
        "$@" >> "$_queue"
}

windows_result_for_label() {
    _wanted_label=$1
    _result_line=$(awk -F '\t' -v label="$_wanted_label" '$1 == label { print; exit }' "$WINDOWS_RESULTS")
    if [ -z "$_result_line" ]; then
        return 1
    fi
    IFS="$(printf '\t')" read -r _result_label _result_status _result_exit _result_error _result_ms <<EOF
$_result_line
EOF
    if [ "$_result_label" != "$_wanted_label" ]; then
        return 1
    fi
    WINDOWS_RESULT_STATUS=$_result_status
    WINDOWS_RESULT_EXIT=$_result_exit
    WINDOWS_RESULT_ERROR=$(windows_queue_decode "$_result_error")
    WINDOWS_RESULT_MS=$_result_ms
}

windows_run_request_file() {
    _request_win=$1
    _result_win=$2
    _assertion_win=$3
    _summary_win=$4
    _runner_stdout=$5
    _runner_stderr=$6
    _runner_jobs=${7:-1}
    ci_timing_set_now_ms
    _started=$CI_TIMING_NOW_MS
    set +e
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_RUNNER_WIN" \
        -RequestPath "$_request_win" \
        -ResultPath "$_result_win" \
        -AssertionPath "$_assertion_win" \
        -SummaryPath "$_summary_win" \
        -Jobs "$_runner_jobs" \
        > "$_runner_stdout" 2> "$_runner_stderr"
    WINDOWS_RUNNER_STATUS=$?
    set -e
    ci_timing_set_now_ms
    _finished=$CI_TIMING_NOW_MS
    WINDOWS_LAST_RUN_MS=$((_finished - _started))
    return "$WINDOWS_RUNNER_STATUS"
}

windows_timed_compile() {
    ci_timing_set_now_ms
    _started=$CI_TIMING_NOW_MS
    run_build "$@"
    ci_timing_set_now_ms
    _finished=$CI_TIMING_NOW_MS
    _elapsed=$((_finished - _started))
    WINDOWS_MANIFEST_COMPILE_MS=$((WINDOWS_MANIFEST_COMPILE_MS + _elapsed))
    WINDOWS_MANIFEST_COMPILES=$((WINDOWS_MANIFEST_COMPILES + 1))
    ci_timing_record_elapsed "$name" compile "$_elapsed" "$build_rc"
}

# Generated backend fixtures stay outside the manifest queue because they need
# their outputs between steps. They still use the same capture implementation,
# but only incur a one-request runner launch per fixture rather than reviving a
# separate one-shot PowerShell script.
run_windows_program() {
    _exe_posix=$1
    _stdout_posix=$2
    _stderr_posix=$3
    _code_posix=$4
    _expected_code=$5
    shift 5
    WINDOWS_DIRECT_POWERSHELL_STARTS=$((WINDOWS_DIRECT_POWERSHELL_STARTS + 1))
    _direct_id=$WINDOWS_DIRECT_POWERSHELL_STARTS
    _direct_queue="$WORKDIR/windows-direct-$_direct_id.requests"
    _direct_results="$WORKDIR/windows-direct-$_direct_id.results"
    _direct_assertions="$WORKDIR/windows-direct-$_direct_id.assertions"
    _direct_summary="$WORKDIR/windows-direct-$_direct_id.summary"
    _direct_stdout="$WORKDIR/windows-direct-$_direct_id.runner.stdout"
    _direct_stderr="$WORKDIR/windows-direct-$_direct_id.runner.stderr"
    _direct_queue_win=$(cygpath -aw "$_direct_queue")
    _direct_results_win=$(cygpath -aw "$_direct_results")
    _direct_assertions_win=$(cygpath -aw "$_direct_assertions")
    _direct_summary_win=$(cygpath -aw "$_direct_summary")
    _exe_win=$(cygpath -aw "$_exe_posix")
    _stdout_win=$(cygpath -aw "$_stdout_posix")
    _stderr_win=$(cygpath -aw "$_stderr_posix")
    _code_win=$(cygpath -aw "$_code_posix")
    WINDOWS_DIRECT_CYGPATH_CONVERSIONS=$((WINDOWS_DIRECT_CYGPATH_CONVERSIONS + 8))
    windows_queue_append_request "$_direct_queue" "windows_direct_$_direct_id" \
        "$_exe_win" "$_stdout_win" "$_stderr_win" "$_code_win" - - - serial "$@"
    WINDOWS_RESULTS=$_direct_results
    if ! windows_run_request_file \
        "$_direct_queue_win" \
        "$_direct_results_win" \
        "$_direct_assertions_win" \
        "$_direct_summary_win" \
        "$_direct_stdout" \
        "$_direct_stderr" \
        1; then
        echo "Windows direct runner failed:" >&2
        show_stream_if_nonempty stdout "$_direct_stdout"
        show_stream_if_nonempty stderr "$_direct_stderr"
        return 1
    fi
    if ! windows_result_for_label "windows_direct_$_direct_id"; then
        echo "Windows direct runner did not report its request" >&2
        return 1
    fi
    if [ "$WINDOWS_RESULT_STATUS" = timeout ]; then
        report_case_timeout "$_exe_posix" "$WINDOWS_RESULT_ERROR" \
            "$_stdout_posix" "$_stderr_posix"
        return 1
    fi
    if [ "$WINDOWS_RESULT_STATUS" != ok ]; then
        echo "Windows direct runner failed to launch $_exe_posix: $WINDOWS_RESULT_ERROR" >&2
        return 1
    fi
    got=$WINDOWS_RESULT_EXIT
}

assert_contains() {
    _file=$1
    _snippet=$2
    _label=$3
    if ! grep -F "$_snippet" "$_file" >/dev/null 2>&1; then
        echo "FAIL: $_label missing snippet: $_snippet" >&2
        exit 1
    fi
}


assert_not_contains() {
    _file=$1
    _snippet=$2
    _label=$3
    if grep -F "$_snippet" "$_file" >/dev/null 2>&1; then
        echo "FAIL: $_label contained forbidden snippet: $_snippet" >&2
        exit 1
    fi
}

check_u64_float_cast_asm() {
    _asm=$1
    _label="u64_float_casts assembly"
    assert_contains "$_asm" "cast_u64_float_" "$_label"
    assert_contains "$_asm" "cast_float_u64_" "$_label"
    assert_contains "$_asm" "    js " "$_label"
    assert_contains "$_asm" '    andq $1, ' "$_label"
    assert_contains "$_asm" '    shrq $1, ' "$_label"
    assert_contains "$_asm" "    orq " "$_label"
    assert_contains "$_asm" "    addsd " "$_label"
    assert_contains "$_asm" "    addss " "$_label"
    assert_contains "$_asm" "    ucomisd " "$_label"
    assert_contains "$_asm" "    ucomiss " "$_label"
    assert_contains "$_asm" "    subsd " "$_label"
    assert_contains "$_asm" "    subss " "$_label"
    assert_contains "$_asm" '    btsq $63, ' "$_label"
    assert_contains "$_asm" "    movzbl" "$_label"
    if ! awk '
        /u8_to_f64/ { in_u8 = 1 }
        in_u8 && /ret/ { exit bad }
        in_u8 && (/cast_u64_float_/ || /addsd / || /testq / || /andq \$1, / || /shrq \$1, /) { bad = 1 }
        END { exit bad }
    ' "$_asm"; then
        echo "FAIL: $_label used the u64 high-bit path in u8_to_f64" >&2
        exit 1
    fi
}

check_stdlib_string_helpers_asm() {
    _asm=$1
    _label="$2 assembly"
    assert_not_contains "$_asm" ".globl tl_string_eq" "$_label"
    assert_not_contains "$_asm" "call tl_string_eq" "$_label"
    assert_not_contains "$_asm" ".extern tl_string_eq" "$_label"
    assert_not_contains "$_asm" ".globl tl_string_to_int" "$_label"
    assert_not_contains "$_asm" "call tl_string_to_int" "$_label"
    assert_not_contains "$_asm" ".extern tl_string_to_int" "$_label"
    assert_not_contains "$_asm" ".globl tl_hash_string" "$_label"
    assert_not_contains "$_asm" "call tl_hash_string" "$_label"
    assert_not_contains "$_asm" ".extern tl_hash_string" "$_label"
    assert_not_contains "$_asm" ".globl tl_int_to_string" "$_label"
    assert_not_contains "$_asm" "call tl_int_to_string" "$_label"
    assert_not_contains "$_asm" ".extern tl_int_to_string" "$_label"
    assert_not_contains "$_asm" ".globl tl_substring" "$_label"
    assert_not_contains "$_asm" "call tl_substring" "$_label"
    assert_not_contains "$_asm" ".extern tl_substring" "$_label"
}

assert_manifest_assembly_requirements() {
    _assembly_case=$1
    _assembly_path=$2
    case "$_assembly_case" in
        u64_float_casts)
            check_u64_float_cast_asm "$_assembly_path"
            ;;
        stdlib_string | string_eq)
            check_stdlib_string_helpers_asm "$_assembly_path" "$_assembly_case"
            ;;
    esac
}

assert_empty_file() {
    _file=$1
    _label=$2
    if [ -s "$_file" ]; then
        echo "FAIL: $_label expected empty file: $_file" >&2
        sed 's/^/  /' "$_file" >&2 || true
        exit 1
    fi
}

assert_file_text() {
    _file=$1
    _want=$2
    _label=$3
    _actual=$(cat "$_file")
    if [ "$_actual" != "$_want" ]; then
        echo "FAIL: $_label expected file text '$_want', got '$_actual'" >&2
        exit 1
    fi
}

file_size_bytes() {
    _file=$1
    if [ -e "$_file" ]; then
        wc -c < "$_file" | tr -d '[:space:]'
    else
        printf '%s\n' missing
    fi
}

show_stream_if_nonempty() {
    _label=$1
    _file=$2
    if [ -s "$_file" ]; then
        echo "$_label:" >&2
        sed 's/^/  /' "$_file" >&2 || true
    fi
}

show_build_streams() {
    _stdout=$1
    _stderr=$2
    show_stream_if_nonempty stdout "$_stdout"
    show_stream_if_nonempty stderr "$_stderr"
}

show_compile_stream_diagnostic() {
    _label=$1
    _file=$2
    if [ ! -e "$_file" ]; then
        echo "$_label: $_file (missing)" >&2
        return
    fi
    _size=$(file_size_bytes "$_file")
    if [ "$_size" -eq 0 ]; then
        echo "$_label: $_file (empty, 0 bytes)" >&2
    else
        echo "$_label: $_file ($_size bytes):" >&2
        sed 's/^/  /' "$_file" >&2 || true
    fi
}

show_compile_artifact_diagnostic() {
    _label=$1
    _file=$2
    if [ -e "$_file" ]; then
        _size=$(file_size_bytes "$_file")
        echo "$_label: $_file (exists, $_size bytes)" >&2
    else
        echo "$_label: $_file (missing)" >&2
    fi
}

show_compile_failure_diagnostics() {
    _case=$1
    _rc=$2
    _compiler=$3
    _source=$4
    _target=$5
    _stdout=$6
    _stderr=$7
    _asm=$8
    _argv=$9

    echo "compile failure diagnostics:" >&2
    echo "  case: $_case" >&2
    echo "  exit code: $_rc" >&2
    echo "  host: $HOST_OS" >&2
    echo "  target: $_target" >&2
    echo "  compiler: $_compiler" >&2
    echo "  source: $_source" >&2
    echo "  argv: $_compiler $_argv" >&2
    show_compile_stream_diagnostic stdout "$_stdout"
    show_compile_stream_diagnostic stderr "$_stderr"
    show_compile_artifact_diagnostic assembly "$_asm"
}

run_empty_compile_diagnostic_self_test() {
    _dir="$WORKDIR/empty-compile-diagnostic-self-test"
    rm -rf "$_dir"
    mkdir -p "$_dir"
    _stdout="$_dir/case.build.stdout"
    _stderr="$_dir/case.build.stderr"
    _asm="$_dir/case.s"
    _source="$_dir/case.tl"
    _diagnostic="$_dir/diagnostic.txt"

    : > "$_stdout"
    : > "$_stderr"
    : > "$_source"
    rm -f "$_asm"

    show_compile_failure_diagnostics \
        empty_stream_case \
        37 \
        /tmp/fake-typelisp \
        "$_source" \
        linux-x86_64 \
        "$_stdout" \
        "$_stderr" \
        "$_asm" \
        "compile $_source --target linux-x86_64 --stdlib-root $ROOT/stdlib --stdlib-root $ROOT/src -o $_asm" \
        > "$_diagnostic" 2>&1

    assert_contains "$_diagnostic" "compile failure diagnostics:" empty-compile-diagnostic
    assert_contains "$_diagnostic" "case: empty_stream_case" empty-compile-diagnostic
    assert_contains "$_diagnostic" "exit code: 37" empty-compile-diagnostic
    assert_contains "$_diagnostic" "host: $HOST_OS" empty-compile-diagnostic
    assert_contains "$_diagnostic" "target: linux-x86_64" empty-compile-diagnostic
    assert_contains "$_diagnostic" "compiler: /tmp/fake-typelisp" empty-compile-diagnostic
    assert_contains "$_diagnostic" "source: $_source" empty-compile-diagnostic
    assert_contains "$_diagnostic" "argv: /tmp/fake-typelisp compile $_source" empty-compile-diagnostic
    assert_contains "$_diagnostic" "stdout: $_stdout (empty, 0 bytes)" empty-compile-diagnostic
    assert_contains "$_diagnostic" "stderr: $_stderr (empty, 0 bytes)" empty-compile-diagnostic
    assert_contains "$_diagnostic" "assembly: $_asm (missing)" empty-compile-diagnostic

    printf '%s\n' "verify-integration empty compile diagnostic self-test passed"
}

run_signal_notice_capture_self_test() {
    if [ "$HOST_OS" != linux ]; then
        echo "signal notice capture self-test requires Linux" >&2
        exit 1
    fi

    _dir="$WORKDIR/signal-notice-capture-self-test"
    rm -rf "$_dir"
    mkdir -p "$_dir"
    _fixture="$_dir/signal-fixture.sh"
    _attempts="$_dir/attempts.txt"
    _stdout="$_dir/program.stdout"
    _stderr="$_dir/program.stderr"
    _run_shell_stderr="$_dir/run-shell.stderr"
    _synthesized_stderr="$_dir/synthesized.stderr"
    _captured_stderr="$_dir/captured.stderr"
    _ordinary_stderr="$_dir/ordinary.stderr"
    _global_stderr="$_dir/global.stderr"
    _rc_file="$_dir/exit-code.txt"

    cat > "$_fixture" <<'EOF'
#!/bin/sh
printf 'attempt\n' >> "$1"
kill -SEGV "$$"
EOF
    chmod +x "$_fixture"
    : > "$_attempts"

    (
        set +e
        run_linux_manifest_program \
            "$_fixture" "$_stdout" "$_stderr" "$_run_shell_stderr" "$_attempts"
        _rc=$?
        set -e
        printf '%s\n' "$_rc" > "$_rc_file"
    ) 2> "$_global_stderr"

    assert_file_text "$_rc_file" 139 signal-notice-capture
    assert_file_text "$_attempts" attempt signal-notice-capture
    assert_empty_file "$_stdout" signal-notice-capture-program-stdout
    assert_empty_file "$_stderr" signal-notice-capture-program-stderr
    assert_empty_file "$_global_stderr" signal-notice-capture-global-stderr
    if [ ! -s "$_run_shell_stderr" ]; then
        echo "FAIL: signal-notice-capture expected captured shell diagnostics" >&2
        exit 1
    fi

    : > "$_synthesized_stderr"
    ensure_linux_signal_exit_diagnostic 139 "$_synthesized_stderr"
    assert_file_text \
        "$_synthesized_stderr" \
        'program terminated by signal 11 (exit 139); shell emitted no notice' \
        signal-notice-capture-synthesized

    printf '%s\n' 'captured shell notice' > "$_captured_stderr"
    ensure_linux_signal_exit_diagnostic 139 "$_captured_stderr"
    assert_file_text \
        "$_captured_stderr" \
        'captured shell notice' \
        signal-notice-capture-preserved

    : > "$_ordinary_stderr"
    ensure_linux_signal_exit_diagnostic 42 "$_ordinary_stderr"
    assert_empty_file "$_ordinary_stderr" signal-notice-capture-ordinary-exit

    run_case_deadline_self_test "$_dir"

    printf '%s\n' "verify-integration signal notice capture self-test passed"
}

# A sleeping case whose TERM-ignoring child outlives it is stopped at a 1 s
# deadline with its whole process group, fails its own row with its output,
# and the next case still runs and passes.
run_case_deadline_self_test() {
    _deadline_dir="$1/case-deadline"
    mkdir -p "$_deadline_dir/sleeper" "$_deadline_dir/ordinary"
    _sleeper="$_deadline_dir/sleeper.sh"
    _child_pid_file="$_deadline_dir/child.pid"
    _sleeper_stdout="$_deadline_dir/sleeper/sleeper.stdout"
    _sleeper_stderr="$_deadline_dir/sleeper/sleeper.stderr"
    _sleeper_shell="$_deadline_dir/sleeper/sleeper.run-shell.stderr"
    _ordinary="$_deadline_dir/ordinary.sh"
    _ordinary_stdout="$_deadline_dir/ordinary/ordinary.stdout"
    _ordinary_stderr="$_deadline_dir/ordinary/ordinary.stderr"
    _ordinary_shell="$_deadline_dir/ordinary/ordinary.run-shell.stderr"
    _report="$_deadline_dir/report.txt"
    cat > "$_sleeper" <<'EOF'
#!/bin/sh
trap '' TERM
printf 'written before the deadline\n'
printf 'still waiting\n' >&2
sleep 60 &
printf '%s\n' "$!" > "$1"
wait
EOF
    printf '#!/bin/sh\nprintf "ran after the timeout\\n"\nexit 42\n' > "$_ordinary"
    chmod +x "$_sleeper" "$_ordinary"

    INTEGRATION_CASE_TIMEOUT_SECONDS=1
    TYPELISP_CI_TIMING=0
    failed=0
    ran=0
    ci_timing_set_now_ms
    _deadline_started=$CI_TIMING_NOW_MS
    set +e
    run_linux_manifest_program \
        "$_sleeper" "$_sleeper_stdout" "$_sleeper_stderr" "$_sleeper_shell" \
        "$_child_pid_file"
    got=$?
    set -e
    ci_timing_set_now_ms
    _deadline_elapsed=$((CI_TIMING_NOW_MS - _deadline_started))
    if [ "$got" -ne 137 ] || [ "$case_timed_out" -ne 1 ]; then
        echo "FAIL: case-deadline sleeper exited $got (timed out: $case_timed_out); expected a 1 s timeout" >&2
        exit 1
    fi
    if [ "$_deadline_elapsed" -ge 10000 ]; then
        echo "FAIL: case-deadline sleeper took $_deadline_elapsed ms to stop at a 1 s deadline" >&2
        exit 1
    fi
    _child_pid=$(cat "$_child_pid_file")
    _child_polls=0
    # The killed child is reaped by whichever ancestor adopts it; a zombie
    # awaiting that reap is already dead.
    while kill -0 "$_child_pid" 2>/dev/null &&
        ! grep -q '^[0-9]* (.*) Z ' "/proc/$_child_pid/stat" 2>/dev/null; do
        _child_polls=$((_child_polls + 1))
        if [ "$_child_polls" -ge 50 ]; then
            echo "FAIL: case-deadline sleeper child $_child_pid outlived its deadline" >&2
            exit 1
        fi
        sleep 0.1
    done

    assert_manifest_case case_deadline_sleeper 0 - - \
        "$_deadline_dir/sleeper/none.s" "$_sleeper_stdout" "$_sleeper_stderr" \
        "$_deadline_dir/sleeper" "$_sleeper_shell" > "$_deadline_dir/report.stdout" 2> "$_report"
    set +e
    run_linux_manifest_program \
        "$_ordinary" "$_ordinary_stdout" "$_ordinary_stderr" "$_ordinary_shell"
    got=$?
    set -e
    assert_manifest_case case_deadline_ordinary 42 'ran after the timeout\n' - \
        "$_deadline_dir/ordinary/none.s" "$_ordinary_stdout" "$_ordinary_stderr" \
        "$_deadline_dir/ordinary" "$_ordinary_shell" >> "$_deadline_dir/report.stdout" 2>> "$_report"

    if [ "$failed" -ne 1 ] || [ "$ran" -ne 2 ]; then
        echo "FAIL: case-deadline rows settled as $failed failed of $ran; expected 1 of 2" >&2
        cat "$_report" >&2
        exit 1
    fi
    assert_file_text "$_deadline_dir/report.stdout" 'PASS: case_deadline_ordinary' \
        case-deadline-next-case
    for _want_line in \
        'FAIL: case_deadline_sleeper (timeout after 1 s)' \
        '  written before the deadline' \
        '  still waiting'; do
        if ! grep -F -x -q "$_want_line" "$_report"; then
            echo "FAIL: case-deadline report is missing: $_want_line" >&2
            cat "$_report" >&2
            exit 1
        fi
    done
    if grep -q 'expected exit\|mismatch' "$_report"; then
        echo "FAIL: case-deadline report compared a timed-out case's output" >&2
        cat "$_report" >&2
        exit 1
    fi
}

run_path_normalization_self_test() {
    _dir="$WORKDIR/path-normalization-self-test"
    rm -rf "$_dir"
    mkdir -p "$_dir"
    _input="$_dir/input.txt"
    _actual="$_dir/actual.txt"
    _expected="$_dir/expected.txt"
    _linux_actual="$_dir/linux-actual.txt"

    printf '%s\r\n' \
        'tl: C:/Work [Tree]^$/Type.Lisp#1/target/case.tl:4:4: panic: boom' \
        'tl: c:\Work [Tree]^$\Type.Lisp#1\target\case.tl:5:6: panic: slash' \
        'tl: D:/external/case.tl:1:2: panic: external' \
        'note: C:/Work [Tree]^$/Type.Lisp#1/target/message.txt' \
        'tl: C:/Work [Tree]^$/Type.Lisp#1-other/target/case.tl:7:8: panic: boundary' \
        > "$_input"
    printf '%s' 'tail: C:/Work [Tree]^$/Type.Lisp#1/target/no-newline.tl' >> "$_input"
    printf '%s\n' \
        'tl: target/case.tl:4:4: panic: boom' \
        'tl: target\case.tl:5:6: panic: slash' \
        'tl: D:/external/case.tl:1:2: panic: external' \
        'note: C:/Work [Tree]^$/Type.Lisp#1/target/message.txt' \
        'tl: C:/Work [Tree]^$/Type.Lisp#1-other/target/case.tl:7:8: panic: boundary' \
        > "$_expected"
    printf '%s' 'tail: C:/Work [Tree]^$/Type.Lisp#1/target/no-newline.tl' >> "$_expected"

    HOST_OS=windows
    WINDOWS_CHECKOUT_ROOT_NATIVE='C:/Work [Tree]^$/Type.Lisp#1'
    normalized_stream "$_input" "$_actual"
    if ! cmp -s "$_expected" "$_actual"; then
        echo "FAIL: Windows integration path normalization changed the wrong bytes" >&2
        diff -u "$_expected" "$_actual" >&2 || true
        exit 1
    fi
    HOST_OS=linux
    normalized_stream "$_input" "$_linux_actual"
    if ! cmp -s "$_input" "$_linux_actual"; then
        echo "FAIL: Linux integration stream normalization changed bytes" >&2
        diff -u "$_input" "$_linux_actual" >&2 || true
        exit 1
    fi

    printf '%s\n' "verify-integration path normalization self-test passed"
}

# A manifest row may pin its own optimization level with an `opt-level:N+`
# prefix on the extra field. Its batch group and any failed-chunk standalone
# replay both use that exact `--opt-level N`. Sets MANIFEST_ROW_OPT_LEVEL to
# the level or the empty string, and MANIFEST_ROW_EXTRA to what is left of the
# extra field.
manifest_row_split_opt_level() {
    MANIFEST_ROW_EXTRA=${1:-}
    MANIFEST_ROW_OPT_LEVEL=
    MANIFEST_ROW_BACKEND_MODE=
    case "$MANIFEST_ROW_EXTRA" in
        opt-level:*)
            MANIFEST_ROW_OPT_LEVEL=${MANIFEST_ROW_EXTRA#opt-level:}
            MANIFEST_ROW_OPT_LEVEL=${MANIFEST_ROW_OPT_LEVEL%%+*}
            MANIFEST_ROW_EXTRA=${MANIFEST_ROW_EXTRA#opt-level:*+}
            case "$MANIFEST_ROW_OPT_LEVEL" in
                0 | 1 | 2) ;;
                *) echo "invalid manifest optimization level: $MANIFEST_ROW_OPT_LEVEL" >&2; return 1 ;;
            esac
            ;;
    esac
    case "$MANIFEST_ROW_EXTRA" in
        backend-mode:scalar)
            MANIFEST_ROW_BACKEND_MODE=scalar
            MANIFEST_ROW_EXTRA=
            ;;
        backend-mode:scalar+*)
            MANIFEST_ROW_BACKEND_MODE=scalar
            MANIFEST_ROW_EXTRA=${MANIFEST_ROW_EXTRA#backend-mode:scalar+}
            ;;
        backend-mode:*)
            echo "invalid manifest backend mode: $MANIFEST_ROW_EXTRA" >&2
            return 1
            ;;
    esac
}

# The batch group of a normalized manifest row: the embedded payload or the
# staged on-disk stdlib layout, plus the row's pinned optimization level. Sets
# MANIFEST_ROW_GROUP from the same two fields integration_shards partitions,
# so a row's group and its shard can never disagree.
manifest_row_batch_group() {
    MANIFEST_ROW_GROUP=embedded
    case "$MANIFEST_ROW_EXTRA" in
        stage-stdlib | stage-stdlib+expected-stderr:*) MANIFEST_ROW_GROUP=stage-stdlib ;;
    esac
    [ -z "$MANIFEST_ROW_OPT_LEVEL" ] ||
        MANIFEST_ROW_GROUP="$MANIFEST_ROW_GROUP-opt$MANIFEST_ROW_OPT_LEVEL"
    [ -z "$MANIFEST_ROW_BACKEND_MODE" ] ||
        MANIFEST_ROW_GROUP="$MANIFEST_ROW_GROUP-$MANIFEST_ROW_BACKEND_MODE"
}

# Select this shard's rows: the batch pre-pass, the staged tree, the case loop
# and the summary all read NORMALIZED_MANIFEST, which holds exactly the rows of
# INTEGRATION_BATCH_GROUPS. Every other row still runs in the shard that names
# its group. A row whose group no shard names fails the run, so a group added
# to tests/integration/manifest.d/*.manifest cannot leave CI, and the manifest
# validation above still checks every row of both hosts.
integration_select_shard() {
    NORMALIZED_MANIFEST="$WORKDIR/manifest.selected"
    SHARD_CASES="$WORKDIR/shard-cases.txt"
    : > "$SHARD_CASES" || return 1
    INTEGRATION_LOCAL_FILTER_ACTIVE=0
    if [ -n "${TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES:-}" ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
        INTEGRATION_LOCAL_FILTER_ACTIVE=1
    fi
    while IFS='|' read -r _sel_name _sel_source _sel_want _sel_stdout _sel_args _sel_deps _sel_extra _sel_suite || [ -n "$_sel_name" ]; do
        case "$_sel_name" in
            "" | \#*) continue ;;
        esac
        manifest_row_split_opt_level "${_sel_extra:-}" || return 1
        manifest_row_batch_group
        case " $INTEGRATION_ALL_GROUPS " in
            *" $MANIFEST_ROW_GROUP "*) ;;
            *)
                echo "integration batch group '$MANIFEST_ROW_GROUP' of $_sel_name belongs to no shard" >&2
                echo "add it to integration_shards in $0" >&2
                return 1
                ;;
        esac
        case " $INTEGRATION_BATCH_GROUPS " in
            *" $MANIFEST_ROW_GROUP "*) ;;
            *) continue ;;
        esac
        printf '%s\n' "$_sel_name" >> "$SHARD_CASES" || return 1
    done < "$HOST_MANIFEST" || return 1
    # Copy the selected rows byte for byte: the readers below depend on the
    # field layout the expansion emitted.
    if [ "$INTEGRATION_LOCAL_FILTER_ACTIVE" -eq 0 ]; then
        awk -F '|' 'FILENAME == ARGV[1] { keep[$1]; next } ($1 in keep)' \
            "$SHARD_CASES" "$HOST_MANIFEST" > "$NORMALIZED_MANIFEST" || return 1
    else
        TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES="$TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES" \
            awk -F '|' -v root="$ROOT" '
            function normalize_path(p) {
                sub(/\r$/, "", p)
                gsub(/\\/, "/", p)
                if (root != "" && substr(p, 1, length(root) + 1) == root "/") {
                    p = substr(p, length(root) + 2)
                }
                while (substr(p, 1, 2) == "./") p = substr(p, 3)
                while (length(p) > 1 && substr(p, length(p), 1) == "/") {
                    p = substr(p, 1, length(p) - 1)
                }
                return p
            }
            function path_matches_changed(cand,    i, p) {
                if (cand == "") return 0
                if (cand in changed_set) return 1
                for (i = 1; i <= nchanged; i++) {
                    p = changed[i]
                    if (substr(cand, 1, length(p) + 1) == p "/") return 1
                    if (substr(p, 1, length(cand) + 1) == cand "/") return 1
                }
                return 0
            }
            function row_matches_changed(name, src, deps,    src_dir, src_base, name_dir, slashes, tmp, nd, dlist, j, d, i, p) {
                if (src in changed_set) return 1
                src_base = src
                sub(/\.tl$/, "", src_base)
                src_dir = src
                if (src_dir ~ /\//) sub(/\/[^\/]+$/, "", src_dir)
                else src_dir = ""
                name_dir = "tests/integration/" name
                tmp = src_dir
                slashes = gsub(/\//, "/", tmp)
                for (i = 1; i <= nchanged; i++) {
                    p = changed[i]
                    if (substr(src, 1, length(p) + 1) == p "/") return 1
                    if (substr(p, 1, length(src_base) + 1) == src_base "/") return 1
                    if (substr(p, 1, length(name_dir) + 1) == name_dir "/") return 1
                    if (slashes >= 2 && substr(p, 1, length(src_dir) + 1) == src_dir "/") return 1
                }
                if (deps != "" && deps != "-") {
                    nd = split(deps, dlist, /[[:space:]]+/)
                    for (j = 1; j <= nd; j++) {
                        d = dlist[j]
                        if (d == "" || d == "-") continue
                        if (path_matches_changed(d)) return 1
                        if (src_dir != "" && path_matches_changed(src_dir "/" d)) return 1
                        if (path_matches_changed("src/" d)) return 1
                        if (path_matches_changed("src" "/tests/" d)) return 1
                        if (path_matches_changed("tests/integration/" d)) return 1
                    }
                }
                return 0
            }
            BEGIN {
                changed_raw = ENVIRON["TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES"]
                gsub(/\r/, "", changed_raw)
                nraw = split(changed_raw, raw_items, /[[:space:],]+/)
                nchanged = 0
                for (i = 1; i <= nraw; i++) {
                    p = normalize_path(raw_items[i])
                    if (p != "" && !(p in changed_set)) {
                        changed_set[p] = 1
                        changed[++nchanged] = p
                    }
                }
            }
            FILENAME == ARGV[1] { keep[$1]; next }
            ($1 in keep) && row_matches_changed($1, $2, $6) { print }
        ' "$SHARD_CASES" "$HOST_MANIFEST" > "$NORMALIZED_MANIFEST" || return 1
        _sel_total=$(wc -l < "$SHARD_CASES" | tr -d ' ')
        _sel_kept=$(wc -l < "$NORMALIZED_MANIFEST" | tr -d ' ')
        echo "[integration] local changed-file filter selected $_sel_kept of $_sel_total shard row(s)"
    fi
}


# Deduplicate identical builds across manifest rows that share the exact same
# (batch-group, source, deps, forced-assembly) tuple. Only the canonical owner
# row is staged, compiled, assembled, and linked; alias rows rewrite any staged
# $SRC / $CASEDIR path in their expected-stderr to the canonical owner's staged
# path so exact line:column abort-site assertions stay 100% preserved, and then
# execute with their own CLI args and expectations against the shared binary.
MANIFEST_UNIQUE=
MANIFEST_PLAN=
INTEGRATION_TOTAL_CASES=0
INTEGRATION_UNIQUE_BUILDS=0
INTEGRATION_DEDUP_ALIAS_CASES=0

integration_build_dedup_plan() {
    MANIFEST_UNIQUE="$WORKDIR/manifest.unique"
    MANIFEST_PLAN="$WORKDIR/manifest.plan"
    _dedup_manifest="$WORKDIR/manifest.dedup"
    _dedup_counts="$WORKDIR/manifest.dedup-counts"
    _dedup_forced=
    if [ "$HOST_OS" = windows ]; then
        _dedup_forced=$(windows_manifest_assembly_assertion_cases | tr '\n' ' ')
    fi
    _dedup_work_root="target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX"
    awk -F '|' \
        -v work_root="$_dedup_work_root" \
        -v forced_list="$_dedup_forced" \
        -v dedup_out="$_dedup_manifest" \
        -v unique_out="$MANIFEST_UNIQUE" \
        -v plan_out="$MANIFEST_PLAN" \
        -v counts_out="$_dedup_counts" '
        function fail(msg) {
            print msg > "/dev/stderr"
            failed = 1
            exit 1
        }
        function replace_literal(str, old, rep,    idx, out, olen) {
            if (old == "" || index(str, old) == 0) return str
            out = ""
            olen = length(old)
            while ((idx = index(str, old)) > 0) {
                out = out substr(str, 1, idx - 1) rep
                str = substr(str, idx + olen)
            }
            return out str
        }
        function rewrite_casedir(str, old_dir, new_dir,    idx, out, olen, next_ch) {
            if (old_dir == "" || index(str, old_dir) == 0) return str
            out = ""
            olen = length(old_dir)
            while ((idx = index(str, old_dir)) > 0) {
                next_ch = substr(str, idx + olen, 1)
                if (next_ch == "" || next_ch !~ /[A-Za-z0-9_]/) {
                    out = out substr(str, 1, idx - 1) new_dir
                } else {
                    out = out substr(str, 1, idx + olen - 1)
                }
                str = substr(str, idx + olen)
            }
            return out str
        }
        BEGIN {
            nf = split(forced_list, farr, /[[:space:]]+/)
            for (i = 1; i <= nf; i++) {
                if (farr[i] != "") forced_set[farr[i]] = 1
            }
            total = 0
            unique = 0
            aliases = 0
            printf "" > dedup_out
            printf "" > unique_out
            printf "" > plan_out
        }
        {
            sub(/\r$/, "")
            if ($0 == "" || $0 ~ /^#/) next
            name = $1
            source = $2
            deps = $6
            extra = (NF >= 7 ? $7 : "")
            rest = extra
            opt = ""
            backend_mode = ""
            if (rest ~ /^opt-level:/) {
                sub(/^opt-level:/, "", rest)
                plus = index(rest, "+")
                if (plus <= 1) fail("invalid manifest optimization level for " name)
                opt = substr(rest, 1, plus - 1)
                rest = substr(rest, plus + 1)
                if (opt != "0" && opt != "1" && opt != "2") {
                    fail("invalid manifest optimization level: " opt)
                }
            }
            if (rest ~ /^backend-mode:/) {
                if (opt != "") fail("cannot combine opt-level and backend-mode for " name)
                sub(/^backend-mode:/, "", rest)
                if (rest == "scalar") {
                    backend_mode = "scalar"
                    rest = ""
                } else if (rest ~ /^scalar\+/) {
                    backend_mode = "scalar"
                    sub(/^scalar\+/, "", rest)
                } else {
                    fail("invalid manifest backend mode for " name ": backend-mode:" rest)
                }
            }
            group = (rest == "stage-stdlib" || rest ~ /^stage-stdlib\+expected-stderr:/) ? "stage-stdlib" : "embedded"
            if (opt != "") group = group "-opt" opt
            if (backend_mode != "") group = group "-" backend_mode
            deps_norm = (deps == "" || deps == "-") ? "" : deps
            forced = (name in forced_set) ? 1 : 0
            key = group SUBSEP source SUBSEP deps_norm SUBSEP forced
            total++
            if (!(key in key_owner)) {
                key_owner[key] = name
                owner = name
                unique++
                row_line = $0
                print row_line > unique_out
            } else {
                owner = key_owner[key]
                aliases++
                if (extra != "") {
                    old_src = work_root "/" name "/" name ".tl"
                    new_src = work_root "/" owner "/" owner ".tl"
                    old_dir = work_root "/" name
                    new_dir = work_root "/" owner
                    extra = replace_literal(extra, old_src, new_src)
                    extra = rewrite_casedir(extra, old_dir, new_dir)
                }
                row_line = $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6
                if (NF >= 8) row_line = row_line "|" extra "|" $8
                else if (NF == 7 || extra != "") row_line = row_line "|" extra
            }
            print row_line > dedup_out
            print owner "|" row_line > plan_out
        }
        END {
            if (failed) exit 1
            if (close(dedup_out) != 0 || close(unique_out) != 0 || close(plan_out) != 0) exit 1
            print total "|" unique "|" aliases > counts_out
            if (close(counts_out) != 0) exit 1
        }
    ' "$NORMALIZED_MANIFEST" || return 1
    mv "$_dedup_manifest" "$NORMALIZED_MANIFEST" || return 1
    IFS='|' read -r INTEGRATION_TOTAL_CASES INTEGRATION_UNIQUE_BUILDS INTEGRATION_DEDUP_ALIAS_CASES \
        < "$_dedup_counts" || return 1
}

# Emit one chunk list per group from the unique build manifest in a single awk
# pass, hoisting heavy chunks first via weight-bounded LPT scheduling.
integration_batch_queue() {
    for _group in $INTEGRATION_BATCH_GROUPS; do
        : > "$WORKDIR/batch-$_group.list" || return 1
    done
    _pool_queue="$WORKDIR/batch-pool.queue"
    : > "$_pool_queue" || return 1
    _queue_manifest=${MANIFEST_UNIQUE:-$NORMALIZED_MANIFEST}
    [ -f "$_queue_manifest" ] || _queue_manifest=$NORMALIZED_MANIFEST
    _queue_forced=
    if [ "$HOST_OS" = windows ]; then
        _queue_forced=$(windows_manifest_assembly_assertion_cases | tr '\n' ' ')
    fi
    awk -F '|' \
        -v dir="$WORKDIR" \
        -v host="$HOST_OS" \
        -v work_root="target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX" \
        -v groups_str="$INTEGRATION_BATCH_GROUPS" \
        -v forced_list="$_queue_forced" \
        -v size="$INTEGRATION_BATCH_SIZE" \
        -v cap="$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        -v queue="$_pool_queue" \
        -v max_w="$INTEGRATION_BATCH_CHUNK_MAX_WEIGHT" '
        function fail(msg) {
            print msg > "/dev/stderr"
            failed = 1
            exit 1
        }
        function resolve_mod(mod,    p, _line) {
            if (mod ~ /^stdlib\./ || mod == "stdlib") return ""
            p = "src/" mod ".tl"
            if ((getline _line < p) >= 0) {
                close(p)
                return p
            }
            p = "src" "/tests/" mod ".tl"
            if ((getline _line < p) >= 0) {
                close(p)
                return p
            }
            p = mod
            gsub(/\./, "/", p)
            p = p ".tl"
            if ((getline _line < p) >= 0) {
                close(p)
                return p
            }
            return ""
        }
        function scan_file(path,    line, n, mod, dep, i, in_str, ch, esc, k, len) {
            if (path in scanned) return
            scanned[path] = 1
            n = 0
            deg[path] = 0
            in_str = 0
            while ((getline line < path) > 0) {
                n++
                if (!in_str && line ~ /^[[:space:]]*(\(cfg[[:space:]]+[^()]+[[:space:]]+)?\(import[[:space:]]+/) {
                    mod = line
                    sub(/^[[:space:]]*(\(cfg[[:space:]]+[^()]+[[:space:]]+)?\(import[[:space:]]+\(?/, "", mod)
                    sub(/[[:space:]\)\r].*/, "", mod)
                    if (mod != "" && !seen_edge[path SUBSEP mod]++) {
                        dep = resolve_mod(mod)
                        if (dep != "" && dep != path) {
                            deg[path]++
                            edge[path, deg[path]] = dep
                        }
                    }
                }
                if (index(line, "\"") > 0) {
                    len = length(line)
                    esc = 0
                    for (k = 1; k <= len; k++) {
                        ch = substr(line, k, 1)
                        if (in_str) {
                            if (esc) { esc = 0 }
                            else if (ch == "\\") { esc = 1 }
                            else if (ch == "\"") { in_str = 0 }
                        } else {
                            if (ch == ";") { break }
                            else if (ch == "\"") { in_str = 1 }
                        }
                    }
                }
            }
            close(path)
            lines[path] = n
            for (i = 1; i <= deg[path]; i++) {
                scan_file(edge[path, i])
            }
        }
        function row_weight(src,    qhead, qtail, u, v, i, tot, vis, q) {
            if (src == "") return 0
            if (src in rw_cache) return rw_cache[src]
            scan_file(src)
            if (lines[src] == 0) {
                rw_cache[src] = 0
                return 0
            }
            qhead = 1
            qtail = 1
            q[1] = src
            vis[src] = 1
            tot = 0
            while (qhead <= qtail) {
                u = q[qhead++]
                tot += lines[u]
                for (i = 1; i <= deg[u]; i++) {
                    v = edge[u, i]
                    if (!(v in vis)) {
                        vis[v] = 1
                        q[++qtail] = v
                    }
                }
            }
            rw_cache[src] = tot + lines[src] * 4
            return rw_cache[src]
        }
        BEGIN {
            ng = split(groups_str, group_order, /[[:space:]]+/)
            if (host == "windows") {
                nf = split(forced_list, farr, /[[:space:]]+/)
                for (i = 1; i <= nf; i++) {
                    if (farr[i] != "") forced_set[farr[i]] = 1
                }
            }
        }
        {
            sub(/\r$/, "")
            if ($0 == "" || $0 ~ /^#/) next
            name = $1
            source = $2
            extra = (NF >= 7 ? $7 : "")
            rest = extra
            opt = ""
            backend_mode = ""
            if (rest ~ /^opt-level:/) {
                sub(/^opt-level:/, "", rest)
                plus = index(rest, "+")
                if (plus <= 1) fail("invalid manifest optimization level for " name)
                opt = substr(rest, 1, plus - 1)
                rest = substr(rest, plus + 1)
                if (opt != "0" && opt != "1" && opt != "2") {
                    fail("invalid manifest optimization level: " opt)
                }
            }
            if (rest ~ /^backend-mode:/) {
                if (opt != "") fail("cannot combine opt-level and backend-mode for " name)
                sub(/^backend-mode:/, "", rest)
                if (rest == "scalar") {
                    backend_mode = "scalar"
                    rest = ""
                } else if (rest ~ /^scalar\+/) {
                    backend_mode = "scalar"
                    sub(/^scalar\+/, "", rest)
                } else {
                    fail("invalid manifest backend mode for " name ": backend-mode:" rest)
                }
            }
            grp = (rest == "stage-stdlib" || rest ~ /^stage-stdlib\+expected-stderr:/) ? "stage-stdlib" : "embedded"
            if (opt != "") grp = grp "-opt" opt
            if (backend_mode != "") grp = grp "-" backend_mode

            rel = work_root "/" name "/" name
            if (host == "windows") {
                entry = rel ".tl|" rel ".obj|" rel ".s" ((name in forced_set) ? "|force-assembly" : "")
            } else {
                entry = rel ".tl|" rel ".s"
            }
            gcnt[grp]++
            gentry[grp, gcnt[grp]] = entry
            gsrc[grp, gcnt[grp]] = source
        }
        END {
            if (failed) exit 1
            chunks = 0
            for (gi = 1; gi <= ng; gi++) {
                grp = group_order[gi]
                if (grp == "" || gcnt[grp] == 0) continue
                idx_in_grp = 0
                cf = 0
                cw = 0
                output = ""
                for (k = 1; k <= gcnt[grp]; k++) {
                    rw = row_weight(gsrc[grp, k])
                    if (cf == 0 || cf >= size || (max_w > 0 && cw > 0 && cw + rw > max_w)) {
                        if (output != "") {
                            if (close(output) != 0) exit 1
                            chunks++
                            chunk_id[chunks] = cur_job
                            chunk_w[chunks] = cw
                        }
                        idx_in_grp++
                        cur_job = "batch-" grp "-" idx_in_grp
                        output = dir "/" cur_job ".list"
                        cf = 0
                        cw = 0
                    }
                    print gentry[grp, k] > output
                    cf++
                    cw += rw
                }
                if (output != "") {
                    if (close(output) != 0) exit 1
                    chunks++
                    chunk_id[chunks] = cur_job
                    chunk_w[chunks] = cw
                }
            }
            if (chunks > 0) {
                for (i = 1; i <= chunks; i++) ord[i] = i
                for (i = 2; i <= chunks; i++) {
                    idx = ord[i]
                    kw = chunk_w[idx]
                    j = i - 1
                    while (j >= 1 && chunk_w[ord[j]] < kw) {
                        ord[j + 1] = ord[j]
                        j--
                    }
                    ord[j + 1] = idx
                }
                for (i = 1; i <= chunks; i++) {
                    idx = ord[i]
                    print chunk_id[idx] "|" cap >> queue
                }
                if (close(queue) != 0) exit 1
            }
        }
    ' "$_queue_manifest" || return 1
}


run_bounded_completion_self_test() (
    . "$ROOT/scripts/lib-bounded-completion-fixtures.sh"
    _completion_root=$(mktemp -d "$WORKDIR/completion.XXXXXX")
    mkdir -p "$_completion_root/runner/scripts"
    cat > "$_completion_root/runner/scripts/run-memory-bounded.sh" <<'EOF'
#!/bin/sh
set -eu
[ "$1:$2:$3:$5:$6:$7" = --limit-mib:64:--report:--timeout-seconds:9:-- ] || exit 93
report=$4
shift 7
. "$COMPLETION_FIXTURES"
bounded_completion_fixture "$report" "$report.status" "$COMPLETION_HOST" 64 "$COMPLETION_CASE"
printf 'partial candidate\n' > "$report.candidate.s"
printf '%s\n' "$*" > "$report.argv"
printf '[bounded] fixture reason=%s\n' "$_bc_reason" >&2
case $COMPLETION_CASE in missing-status | bad-status) exit 2 ;; esac
bounded_completion_fixture_read "$report.status"
exit "$BOUNDED_COMPLETION_FIXTURE_TEXT"
EOF
    chmod +x "$_completion_root/runner/scripts/run-memory-bounded.sh"
    COMPLETION_FIXTURES="$ROOT/scripts/lib-bounded-completion-fixtures.sh"
    export COMPLETION_FIXTURES
    bounded_completion_fixture_matrix "$HOST_OS"
    _completion_checks="$_completion_root/checks.tsv"
    : > "$_completion_checks"
    set --
    for _completion_host in $BOUNDED_COMPLETION_HOSTS; do
        for _completion_case in $BOUNDED_COMPLETION_CASES; do
            set -- "$@" "$_completion_root/$_completion_host-$_completion_case/case"
        done
    done
    mkdir -p "$@"
    _completion_count=0
    for _completion_host in $BOUNDED_COMPLETION_HOSTS; do
        for _completion_case in $BOUNDED_COMPLETION_CASES; do
            _completion_count=$((_completion_count + 1))
            _completion_dir="$_completion_root/$_completion_host-$_completion_case"
            (
                WORKDIR=$_completion_dir
                exec 9> "$WORKDIR/console"
                HOST_OS=$_completion_host
                INTEGRATION_POOL_WORKERS=1
                INTEGRATION_POOL_BUDGET_MIB=64
                INTEGRATION_POOL_ENFORCE_CAPS=1
                INTEGRATION_BATCH_CHUNKS=0
                INTEGRATION_BATCH_FAILED_CHUNKS=0
                TYPELISP_CI_TIMING=0
                printf '%s\n' 'batch-embedded-1|64' 'batch-embedded-2|64' > "$WORKDIR/queue"
                printf '%s|%s|%s\n' "$WORKDIR/case/source.tl" \
                    "$WORKDIR/case/candidate.s" "$WORKDIR/case/candidate.obj" \
                    > "$WORKDIR/batch-embedded-1.list"
                printf '%s|%s|%s\n' "$WORKDIR/case/source.tl" \
                    "$WORKDIR/case/candidate.s" "$WORKDIR/case/candidate.obj" \
                    > "$WORKDIR/batch-embedded-2.list"
                printf 'partial candidate\n' > "$WORKDIR/case/candidate.s"
                printf 'partial candidate\n' > "$WORKDIR/case/candidate.obj"
                # Plant only the compile leaf: the actual worker, join,
                # timing-disabled preparation and settlement remain in use.
                integration_batch_compile_chunk() {
                    _completion_job="batch-$2"
                    _completion_mode=success
                    [ "$2" != embedded-1 ] || _completion_mode=$_completion_case
                    bounded_completion_fixture "$WORKDIR/$_completion_job.memory" \
                        "$WORKDIR/$_completion_job.status" "$HOST_OS" 64 "$_completion_mode"
                    printf '1\n' > "$WORKDIR/$_completion_job.elapsed-ms"
                    printf 'compiler diagnostic\n' > "$WORKDIR/$_completion_job.stderr"
                }
                integration_windows_register_plan() { : > "$WORKDIR/registered"; }
                integration_windows_register_plans_batch() { : > "$WORKDIR/registered"; }
                integration_batch_run_pool "$WORKDIR/queue"
                printf '%s\n' "$INTEGRATION_BATCH_FAILED_CHUNKS" > "$WORKDIR/settled"
                if [ "$INTEGRATION_BATCH_FAILED_CHUNKS" -gt 0 ]; then
                    ROOT="$_completion_root/runner"
                    INTEGRATION_POOL_CHUNK_CAP_MIB=64
                    INTEGRATION_POOL_JOB_TIMEOUT_SECONDS=9
                    COMPLETION_HOST=$HOST_OS
                    COMPLETION_CASE=success
                    export COMPLETION_HOST COMPLETION_CASE
                    integration_standalone_compile "$WORKDIR/case/replay.memory" \
                        uncallable-compiler compile fixture.tl
                    integration_diagnostic_only "$WORKDIR/case" fixture || exit 1
                    : > "$WORKDIR/replayed"
                fi
                integration_batch_require_success || exit 1
                : > "$WORKDIR/accepted"
            ) > "$_completion_dir/reader.log" 2>&1 &
            _completion_pid=$!
            _completion_rc=0
            wait "$_completion_pid" || _completion_rc=$?
            case $_completion_case in
                success)
                    [ "$_completion_rc" -eq 0 ] && [ -e "$_completion_dir/accepted" ] || exit 1
                    ;;
                command-*)
                    bounded_completion_fixture_read "$_completion_dir/settled"
                    _completion_settled=$BOUNDED_COMPLETION_FIXTURE_TEXT
                    bounded_completion_fixture_read "$_completion_dir/batch-embedded-1.status"
                    _completion_status=$BOUNDED_COMPLETION_FIXTURE_TEXT
                    [ "$_completion_rc" -ne 0 ] && [ "$_completion_settled" = 1 ] &&
                        [ -e "$_completion_dir/replayed" ] && [ ! -e "$_completion_dir/accepted" ] &&
                        [ ! -e "$_completion_dir/case/candidate.s" ] || exit 1
                    bounded_completion_fixture_expect "$_completion_checks" "$_completion_host/$_completion_case" contains \
                        "$_completion_dir/reader.log" "exited $_completion_status;"
                    bounded_completion_fixture_expect "$_completion_checks" "$_completion_host/$_completion_case" contains \
                        "$_completion_dir/console" 'replay was diagnostic-only'
                    ;;
                *)
                    if [ "$_completion_rc" -eq 0 ] || [ -e "$_completion_dir/accepted" ] ||
                        [ -e "$_completion_dir/registered" ] ||
                        [ -e "$_completion_dir/batch-pool/claims/batch-embedded-2" ]; then
                        echo "FAIL: integration accepted/replayed $_completion_host/$_completion_case" >&2
                        exit 1
                    fi
                    bounded_completion_fixture_expect "$_completion_checks" "$_completion_host/$_completion_case" absent \
                        "$_completion_dir/reader.log" 'replaying its entries'
                    ;;
            esac
            if [ "$_completion_case" = missing-report ]; then
                # Reach the parent's independent guard even though the real
                # worker correctly refused this completion before settlement.
                if (
                    WORKDIR=$_completion_dir
                    HOST_OS=$_completion_host
                    integration_batch_settle_chunk "$WORKDIR/batch-embedded-1.list" embedded-1 64
                ) > "$_completion_dir/parent.log" 2>&1; then
                    echo "FAIL: integration parent accepted $_completion_host/missing-report" >&2
                    exit 1
                fi
                bounded_completion_fixture_expect "$_completion_checks" "$_completion_host/missing-report/parent" contains \
                    "$_completion_dir/parent.log" 'reason=invalid-completion'
            fi
        done
    done

    # The actual standalone function must invoke the bounded runner with the
    # same cap and deadline. Model only that runner's result, including a
    # candidate emitted before cancellation. A direct compiler call is fatal.
    for COMPLETION_HOST in $BOUNDED_COMPLETION_HOSTS; do
        for COMPLETION_CASE in $BOUNDED_COMPLETION_CASES; do
            _completion_count=$((_completion_count + 1))
            export COMPLETION_HOST COMPLETION_CASE
            _completion_report="$_completion_root/standalone-$COMPLETION_HOST-$COMPLETION_CASE"
            _completion_rc=0
            (
                exec 9> "$_completion_report.console"
                ROOT="$_completion_root/runner"
                HOST_OS=$COMPLETION_HOST
                TYPELISP_CI_TIMING=1
                TYPELISP_CI_TIMING_GATE=standalone-completion-fixture
                ci_timing_init "$_completion_report.timing" "$HOST_OS"
                INTEGRATION_POOL_CHUNK_CAP_MIB=64
                INTEGRATION_POOL_JOB_TIMEOUT_SECONDS=9
                ci_timing_run "standalone-$COMPLETION_CASE" compile integration_standalone_compile \
                    "$_completion_report" uncallable-compiler compile fixture.tl \
                    > "$_completion_report.build.stdout" 2> "$_completion_report.build.stderr"
                : > "$_completion_report.accepted"
            ) > "$_completion_report.log" 2>&1 &
            _completion_pid=$!
            wait "$_completion_pid" || _completion_rc=$?
            case $COMPLETION_CASE in
                success) [ "$_completion_rc" -eq 0 ] && [ -e "$_completion_report.accepted" ] || exit 1 ;;
                command-*)
                    bounded_completion_fixture_read "$_completion_report.status"
                    _completion_status=$BOUNDED_COMPLETION_FIXTURE_TEXT
                    [ "$_completion_rc" -eq "$_completion_status" ] || exit 1 ;;
                *)
                    [ "$_completion_rc" -ne 0 ] && [ ! -e "$_completion_report.accepted" ] || exit 1
                    bounded_completion_fixture_expect "$_completion_checks" "$COMPLETION_HOST/$COMPLETION_CASE/standalone" contains \
                        "$_completion_report.console" 'reason='
                    bounded_completion_fixture_expect "$_completion_checks" "$COMPLETION_HOST/$COMPLETION_CASE/standalone" contains \
                        "$_completion_report.build.stderr" '[bounded] fixture reason='
                    ;;
            esac
            bounded_completion_fixture_read "$_completion_report.argv"
            [ "$BOUNDED_COMPLETION_FIXTURE_TEXT" = 'uncallable-compiler compile fixture.tl' ] || exit 1
        done
    done
    bounded_completion_fixture_check "$_completion_checks" || exit 1
    echo "[integration] bounded completion and standalone retry fixtures passed ($_completion_count host/path cases)"
)

run_batch_observability_self_test() {
    _dir="$WORKDIR/batch-observability-self-test"
    mkdir -p "$_dir"
    _chunk="$_dir/chunk.list"
    _fake_compiler="$_dir/fake-typelisp"
    _timing="$_dir/timing.tsv"
    cat > "$_chunk" <<'EOF'
first.tl|first.s
middle.tl|middle.s
last.tl|last.s
EOF
    cat > "$_fake_compiler" <<'EOF'
#!/bin/sh
[ "$1" = compile ] && [ "$2" = --batch ] && [ -s "$3" ]
EOF
    chmod +x "$_fake_compiler"

    _entry=$(integration_batch_sentinel_entry "$_chunk")
    if [ "$_entry" != "last.tl|last.s" ]; then
        echo "FAIL: batch sentinel selected '$_entry', expected the last chunk entry" >&2
        exit 1
    fi

    WORKDIR=$_dir
    COMPILER=$_fake_compiler
    # This self-test exercises the legacy assembly batch timing/sentinel
    # contract. Windows plan structure has its own focused validator self-test.
    HOST_OS=linux
    INTEGRATION_BATCH_CHUNKS=0
    INTEGRATION_BATCH_FAILED_CHUNKS=0
    TYPELISP_CI_TIMING=1
    TYPELISP_CI_TIMING_GATE=batch-observability-self-test
    export TYPELISP_CI_TIMING TYPELISP_CI_TIMING_GATE
    ci_timing_init "$_timing" "$HOST_OS"
    integration_batch_run_chunk "$_chunk" embedded-1 --stdlib-root "$ROOT/src"

    if ! awk -F '\t' '
        $1 == "batch-observability-self-test" &&
        $2 == "batch-embedded-1" &&
        $3 == "compile" &&
        $4 ~ /^[0-9]+$/ &&
        $5 == 0 { found = 1 }
        END { exit !found }
    ' "$_timing"; then
        echo "FAIL: batch compile timing row missing or malformed" >&2
        cat "$_timing" >&2
        exit 1
    fi
    if [ "$INTEGRATION_BATCH_CHUNKS" -ne 1 ] ||
        [ "$INTEGRATION_BATCH_FAILED_CHUNKS" -ne 0 ]; then
        echo "FAIL: batch chunk counters changed during observability self-test" >&2
        exit 1
    fi

    # Queue every source exactly once, preserving the explicit level and
    # stdlib choice across empty groups and a chunk boundary.
    NORMALIZED_MANIFEST="$_dir/levels.manifest"
    cat > "$NORMALIZED_MANIFEST" <<'EOF'
default_a|a.tl|0|-|-|-
default_b|b.tl|0|-|-|-
default_c|c.tl|0|-|-|-
disk_default|disk.tl|0|-|-|-|stage-stdlib
zero|zero.tl|0|-|-|-|opt-level:0+
disk_zero|zero.tl|0|-|-|-|opt-level:0+stage-stdlib
one|one.tl|0|-|-|-|opt-level:1+
two|two.tl|0|-|-|-|opt-level:2+expected-stderr:message
u64_float_casts|cast.tl|0|-|-|-|opt-level:2+stage-stdlib
EOF
    INTEGRATION_BATCH_SIZE=2
    integration_batch_queue
    printf '%s\n' \
        "batch-stage-stdlib-1|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        "batch-embedded-1|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        "batch-embedded-2|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        "batch-stage-stdlib-opt0-1|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        "batch-stage-stdlib-opt2-1|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        "batch-embedded-opt0-1|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        "batch-embedded-opt1-1|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        "batch-embedded-opt2-1|$INTEGRATION_POOL_CHUNK_CAP_MIB" \
        > "$_dir/levels.expected.queue"
    if ! cmp -s "$_dir/levels.expected.queue" "$_dir/batch-pool.queue" ||
        [ -s "$_dir/batch-stage-stdlib-opt1.list" ] ||
        [ "$(cat "$_dir/batch-embedded-2.list")" != \
            'target/integration-verify/linux/default_c/default_c.tl|target/integration-verify/linux/default_c/default_c.s' ]; then
        echo "FAIL: optimization-level batch partition lost its rows, order or chunk boundary" >&2
        exit 1
    fi
    # Build deduplication merges identical (group, source, deps, forced) rows,
    # rewrites $SRC and $CASEDIR in alias expected-stderr to the canonical
    # owner, and never merges rows differing in opt-level, stdlib layout, deps,
    # or forced-assembly status.
    _dedup_dir="$_dir/dedup-self-test"
    mkdir -p "$_dedup_dir"
    (
        WORKDIR=$_dedup_dir
        HOST_OS=linux
        INTEGRATION_SHARD_SUFFIX=-opt-levels
        INTEGRATION_BATCH_GROUPS='stage-stdlib-opt0 stage-stdlib-opt1 embedded-opt0'
        INTEGRATION_BATCH_SIZE=20
        NORMALIZED_MANIFEST="$_dedup_dir/dedup.manifest"
        cat > "$NORMALIZED_MANIFEST" <<'EOF'
canon_a|tests/integration/shared.tl|134|-|arg1|helper.tl|opt-level:0+expected-stderr:tl: target/integration-verify/linux-opt-levels/canon_a/canon_a.tl:10:5: err
alias_a|tests/integration/shared.tl|134|-|arg2|helper.tl|opt-level:0+expected-stderr:tl: target/integration-verify/linux-opt-levels/alias_a/alias_a.tl:20:3: err2
alias_dir|tests/integration/shared.tl|134|-|arg3|helper.tl|opt-level:0+expected-stderr:tl: target/integration-verify/linux-opt-levels/alias_dir/helper.tl:7:2: err3
diff_dep|tests/integration/shared.tl|0|-|arg1|-|opt-level:0+
diff_group|tests/integration/shared.tl|0|-|arg1|helper.tl|opt-level:0+stage-stdlib
diff_opt|tests/integration/shared.tl|0|-|arg1|helper.tl|opt-level:1+stage-stdlib
EOF
        integration_build_dedup_plan || exit 1
        if [ "$INTEGRATION_TOTAL_CASES" -ne 6 ] ||
            [ "$INTEGRATION_UNIQUE_BUILDS" -ne 4 ] ||
            [ "$INTEGRATION_DEDUP_ALIAS_CASES" -ne 2 ]; then
            echo "FAIL: build dedup counts wrong: total=$INTEGRATION_TOTAL_CASES unique=$INTEGRATION_UNIQUE_BUILDS aliases=$INTEGRATION_DEDUP_ALIAS_CASES" >&2
            exit 1
        fi
        if ! grep -F 'alias_a|tests/integration/shared.tl|134|-|arg2|helper.tl|opt-level:0+expected-stderr:tl: target/integration-verify/linux-opt-levels/canon_a/canon_a.tl:20:3: err2' "$NORMALIZED_MANIFEST" >/dev/null ||
            ! grep -F 'alias_dir|tests/integration/shared.tl|134|-|arg3|helper.tl|opt-level:0+expected-stderr:tl: target/integration-verify/linux-opt-levels/canon_a/helper.tl:7:2: err3' "$NORMALIZED_MANIFEST" >/dev/null; then
            echo "FAIL: build dedup did not rewrite alias \$SRC/\$CASEDIR paths to canonical owner" >&2
            cat "$NORMALIZED_MANIFEST" >&2
            exit 1
        fi
        integration_batch_queue || exit 1
        if [ "$(cat "$_dedup_dir"/batch-*-[0-9]*.list | wc -l | tr -d ' ')" -ne 4 ]; then
            echo "FAIL: batch queue did not deduplicate identical builds to 4 entries" >&2
            exit 1
        fi
    ) || exit 1
    # Inspect the actual common argv constructor, including target/cfg and
    # both source layouts. Default and explicitly pinned level 1 stay distinct.
    INTEGRATION_BATCH_TARGET_ARGS='--target windows-x86_64 --cfg windows'
    for _level_case in embedded:default stage-stdlib:default embedded-opt0:0 stage-stdlib-opt0:0 embedded-opt1:1 stage-stdlib-opt1:1 embedded-opt2:2 stage-stdlib-opt2:2; do
        _level_group=${_level_case%:*}
        _level_want=${_level_case#*:}
        integration_batch_group_run "$_level_group" printf '%s\n' \
            > "$_dir/level.argv"
        printf '%s\n' --verify-ir > "$_dir/level.expected.argv"
        if [ "$_level_want" != default ]; then
            printf '%s\n' --opt-level "$_level_want" >> "$_dir/level.expected.argv"
        fi
        printf '%s\n' --target windows-x86_64 --cfg windows >> "$_dir/level.expected.argv"
        case "$_level_group" in
            stage-stdlib*) printf '%s\n' --stdlib-root "$ROOT/stdlib" >> "$_dir/level.expected.argv" ;;
        esac
        printf '%s\n' --stdlib-root "$ROOT/src" >> "$_dir/level.expected.argv"
        if ! cmp -s "$_dir/level.argv" "$_dir/level.expected.argv"; then
            echo "FAIL: batch group $_level_group changed its exact compile flags" >&2
            exit 1
        fi
    done
    if integration_batch_group_run embedded-opt3 true 2> "$_dir/invalid-group.stderr" ||
        manifest_row_split_opt_level 'opt-level:3+' 2> "$_dir/invalid-level.stderr"; then
        echo "FAIL: invalid batch optimization metadata was accepted" >&2
        exit 1
    fi
    _valid_manifest=$NORMALIZED_MANIFEST
    NORMALIZED_MANIFEST="$_dir/invalid-level.manifest"
    printf '%s\n' 'invalid|invalid.tl|0|-|-|-|opt-level:3+' > "$NORMALIZED_MANIFEST"
    if ci_timing_run invalid-level batch-queue integration_batch_queue \
        2> "$_dir/invalid-queue.stderr"; then
        echo "FAIL: timed batch queue suppressed invalid optimization metadata" >&2
        exit 1
    fi
    NORMALIZED_MANIFEST=$_valid_manifest
    HOST_OS=windows
    integration_batch_queue
    if [ "$(cat "$_dir/batch-stage-stdlib-opt2-1.list")" != \
        'target/integration-verify/windows/u64_float_casts/u64_float_casts.tl|target/integration-verify/windows/u64_float_casts/u64_float_casts.obj|target/integration-verify/windows/u64_float_casts/u64_float_casts.s|force-assembly' ]; then
        echo "FAIL: pinned Windows batch lost its forced assembly assertion" >&2
        exit 1
    fi
    HOST_OS=linux

    # Weight-bounded splitting breaks heavy rows out of oversized chunks and
    # hoists the heaviest chunks to the front of the pool queue (LPT).
    _lpt_dir="$_dir/lpt-split"
    mkdir -p "$_lpt_dir/cases"
    printf ';; light\n' > "$_lpt_dir/cases/light1.tl"
    printf ';; light\n' > "$_lpt_dir/cases/light2.tl"
    awk 'BEGIN { for (i = 0; i < 70; i++) print ";; heavy" }' > "$_lpt_dir/cases/heavy1.tl"
    awk 'BEGIN { for (i = 0; i < 80; i++) print ";; heavier" }' > "$_lpt_dir/cases/heavy2.tl"
    awk 'BEGIN { for (i = 0; i < 120; i++) print ";; heaviest" }' > "$_lpt_dir/cases/heavy_em.tl"
    (
        WORKDIR=$_lpt_dir
        NORMALIZED_MANIFEST="$_lpt_dir/lpt.manifest"
        cat > "$NORMALIZED_MANIFEST" <<EOF
ss_l1|$_lpt_dir/cases/light1.tl|0|-|-|-|stage-stdlib
ss_l2|$_lpt_dir/cases/light2.tl|0|-|-|-|stage-stdlib
ss_h1|$_lpt_dir/cases/heavy1.tl|0|-|-|-|stage-stdlib
ss_h2|$_lpt_dir/cases/heavy2.tl|0|-|-|-|stage-stdlib
em_l1|$_lpt_dir/cases/light1.tl|0|-|-|-
em_h1|$_lpt_dir/cases/heavy_em.tl|0|-|-|-
EOF
        INTEGRATION_BATCH_GROUPS='stage-stdlib embedded'
        INTEGRATION_BATCH_SIZE=10
        INTEGRATION_BATCH_CHUNK_MAX_WEIGHT=350
        integration_batch_queue
        if [ "$(head -n 1 "$_lpt_dir/batch-pool.queue")" != "batch-embedded-2|$INTEGRATION_POOL_CHUNK_CAP_MIB" ] ||
            [ ! -s "$_lpt_dir/batch-stage-stdlib-3.list" ] ||
            [ "$(cat "$_lpt_dir"/batch-*-[0-9]*.list | wc -l | tr -d ' ')" -ne 6 ]; then
            echo "FAIL: weight-bounded integration batch queue did not split heavy rows or hoist heaviest chunk (LPT)" >&2
            cat "$_lpt_dir/batch-pool.queue" >&2
            exit 1
        fi
    ) || exit 1

    # Local-only changed-file filter matches source path, case-dir prefix, and
    # deps field 6, and is strictly ignored when GITHUB_ACTIONS=true.
    _flt_dir="$_dir/local-filter"
    mkdir -p "$_flt_dir"
    cat > "$_flt_dir/host.manifest" <<'EOF'
case_src|tests/integration/alpha.tl|0|-|-|-
case_dir|tests/integration/beta/main.tl|0|-|-|-
case_dep|tests/integration/gamma.tl|0|-|-|benchmarks/gamma_bench/baseline.c helper_dep.tl
case_other|tests/integration/delta.tl|0|-|-|-
EOF
    (
        WORKDIR=$_flt_dir
        HOST_MANIFEST="$_flt_dir/host.manifest"
        INTEGRATION_BATCH_GROUPS='stage-stdlib embedded'
        INTEGRATION_ALL_GROUPS='stage-stdlib embedded'
        GITHUB_ACTIONS=
        TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES='tests\integration\alpha.tl tests/integration/beta benchmarks\gamma_bench\baseline.c'
        export GITHUB_ACTIONS TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES
        integration_select_shard > "$_flt_dir/filter.log"
        if [ "$INTEGRATION_LOCAL_FILTER_ACTIVE" -ne 1 ] ||
            [ "$(cut -d '|' -f 1 "$_flt_dir/manifest.selected" | tr '\n' ' ')" != 'case_src case_dir case_dep ' ]; then
            echo "FAIL: local changed-file filter selected unexpected rows" >&2
            cat "$_flt_dir/manifest.selected" >&2
            exit 1
        fi
        GITHUB_ACTIONS=true
        export GITHUB_ACTIONS
        integration_select_shard > "$_flt_dir/ci.log"
        if [ "$INTEGRATION_LOCAL_FILTER_ACTIVE" -ne 0 ] ||
            [ "$(wc -l < "$_flt_dir/manifest.selected" | tr -d ' ')" -ne 4 ]; then
            echo "FAIL: GITHUB_ACTIONS=true did not strictly ignore TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES" >&2
            cat "$_flt_dir/manifest.selected" >&2
            exit 1
        fi
    ) || exit 1

    # The pooled route: three chunks, one of whose compiles fails. Every chunk
    # is settled in queue order, the failed chunk's candidate output is removed
    # for the standalone replay, and every job publishes its own timing row.
    cat > "$_fake_compiler" <<'EOF'
#!/bin/sh
[ "$1" = compile ] && [ "$2" = --batch ] && [ -s "$3" ] || exit 2
if grep -q 'fail\.tl' "$3"; then
    exit 1
fi
if grep -q 'slow\.tl' "$3"; then
    sleep 5
fi
exit 0
EOF
    chmod +x "$_fake_compiler"
    printf 'a.tl|%s/a.s\n' "$_dir" > "$_dir/batch-embedded-1.list"
    printf 'fail.tl|%s/fail.s\n' "$_dir" > "$_dir/batch-embedded-2.list"
    printf 'c.tl|%s/c.s\n' "$_dir" > "$_dir/batch-stage-stdlib-1.list"
    : > "$_dir/fail.s"
    printf '%s\n' 'batch-embedded-1|64' 'batch-embedded-2|64' \
        'batch-stage-stdlib-1|64' > "$_dir/pool.queue"
    INTEGRATION_BATCH_TARGET_ARGS=
    INTEGRATION_POOL_CHUNK_CAP_MIB=64
    INTEGRATION_POOL_BUDGET_MIB=$((INTEGRATION_POOL_WORKERS * 64))
    _real_host=linux
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) _real_host=windows ;;
    esac
    [ "$_real_host" = linux ] || INTEGRATION_POOL_ENFORCE_CAPS=0
    integration_batch_run_pool "$_dir/pool.queue"
    if [ "$INTEGRATION_BATCH_CHUNKS" -ne 4 ] ||
        [ "$INTEGRATION_BATCH_FAILED_CHUNKS" -ne 1 ]; then
        echo "FAIL: pooled chunks settled as $INTEGRATION_BATCH_CHUNKS chunk(s)," \
            "$INTEGRATION_BATCH_FAILED_CHUNKS failed; expected 4 and 1" >&2
        exit 1
    fi
    if [ -e "$_dir/fail.s" ]; then
        echo "FAIL: a failed pooled chunk kept its candidate output" >&2
        exit 1
    fi
    _pool_rows=$(awk -F '\t' '$3 == "compile" { printf "%s:%s ", $2, $5 }' "$_timing")
    if [ "$_pool_rows" != "batch-embedded-1:0 batch-embedded-1:0 batch-embedded-2:1 batch-stage-stdlib-1:0 " ]; then
        echo "FAIL: pooled batch timing rows missing, reordered or wrong: $_pool_rows" >&2
        cat "$_timing" >&2
        exit 1
    fi
    if [ "$_real_host" = linux ] && [ "$INTEGRATION_POOL_PEAK_BYTES" -le 0 ]; then
        echo "FAIL: pooled chunks recorded no bounded memory peak" >&2
        exit 1
    fi

    # A chunk stopped by its bound fails the gate instead of replaying.
    if [ "$_real_host" = linux ]; then
        printf 'slow.tl|%s/slow.s\n' "$_dir" > "$_dir/batch-embedded-9.list"
        printf '%s\n' 'batch-embedded-9|64' > "$_dir/slow.queue"
        if (
            INTEGRATION_POOL_JOB_TIMEOUT_SECONDS=1
            integration_batch_run_pool "$_dir/slow.queue"
        ) > "$_dir/slow.stdout" 2> "$_dir/slow.stderr"; then
            echo "FAIL: a pooled chunk past its timeout did not fail the gate" >&2
            exit 1
        fi
        if ! grep -q 'reason=timeout' "$_dir/slow.stderr"; then
            echo "FAIL: a timed-out pooled chunk was not reported as a bound stop" >&2
            cat "$_dir/slow.stderr" >&2
            exit 1
        fi
    fi

    # ci_timing_run is reentrant (#7956): the batch precompile is timed around
    # its per-chunk rows. Each call records exactly its own row, with its own
    # label, start and status, however the calls nest.
    _nested="$_dir/nested-timing.tsv"
    ci_timing_init "$_nested" "$HOST_OS"
    nested_timing_inner_pair() {
        ci_timing_run nested-inner-a sleep sleep 0.1 &&
            ci_timing_run nested-inner-b sleep sleep 0.1
    }
    nested_timing_ignored_failure() {
        ci_timing_run nested-inner-ignored check false || true
    }
    nested_timing_propagated_failure() {
        ci_timing_run nested-inner-propagated check false
    }
    ci_timing_run nested-outer compile nested_timing_inner_pair
    ci_timing_run nested-outer-ignored compile nested_timing_ignored_failure
    if ci_timing_run nested-outer-propagated compile \
            nested_timing_propagated_failure; then
        echo "FAIL: an outer ci_timing_run lost its command's failure" >&2
        exit 1
    fi
    if ! awk -F '\t' '
        NR > 1 { seen[$2 ":" $3 ":" $5]++; elapsed[$2] = $4; rows++ }
        END {
            exit !(rows == 7 &&
                seen["nested-inner-a:sleep:0"] == 1 &&
                seen["nested-inner-b:sleep:0"] == 1 &&
                seen["nested-outer:compile:0"] == 1 &&
                seen["nested-inner-ignored:check:1"] == 1 &&
                seen["nested-outer-ignored:compile:0"] == 1 &&
                seen["nested-inner-propagated:check:1"] == 1 &&
                seen["nested-outer-propagated:compile:1"] == 1 &&
                elapsed["nested-outer"] >= \
                    elapsed["nested-inner-a"] + elapsed["nested-inner-b"])
        }
    ' "$_nested"; then
        echo "FAIL: nested ci_timing_run rows lost, mislabelled or mistimed" >&2
        cat "$_nested" >&2
        exit 1
    fi

    printf '%s\n' "verify-integration batch observability self-test passed"
}

assert_manifest_case() {
    _name=$1
    _want=$2
    _stdout_spec=$3
    _stderr_spec=$4
    _asm=$5
    _stdout=$6
    _stderr=$7
    _case_dir=$8
    _run_shell_stderr=$9
    _assert_started=0
    if [ "$HOST_OS" = windows ] || ci_timing_enabled; then
        ci_timing_set_now_ms
        _assert_started=$CI_TIMING_NOW_MS
    fi
    _expected_stdout_cmp="$_case_dir/$_name.expected.stdout.cmp"
    _expected_stderr_cmp="$_case_dir/$_name.expected.stderr.cmp"
    _stdout_cmp="$_case_dir/$_name.stdout.cmp"
    _stderr_cmp="$_case_dir/$_name.stderr.cmp"
    _expected_stdout="$_case_dir/$_name.expected.stdout"
    _expected_stderr="$_case_dir/$_name.expected.stderr"

    assert_manifest_assembly_requirements "$_name" "$_asm"

    write_expected_stream "$_stdout_spec" "$_expected_stdout"
    write_expected_stream "$_stderr_spec" "$_expected_stderr"
    normalized_stream "$_expected_stdout" "$_expected_stdout_cmp"
    normalized_stream "$_expected_stderr" "$_expected_stderr_cmp"
    normalized_stream "$_stdout" "$_stdout_cmp"
    normalized_stream "$_stderr" "$_stderr_cmp"

    _case_failed=0
    if [ "$case_timed_out" -eq 1 ]; then
        report_case_timeout "$_name" \
            "timeout after $INTEGRATION_CASE_TIMEOUT_SECONDS s" "$_stdout" "$_stderr"
        case_timed_out=0
        _case_failed=1
    else
        if [ "$got" -ne "$_want" ]; then
            echo "FAIL: $_name expected exit $_want, got $got" >&2
            _case_failed=1
        fi
        if ! cmp -s "$_expected_stdout_cmp" "$_stdout_cmp"; then
            echo "FAIL: $_name stdout mismatch" >&2
            if command -v diff >/dev/null 2>&1; then
                diff -u "$_expected_stdout_cmp" "$_stdout_cmp" >&2 || true
            fi
            _case_failed=1
        fi
        if ! cmp -s "$_expected_stderr_cmp" "$_stderr_cmp"; then
            echo "FAIL: $_name stderr mismatch" >&2
            if command -v diff >/dev/null 2>&1; then
                diff -u "$_expected_stderr_cmp" "$_stderr_cmp" >&2 || true
            fi
            _case_failed=1
        fi
    fi
    if [ "$_case_failed" -ne 0 ] && [ -s "$_run_shell_stderr" ]; then
        echo "NOTE: $_name shell run diagnostics:" >&2
        sed 's/^/  /' "$_run_shell_stderr" >&2
    fi

    if [ "$_case_failed" -eq 0 ]; then
        echo "PASS: $_name"
        _assert_status=0
    else
        failed=$((failed + 1))
        _assert_status=1
    fi
    ran=$((ran + 1))
    if [ "$HOST_OS" = windows ] || ci_timing_enabled; then
        ci_timing_set_now_ms
        _assert_finished=$CI_TIMING_NOW_MS
        _assert_elapsed=$((_assert_finished - _assert_started))
        ci_timing_record_elapsed "$_name" assert "$_assert_elapsed" "$_assert_status"
    fi
    if [ "$HOST_OS" = windows ]; then
        WINDOWS_MANIFEST_ASSERT_MS=$((WINDOWS_MANIFEST_ASSERT_MS + _assert_elapsed))
        WINDOWS_MANIFEST_ASSERTS=$((WINDOWS_MANIFEST_ASSERTS + 1))
    fi
}

if [ "$SELF_TEST_EMPTY_COMPILE_DIAGNOSTIC" -eq 1 ]; then
    run_empty_compile_diagnostic_self_test
    exit 0
fi
if [ "$SELF_TEST_SIGNAL_NOTICE_CAPTURE" -eq 1 ]; then
    run_signal_notice_capture_self_test
    exit 0
fi
if [ "$SELF_TEST_PATH_NORMALIZATION" -eq 1 ]; then
    run_path_normalization_self_test
    exit 0
fi

assert_program_fixture_result() {
    _fixture_label=$1
    _fixture_want=$2
    _fixture_got=$3
    _fixture_stdout=$4
    _fixture_stderr=$5
    _fixture_stdout_spec=$6
    _fixture_dir=$7
    _fixture_expected_stdout="$_fixture_dir/$_fixture_label.expected.stdout"
    _fixture_expected_stdout_cmp="$_fixture_dir/$_fixture_label.expected.stdout.cmp"
    _fixture_stdout_cmp="$_fixture_dir/$_fixture_label.stdout.cmp"

    write_expected_stream "$_fixture_stdout_spec" "$_fixture_expected_stdout"
    normalized_stream "$_fixture_expected_stdout" "$_fixture_expected_stdout_cmp"
    normalized_stream "$_fixture_stdout" "$_fixture_stdout_cmp"

    _fixture_failed=0
    if [ "$_fixture_got" -ne "$_fixture_want" ]; then
        echo "FAIL: $_fixture_label expected exit $_fixture_want, got $_fixture_got" >&2
        _fixture_failed=1
    fi
    if ! cmp -s "$_fixture_expected_stdout_cmp" "$_fixture_stdout_cmp"; then
        echo "FAIL: $_fixture_label stdout mismatch" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_fixture_expected_stdout_cmp" "$_fixture_stdout_cmp" >&2 || true
        fi
        _fixture_failed=1
    fi
    if [ -s "$_fixture_stderr" ]; then
        echo "FAIL: $_fixture_label expected empty stderr" >&2
        _fixture_failed=1
    fi
    if [ "$_fixture_failed" -ne 0 ]; then
        show_stream_if_nonempty stdout "$_fixture_stdout"
        show_stream_if_nonempty stderr "$_fixture_stderr"
        exit 1
    fi
}

assemble_link_windows() {
    _asm=$1
    _obj=$2
    _bin=$3
    _label=$4

    clang --target=x86_64-pc-windows-msvc -c "$_asm" -o "$_obj" || {
        echo "FAIL: $_label assemble failed" >&2
        exit 1
    }
    _win_stdlib=$(windows_stdlib_archive_for_asm "$_asm" "${COMPILER:-}")
    if [ -n "$_win_stdlib" ]; then
        lld-link -NOLOGO "$(cygpath -aw "$_obj")" "$(cygpath -aw "$_win_stdlib")" -OPT:REF \
            "-OUT:$(cygpath -aw "$_bin")" -SUBSYSTEM:CONSOLE \
            -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib ntdll.lib || {
            echo "FAIL: $_label link failed" >&2
            exit 1
        }
    else
        lld-link -NOLOGO "$(cygpath -aw "$_obj")" "-OUT:$(cygpath -aw "$_bin")" -SUBSYSTEM:CONSOLE \
            -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib ntdll.lib || {
            echo "FAIL: $_label link failed" >&2
            exit 1
        }
    fi
}

run_windows_program_fixture() {
    _label=$1
    _source=$2
    _want=$3
    _opt_level=$4
    _stdout_spec=${5:--}
    _dir="$WORKDIR/$_label"
    mkdir -p "$_dir"
    _asm="$_dir/$_label.s"
    _obj="$_dir/$_label.obj"
    _bin="$_dir/$_label.exe"
    _stdout="$_dir/$_label.stdout"
    _stderr="$_dir/$_label.stderr"
    _code="$_dir/$_label.exit"
    _build_stdout="$_dir/$_label.build.stdout"
    _build_stderr="$_dir/$_label.build.stderr"

    echo "[$_label] compile --opt-level $_opt_level -> run (windows)"
    run_build "$COMPILER" compile "$ROOT/$_source" \
        --target windows-x86_64 --cfg windows \
        --stdlib-root "$ROOT/src" \
        --opt-level "$_opt_level" -o "$_asm" > "$_build_stdout" 2> "$_build_stderr"
    if [ "$build_rc" -ne 0 ]; then
        echo "FAIL: $_label compile failed" >&2
        show_build_streams "$_build_stdout" "$_build_stderr"
        exit 1
    fi
    assemble_link_windows "$_asm" "$_obj" "$_bin" "$_label"
    run_windows_program "$_bin" "$_stdout" "$_stderr" "$_code" "$_want"
    assert_program_fixture_result \
        "$_label" "$_want" "$got" "$_stdout" "$_stderr" \
        "$_stdout_spec" "$_dir"
}

run_windows_fatal_backtrace_fixture() {
    _label=fatal-backtrace-debug
    _source=tests/integration/fatal_backtrace.tl
    _dir="$WORKDIR/$_label"
    mkdir -p "$_dir"
    _asm="$_dir/$_label.s"
    _obj="$_dir/$_label.obj"
    _bin="$_dir/$_label.exe"
    _stdout="$_dir/$_label.stdout"
    _stderr="$_dir/$_label.stderr"
    _code="$_dir/$_label.exit"

    echo "[$_label] compile --backtrace -> run (windows)"
    run_build "$COMPILER" compile "$_source" \
        --target windows-x86_64 --cfg windows --backtrace \
        --stdlib-root "$ROOT/src" --opt-level 2 -o "$_asm"
    [ "$build_rc" -eq 0 ] || {
        echo "FAIL: $_label Windows compile failed" >&2
        exit 1
    }
    assert_contains "$_asm" '.section .rdata$TLBT,"dr"' "$_label Windows"
    assert_contains "$_asm" '.section .rdata$TLBS,"dr"' "$_label Windows"
    assert_contains "$_asm" 'call RtlCaptureStackBackTrace' "$_label Windows"
    assemble_link_windows "$_asm" "$_obj" "$_bin" "$_label"
    run_windows_program "$_bin" "$_stdout" "$_stderr" "$_code" 134
    [ "$got" -eq 134 ] || {
        echo "FAIL: $_label Windows expected exit 134, got $got" >&2
        exit 1
    }
    assert_empty_file "$_stdout" "$_label Windows stdout"
    assert_contains "$_stderr" 'stack backtrace:' "$_label Windows"
    assert_contains "$_stderr" 'fatal_backtrace.tl::backtrace-leaf' "$_label Windows"
    assert_contains "$_stderr" 'fatal_backtrace.tl:7:3' "$_label Windows"
}

run_windows_backend_fixtures() {
    run_windows_fatal_backtrace_fixture

    _runtime_dir="$WORKDIR/windows-backend-runtime"
    mkdir -p "$_runtime_dir"
    _runtime_asm="$_runtime_dir/runtime_helpers.s"
    _runtime_obj="$_runtime_dir/runtime_helpers.obj"
    _runtime_bin="$_runtime_dir/runtime_helpers.exe"
    _runtime_stdout="$_runtime_dir/runtime.stdout"
    _runtime_stderr="$_runtime_dir/runtime.stderr"
    _runtime_code="$_runtime_dir/runtime.exit"

    echo "[windows-backend-runtime] emit -> assemble -> link -> run"
    # The compile-only bootstrapped stage1 has no `run`, so build the fixture
    # driver (compile -> clang -> lld-link) and execute it to emit the runtime asm
    # (mirrors the Linux backend-runtime case in tests/codegen/integration-fixtures.cases).
    _driver_asm="$_runtime_dir/fixture_driver.s"
    _driver_obj="$_runtime_dir/fixture_driver.obj"
    _driver_bin="$_runtime_dir/fixture_driver.exe"
    "$COMPILER" compile src/tests/compiler_backend_runtime_fixture.tl \
        --stdlib-root src \
        --target windows-x86_64 --cfg windows -o "$_driver_asm" || {
        echo "FAIL: windows-backend-runtime driver compile failed" >&2
        exit 1
    }
    assemble_link_windows "$_driver_asm" "$_driver_obj" "$_driver_bin" windows-backend-runtime-driver
    "$_driver_bin" "$_runtime_asm" windows-x86_64 || {
        echo "FAIL: windows-backend-runtime driver run failed" >&2
        exit 1
    }
    for _snippet in \
        ".globl main" \
        ".globl tl_alloc" \
        "tl_alloc:" \
        "%gs:0x28" \
        "call tl_substring" \
        "call tl_string_concat" \
        ".L_tl_argc:" \
        ".L_tl_argv:" \
        "movq %rcx, .L_tl_argc(%rip)" \
        "movq %rdx, .L_tl_argv(%rip)" \
        ".extern VirtualAlloc" \
        ".extern GetLastError" \
        ".extern ExitProcess" \
        ".extern WriteFile" \
        "call VirtualAlloc" \
        "call GetLastError" \
        "call tl_windows_allocation_abort" \
        "rep movsb"
    do
        assert_contains "$_runtime_asm" "$_snippet" windows-backend-runtime
    done
    _rep_movsb_count=$(grep -c -F "rep movsb" "$_runtime_asm" || true)
    if [ "$_rep_movsb_count" -lt 1 ]; then
        echo "FAIL: windows-backend-runtime expected at least 1 rep movsb copy, got $_rep_movsb_count" >&2
        exit 1
    fi
    for _snippet in \
        "syscall" \
        ".globl _start" \
        ".extern tl_alloc" \
        ".extern tl_oob_abort" \
        ".globl tl_oob_abort" \
        "tl_oob_abort:" \
        ".globl tl_substring" \
        "tl_substring:" \
        ".extern tl_substring" \
        ".globl tl_string_concat" \
        "tl_string_concat:" \
        ".extern tl_string_concat" \
        ".extern tl_string_eq" \
        ".extern tl_string_to_int" \
        ".globl tl_string_eq" \
        "tl_string_eq:" \
        ".globl tl_string_to_int" \
        "tl_string_to_int:" \
        ".globl tl_hash_string" \
        "tl_hash_string:" \
        ".extern tl_hash_string" \
        ".globl tl_int_to_string" \
        "tl_int_to_string:" \
        ".extern tl_int_to_string" \
        "tl_print_err:" \
        ".L_tl_arg_count:" \
        ".L_tl_arg:" \
        ".L_tl_read_file:" \
        ".L_tl_write_file:" \
        ".L_tl_file_exists:" \
        ".L_tl_file_open_status:" \
        ".L_tl_file_close_status:" \
        ".L_tl_file_read_chunk_status:" \
        ".L_tl_file_write_status:" \
        ".L_tl_file_flush_status:" \
        ".L_tl_file_read_chunk_bytes:" \
        ".L_tl_file_read_chunk_eof:" \
        ".extern tl_print_err" \
        ".extern .L_tl_arg_count" \
        ".extern .L_tl_arg" \
        ".extern .L_tl_read_file" \
        ".extern .L_tl_write_file" \
        ".extern .L_tl_file_exists" \
        ".extern .L_tl_abort" \
        ".extern exit" \
        ".extern _write" \
        ".extern .L_tl_read_stdin_line" \
        ".extern .L_tl_read_stdin_bytes" \
        ".extern .L_tl_stdin_eof" \
        ".extern .L_tl_flush_stdout" \
        ".extern tl_random_system_seed" \
        "SystemFunction036" \
        "tl_process_output:" \
        "tl_process_start:" \
        "tl_process_wait:" \
        ".L_tl_process_read_all:" \
        ".L_tl_process_exec_marker:" \
        "tmpfile:" \
        "_fileno:" \
        "_get_osfhandle:" \
        "fclose:" \
        "__p__environ:" \
        "    call _lseeki64" \
        "    call _read" \
        "    ud2" \
        ".L_tl_substring_copy_loop:" \
        ".L_tl_string_concat_copy_a:" \
        ".L_tl_string_concat_copy_b:" \
        "path_copy_loop:" \
        "path_copy_done:"
    do
        assert_not_contains "$_runtime_asm" "$_snippet" windows-backend-runtime
    done
    # The direct backend fixture does not lower TypeLisp runtime-prelude bodies.
    # Append freestanding link-only targets for tl_alloc's OOM/provenance paths
    # and the moved string construction helpers; the happy path must not execute
    # them.
    cat >> "$_runtime_asm" <<'EOF'
    .globl tl_oom_abort
tl_oom_abort:
    movl $134, %ecx
    call ExitProcess
    .globl tl_windows_allocation_abort
tl_windows_allocation_abort:
    movl $134, %ecx
    call ExitProcess
    .globl tl_substring
tl_substring:
    xorl %eax, %eax
    ret
    .globl tl_string_concat
tl_string_concat:
    xorl %eax, %eax
    ret
EOF
    assemble_link_windows "$_runtime_asm" "$_runtime_obj" "$_runtime_bin" windows-backend-runtime
    run_windows_program "$_runtime_bin" "$_runtime_stdout" "$_runtime_stderr" "$_runtime_code" 42
    if [ "$got" -ne 42 ]; then
        echo "FAIL: windows-backend-runtime expected exit 42, got $got" >&2
        exit 1
    fi
    assert_empty_file "$_runtime_stdout" windows-backend-runtime-stdout
    assert_empty_file "$_runtime_stderr" windows-backend-runtime-stderr

    _driver_dir="$WORKDIR/windows-selfhost-compile-driver"
    mkdir -p "$_driver_dir"
    _driver_bin="$COMPILER"
    _driver_source="$_driver_dir/main.tl"
    _driver_asm="$_driver_dir/main.s"
    _driver_linux_asm="$_driver_dir/main-linux.s"
    _driver_windows_asm="$_driver_dir/main-windows.s"
    _driver_stdout="$_driver_dir/run.stdout"
    _driver_stderr="$_driver_dir/run.stderr"
    _driver_code="$_driver_dir/run.exit"

    echo "[windows-selfhost-compile-driver] exercise"
    printf '%s\n' '(define (main) : i64 42)' > "$_driver_source"
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" 0 compile \
        "$(cygpath -aw "$_driver_source")" -o "$(cygpath -aw "$_driver_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver default target got exit $got" >&2
        exit 1
    fi
    assert_contains "$_driver_stdout" "Wrote " windows-selfhost-compile-driver-stdout
    assert_empty_file "$_driver_stderr" windows-selfhost-compile-driver-stderr
    assert_contains "$_driver_asm" ".globl main" windows-selfhost-compile-driver
    assert_contains "$_driver_asm" "main:" windows-selfhost-compile-driver
    assert_contains "$_driver_asm" ".globl _tl_start" windows-selfhost-compile-driver

    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" 0 compile \
        "$(cygpath -aw "$_driver_source")" --target linux-x86_64 -o "$(cygpath -aw "$_driver_linux_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver explicit Linux target got exit $got" >&2
        exit 1
    fi
    assert_contains "$_driver_stdout" "Wrote " windows-selfhost-compile-driver-linux-stdout
    assert_empty_file "$_driver_stderr" windows-selfhost-compile-driver-linux-stderr
    if ! cmp -s "$_driver_asm" "$_driver_linux_asm"; then
        echo "FAIL: explicit Linux target should match default selfhost compile output" >&2
        exit 1
    fi

    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" 0 compile \
        "$(cygpath -aw "$_driver_source")" --target windows-x86_64 --cfg windows -o "$(cygpath -aw "$_driver_windows_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver Windows target got exit $got" >&2
        exit 1
    fi
    assert_contains "$_driver_stdout" "Wrote " windows-selfhost-compile-driver-windows-stdout
    assert_empty_file "$_driver_stderr" windows-selfhost-compile-driver-windows-stderr
    assert_contains "$_driver_windows_asm" ".globl main" windows-selfhost-compile-driver-windows
    assert_not_contains "$_driver_windows_asm" ".globl _start" windows-selfhost-compile-driver-windows

    _bad_target_asm="$_driver_dir/bad-target.s"
    rm -f "$_bad_target_asm"
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" - compile \
        "$(cygpath -aw "$_driver_source")" --target plan9-x86_64 -o "$(cygpath -aw "$_bad_target_asm")"
    if [ "$got" -eq 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver invalid target unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty_file "$_driver_stdout" windows-selfhost-compile-driver-bad-target-stdout
    assert_contains "$_driver_stderr" "invalid --target 'plan9-x86_64'; expected linux-x86_64 or windows-x86_64" \
        windows-selfhost-compile-driver-bad-target
    if [ -e "$_bad_target_asm" ]; then
        echo "FAIL: invalid target wrote assembly: $_bad_target_asm" >&2
        exit 1
    fi

    _comptime_source="$_driver_dir/comptime-type.tl"
    _comptime_asm="$_driver_dir/comptime-type.s"
    cat > "$_comptime_source" <<'EOF'
(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64) (__tl_make-array T n))
(define (main) : (__tl_dyn-array i64) (alloc (type i64) 4))
EOF
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" 0 compile \
        "$(cygpath -aw "$_comptime_source")" -o "$(cygpath -aw "$_comptime_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver comptime type source got exit $got" >&2
        exit 1
    fi
    assert_contains "$_driver_stdout" "Wrote " windows-selfhost-compile-driver-comptime-stdout
    assert_empty_file "$_driver_stderr" windows-selfhost-compile-driver-comptime-stderr
    assert_contains "$_comptime_asm" "__tl_specialized_alloc_type_i64_none" \
        windows-selfhost-compile-driver-comptime

    _bad_source="$_driver_dir/bad.tl"
    _bad_asm="$_driver_dir/bad.s"
    printf '%s\n' '(define (main) : i64 true)' > "$_bad_source"
    rm -f "$_bad_asm"
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" - compile \
        "$(cygpath -aw "$_bad_source")" -o "$(cygpath -aw "$_bad_asm")"
    if [ "$got" -eq 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver invalid source unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty_file "$_driver_stdout" windows-selfhost-compile-driver-bad-source-stdout
    assert_contains "$_driver_stderr" "typecheck: return type mismatch" \
        windows-selfhost-compile-driver-bad-source
    if [ -e "$_bad_asm" ]; then
        echo "FAIL: invalid source wrote assembly: $_bad_asm" >&2
        exit 1
    fi

    echo "Windows backend fixture checks passed."
}

run_backend_cmp_mem_fold_parity_fixtures() {
    # Windows half of tests/codegen/integration-fixtures.cases
    # backend-cmp-mem-fold-parity: both the unfused opt0 reference and the
    # opt2 folded path run; the cross-mode differential reuses both binaries.
    for _cmp_mem_level in 0 2; do
        run_windows_program_fixture \
            "backend-cmp-mem-fold-parity-opt$_cmp_mem_level" \
            src/tests/compiler_backend_cmp_mem_fold_smoke.tl \
            0 \
            "$_cmp_mem_level" \
            'cmp-mem fold smoke: bytes=4547\ncmp-mem fold smoke: compares=35338 words=388 indirect=280 acc=1579\n'
    done
    echo "Backend cmp-mem opt0/opt2 runtime parity checks passed."
}

# The fixtures of tests/codegen/integration-fixtures.cases (Linux).
run_linux_fixture_cases() {
    TYPELISP_BIN=$COMPILER scripts/verify-codegen-cases.sh "$@" tests/codegen/integration-fixtures.cases
}

windows_build_and_assemble_manifest() {
    _win_ready="$WORKDIR/windows-build.ready"
    _win_standalone="$WORKDIR/windows-build.standalone"
    _win_failed_owners="$WORKDIR/windows-build.failed-owners"
    _win_diag_owners="$WORKDIR/windows-build.diag-owners"
    _win_prep_counts="$WORKDIR/windows-build.prep-counts"
    _win_cdep_objs="$WORKDIR/windows-cdep-objs.tsv"
    : > "$_win_ready" || return 1
    : > "$_win_standalone" || return 1
    : > "$_win_failed_owners" || return 1
    : > "$_win_diag_owners" || return 1
    : > "$_win_cdep_objs" || return 1

    # Single-pass awk classifies every unique build against the consolidated
    # batch COFF artifact index (zero per-case shell loops).
    if ! awk -F '|' \
        -v artifacts_file="$WINDOWS_COFF_ARTIFACTS" \
        -v workdir="$WORKDIR" \
        -v ready_out="$_win_ready" \
        -v standalone_out="$_win_standalone" \
        -v counts_out="$_win_prep_counts" '
        function fail(msg) {
            print msg > "/dev/stderr"
            failed = 1
            exit 1
        }
        function file_nonempty(p,    rc, tmp) {
            rc = (getline tmp < p)
            close(p)
            return rc > 0
        }
        BEGIN {
            batched = 0
            standalone_cnt = 0
            printf "" > ready_out
            printf "" > standalone_out
        }
        FILENAME == artifacts_file {
            if ($0 == "") next
            art_kind[$1] = $2
            art_path[$1] = $3
            art_reason[$1] = $4
            art_archive[$1] = $5
            next
        }
        {
            sub(/\r$/, "")
            if ($0 == "" || $0 ~ /^#/) next
            name = $1
            source = $2
            deps = $6
            extra = (NF >= 7 ? $7 : "")
            rest = extra
            opt = ""
            backend_mode = ""
            if (rest ~ /^opt-level:/) {
                sub(/^opt-level:/, "", rest)
                plus = index(rest, "+")
                opt = substr(rest, 1, plus - 1)
                rest = substr(rest, plus + 1)
            }
            if (rest ~ /^backend-mode:/) {
                sub(/^backend-mode:/, "", rest)
                if (rest == "scalar") {
                    backend_mode = "scalar"
                    rest = ""
                } else if (rest ~ /^scalar\+/) {
                    backend_mode = "scalar"
                    sub(/^scalar\+/, "", rest)
                }
            }
            stage_stdlib = (rest == "stage-stdlib" || rest ~ /^stage-stdlib\+expected-stderr:/) ? 1 : 0
            case_dir = workdir "/" name
            obj = case_dir "/" name ".obj"
            asm = case_dir "/" name ".s"
            if (name in art_kind) {
                kind = art_kind[name]
                sel = art_path[name]
                reason = art_reason[name]
                arch = art_archive[name]
                if (kind == "coff-object") {
                    if (sel != obj || !file_nonempty(obj))
                        fail("FAIL: " name " Windows COFF object marker does not name its object")
                    cls = "none"
                } else if (kind == "assembly") {
                    if (sel != asm || !file_nonempty(asm))
                        fail("FAIL: " name " Windows COFF assembly marker does not name its assembly")
                    cls = (reason == "forced-assembly") ? "forced" : "fallback"
                } else {
                    fail("FAIL: " name " has unknown Windows COFF artifact kind: " kind)
                }
                batched++
                print name "|" source "|" kind "|" cls "|" arch "|" deps > ready_out
            } else {
                standalone_cnt++
                print name "|" source "|" stage_stdlib "|" opt "|" backend_mode "|" deps > standalone_out
            }
        }
        END {
            if (failed) exit 1
            if (close(ready_out) != 0 || close(standalone_out) != 0) exit 1
            print batched > counts_out
            if (close(counts_out) != 0) exit 1
        }
    ' "$WINDOWS_COFF_ARTIFACTS" "$MANIFEST_UNIQUE"; then
        return 1
    fi
    IFS= read -r _win_batched_count < "$_win_prep_counts" || return 1
    INTEGRATION_BATCHED_CASES=$((INTEGRATION_BATCHED_CASES + _win_batched_count))

    # Rare path: standalone diagnostic/fallback compiles when a batch chunk failed.
    if [ -s "$_win_standalone" ]; then
        while IFS='|' read -r name _st_source stage_stdlib opt_level backend_mode deps || [ -n "$name" ]; do
            [ -n "$name" ] || continue
            work_src_rel="target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX/$name/$name.tl"
            case_dir="$WORKDIR/$name"
            work_src="$case_dir/$name.tl"
            asm="$case_dir/$name.s"
            build_stdout="$case_dir/$name.build.stdout"
            build_stderr="$case_dir/$name.build.stderr"
            if [ -n "$opt_level" ]; then
                opt_level_args="--opt-level $opt_level"
            else
                opt_level_args=
            fi
            if [ -n "$backend_mode" ]; then
                opt_level_args="${opt_level_args:+$opt_level_args }--backend-mode $backend_mode"
            fi
            INTEGRATION_STANDALONE_COMPILES=$((INTEGRATION_STANDALONE_COMPILES + 1))
            if [ "$stage_stdlib" -eq 1 ]; then
                # shellcheck disable=SC2086
                windows_timed_compile integration_standalone_compile "$case_dir/standalone.memory" \
                    "$COMPILER" compile "$work_src_rel" --verify-ir --target windows-x86_64 --cfg windows \
                    --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" -o "$asm" \
                    $opt_level_args \
                    > "$build_stdout" 2> "$build_stderr"
            else
                # shellcheck disable=SC2086
                windows_timed_compile integration_standalone_compile "$case_dir/standalone.memory" \
                    "$COMPILER" compile "$work_src_rel" --verify-ir --target windows-x86_64 --cfg windows \
                    --stdlib-root "$ROOT/src" -o "$asm" \
                    $opt_level_args \
                    > "$build_stdout" 2> "$build_stderr"
            fi
            if [ "$build_rc" -ne 0 ]; then
                echo "FAIL: $name compile failed" >&2
                show_compile_failure_diagnostics \
                    "$name" \
                    "$build_rc" \
                    "$COMPILER" \
                    "$work_src" \
                    windows-x86_64 \
                    "$build_stdout" \
                    "$build_stderr" \
                    "$asm" \
                    "compile $work_src_rel --verify-ir --target windows-x86_64 --cfg windows --stdlib-root $ROOT/src -o $asm $opt_level_args (stage-stdlib=$stage_stdlib)"
                printf '%s\n' "$name" >> "$_win_failed_owners"
                continue
            fi
            if integration_diagnostic_only "$case_dir" "$name"; then
                printf '%s\n' "$name" >> "$_win_diag_owners"
                continue
            fi
            windows_link_archive=none
            if [ -n "$WINDOWS_STDLIB_ARCHIVE_WIN" ] &&
                [ -n "$(windows_stdlib_archive_for_asm "$asm" "${COMPILER:-}")" ]; then
                windows_link_archive=stdlib-archive
            fi
            printf '%s|%s|assembly|standalone|%s|%s\n' \
                "$name" "$_st_source" "$windows_link_archive" "$deps" >> "$_win_ready"
        done < "$_win_standalone"
    fi

    # Build the NUL-delimited clang.exe -c queue for all assembly + C dep
    # compiles in one awk pass (heavy src/tests/* assemblies first for LPT).
    # Pass native Windows backslash paths via ENVIRON so awk never interprets
    # \a, \b, \t, \i, etc. as escape sequences.
    _win_asm_counts="$WORKDIR/windows-assemble.prep-counts"
    printf 'tlwinlink1\000' > "$WINDOWS_ASSEMBLE_REQUEST"
    : > "$WINDOWS_ASSEMBLE_CASES"
    if ! AWK_WORKDIR_WIN="$WINDOWS_WORKDIR_WIN" \
        AWK_CLANG_WIN="$WINDOWS_CLANG_WIN" \
        awk -F '|' \
        -v req_out="$WINDOWS_ASSEMBLE_REQUEST" \
        -v cases_out="$WINDOWS_ASSEMBLE_CASES" \
        -v cdep_out="$_win_cdep_objs" \
        -v counts_out="$_win_asm_counts" '
        BEGIN {
            workdir_win = ENVIRON["AWK_WORKDIR_WIN"]
            clang_win = ENVIRON["AWK_CLANG_WIN"]
        }
        function emit_req(label, outp, stout, sterr, argc, a1, a2, a3, a4, a5, a6, a7, a8) {
            printf "%s%c%s%c%s%c%s%c%s%c%d%c", label, 0, clang_win, 0, outp, 0, stout, 0, sterr, 0, argc, 0 >> req_out
            if (argc >= 1) printf "%s%c", a1, 0 >> req_out
            if (argc >= 2) printf "%s%c", a2, 0 >> req_out
            if (argc >= 3) printf "%s%c", a3, 0 >> req_out
            if (argc >= 4) printf "%s%c", a4, 0 >> req_out
            if (argc >= 5) printf "%s%c", a5, 0 >> req_out
            if (argc >= 6) printf "%s%c", a6, 0 >> req_out
            if (argc >= 7) printf "%s%c", a7, 0 >> req_out
            if (argc >= 8) printf "%s%c", a8, 0 >> req_out
        }
        {
            if ($0 == "") next
            owner = $1
            src = $2
            kind = $3
            cls = $4
            deps = $6
            if (kind == "assembly") {
                if (src ~ /^src\/tests\//) {
                    h_n++
                    h_owner[h_n] = owner
                    h_cls[h_n] = cls
                } else {
                    l_n++
                    l_owner[l_n] = owner
                    l_cls[l_n] = cls
                }
            }
            if (deps != "" && deps != "-") {
                nd = split(deps, dlist, /[[:space:]]+/)
                k = 0
                for (i = 1; i <= nd; i++) {
                    d = dlist[i]
                    if (d ~ /\.c$/) {
                        k++
                        c_n++
                        c_owner[c_n] = owner
                        c_dep[c_n] = d
                        c_idx[c_n] = k
                    }
                }
            }
        }
        END {
            req_total = 0
            asm_total = 0
            cdep_total = 0
            for (i = 1; i <= h_n; i++) {
                owner = h_owner[i]
                cdir = workdir_win "\\" owner
                lbl = "asm__" owner
                emit_req(lbl, cdir "\\" owner ".obj", cdir "\\" owner ".asm.stdout", cdir "\\" owner ".asm.stderr", 5,
                    "--target=x86_64-pc-windows-msvc", "-c", cdir "\\" owner ".s", "-o", cdir "\\" owner ".obj")
                print lbl "|" owner "|asm|" h_cls[i] "|" owner ".asm.stdout|" owner ".asm.stderr" >> cases_out
                req_total++; asm_total++
            }
            for (i = 1; i <= l_n; i++) {
                owner = l_owner[i]
                cdir = workdir_win "\\" owner
                lbl = "asm__" owner
                emit_req(lbl, cdir "\\" owner ".obj", cdir "\\" owner ".asm.stdout", cdir "\\" owner ".asm.stderr", 5,
                    "--target=x86_64-pc-windows-msvc", "-c", cdir "\\" owner ".s", "-o", cdir "\\" owner ".obj")
                print lbl "|" owner "|asm|" l_cls[i] "|" owner ".asm.stdout|" owner ".asm.stderr" >> cases_out
                req_total++; asm_total++
            }
            for (i = 1; i <= c_n; i++) {
                owner = c_owner[i]
                d = c_dep[i]
                k = c_idx[i]
                base = d
                sub(/^.*\//, "", base)
                sub(/\.c$/, "", base)
                dwin = d
                gsub(/\//, "\\", dwin)
                cdir = workdir_win "\\" owner
                lbl = "cdep__" owner "__" k
                objp = cdir "\\" base ".native.obj"
                stout_rel = base "_" k ".cdep.stdout"
                sterr_rel = base "_" k ".cdep.stderr"
                emit_req(lbl, objp, cdir "\\" stout_rel, cdir "\\" sterr_rel, 8,
                    "--target=x86_64-pc-windows-msvc", "-std=c99", "-Wall", "-Wextra", "-c", cdir "\\" dwin, "-o", objp)
                print lbl "|" owner "|cdep|cdep|" stout_rel "|" sterr_rel >> cases_out
                print owner "|" objp >> cdep_out
                req_total++; cdep_total++
            }
            if (req_total > 0 && (close(req_out) != 0 || close(cases_out) != 0)) exit 1
            if (cdep_total > 0 && close(cdep_out) != 0) exit 1
            print req_total "|" asm_total "|" cdep_total > counts_out
            if (close(counts_out) != 0) exit 1
        }
    ' "$_win_ready"; then
        return 1
    fi
    IFS='|' read -r WINDOWS_ASSEMBLE_REQUESTS WINDOWS_MANIFEST_ASSEMBLES WINDOWS_MANIFEST_CDEP_ASSEMBLES \
        < "$_win_asm_counts" || return 1

    # Run all clang.exe -c jobs in parallel via windows-integration-linker.ps1.
    if [ "$WINDOWS_ASSEMBLE_REQUESTS" -gt 0 ]; then
        WINDOWS_ASSEMBLE_POWERSHELL_STARTS=1
        ci_timing_set_now_ms
        _asm_helper_started=$CI_TIMING_NOW_MS
        set +e
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_LINKER_WIN" \
            -RequestPath "$WINDOWS_ASSEMBLE_REQUEST_WIN" \
            -ResultPath "$WINDOWS_ASSEMBLE_RESULTS_WIN" \
            -SummaryPath "$WINDOWS_ASSEMBLE_SUMMARY_WIN" \
            -Jobs "$WINDOWS_ASSEMBLE_JOBS" \
            > "$WINDOWS_ASSEMBLE_RUNNER_STDOUT" 2> "$WINDOWS_ASSEMBLE_RUNNER_STDERR"
        _asm_helper_status=$?
        set -e
        ci_timing_set_now_ms
        _asm_helper_finished=$CI_TIMING_NOW_MS
        WINDOWS_MANIFEST_ASSEMBLE_HELPER_MS=$((_asm_helper_finished - _asm_helper_started))
        if [ "$_asm_helper_status" -ne 0 ]; then
            echo "FAIL: Windows integration assemble scheduler failed" >&2
            show_stream_if_nonempty stdout "$WINDOWS_ASSEMBLE_RUNNER_STDOUT"
            show_stream_if_nonempty stderr "$WINDOWS_ASSEMBLE_RUNNER_STDERR"
            return 1
        fi

        WINDOWS_ASSEMBLE_SUMMARY_REQUESTS=
        WINDOWS_ASSEMBLE_SUMMARY_CHILD_STARTS=
        WINDOWS_ASSEMBLE_SUMMARY_LAUNCH_FAILURES=
        WINDOWS_ASSEMBLE_SUMMARY_FAILED_PROCESSES=
        WINDOWS_ASSEMBLE_SUMMARY_MISSING_OUTPUTS=
        WINDOWS_ASSEMBLE_SUMMARY_JOBS=
        WINDOWS_ASSEMBLE_SUMMARY_PEAK_CONCURRENCY=
        WINDOWS_ASSEMBLE_SUMMARY_CHILD_MS=
        WINDOWS_ASSEMBLE_SUMMARY_RESULT_PROCESS_MS=
        WINDOWS_ASSEMBLE_SUMMARY_ELAPSED_MS=
        while IFS='=' read -r _asm_s_key _asm_s_val || [ -n "$_asm_s_key" ]; do
            case "$_asm_s_key" in
                requests) WINDOWS_ASSEMBLE_SUMMARY_REQUESTS=$_asm_s_val ;;
                child_starts) WINDOWS_ASSEMBLE_SUMMARY_CHILD_STARTS=$_asm_s_val ;;
                launch_failures) WINDOWS_ASSEMBLE_SUMMARY_LAUNCH_FAILURES=$_asm_s_val ;;
                failed_processes) WINDOWS_ASSEMBLE_SUMMARY_FAILED_PROCESSES=$_asm_s_val ;;
                missing_outputs) WINDOWS_ASSEMBLE_SUMMARY_MISSING_OUTPUTS=$_asm_s_val ;;
                jobs) WINDOWS_ASSEMBLE_SUMMARY_JOBS=$_asm_s_val ;;
                peak_concurrency) WINDOWS_ASSEMBLE_SUMMARY_PEAK_CONCURRENCY=$_asm_s_val ;;
                child_ms) WINDOWS_ASSEMBLE_SUMMARY_CHILD_MS=$_asm_s_val ;;
                result_process_ms) WINDOWS_ASSEMBLE_SUMMARY_RESULT_PROCESS_MS=$_asm_s_val ;;
                elapsed_ms) WINDOWS_ASSEMBLE_SUMMARY_ELAPSED_MS=$_asm_s_val ;;
            esac
        done < "$WINDOWS_ASSEMBLE_SUMMARY"
        if [ "${WINDOWS_ASSEMBLE_SUMMARY_REQUESTS:-}" != "$WINDOWS_ASSEMBLE_REQUESTS" ] ||
            [ "${WINDOWS_ASSEMBLE_SUMMARY_JOBS:-}" != "$WINDOWS_ASSEMBLE_JOBS" ]; then
            echo "FAIL: Windows integration assemble scheduler summary mismatch" >&2
            return 1
        fi
        WINDOWS_MANIFEST_ASSEMBLE_WALL_MS=$WINDOWS_ASSEMBLE_SUMMARY_ELAPSED_MS
        ci_timing_record_elapsed windows-manifest assemble-helper "$WINDOWS_MANIFEST_ASSEMBLE_HELPER_MS" 0
        ci_timing_record_elapsed windows-manifest assemble-scheduler "$WINDOWS_MANIFEST_ASSEMBLE_WALL_MS" 0

        _win_asm_timing_file=
        if ci_timing_enabled; then
            _win_asm_timing_file=$TYPELISP_CI_TIMING_FILE
        fi
        _win_asm_failures="$WORKDIR/windows-assemble.failures"
        _win_asm_totals="$WORKDIR/windows-assemble.totals"
        : > "$_win_asm_failures" || return 1
        if ! awk \
            -v cases_file="$WINDOWS_ASSEMBLE_CASES" \
            -v results_file="$WINDOWS_ASSEMBLE_RESULTS" \
            -v timing_file="$_win_asm_timing_file" \
            -v timing_gate="${TYPELISP_CI_TIMING_GATE:-ungated}" \
            -v timing_host="${TYPELISP_CI_TIMING_HOST:-$HOST_OS}" \
            -v failures_out="$_win_asm_failures" \
            -v failed_owners_out="$_win_failed_owners" \
            -v totals_out="$_win_asm_totals" '
            function fail(msg) {
                print msg > "/dev/stderr"
                bad = 1
                exit 1
            }
            BEGIN {
                n = 0
                while ((getline line < cases_file) > 0) {
                    sub(/\r$/, "", line)
                    if (line == "") continue
                    split(line, f, "|")
                    n++
                    c_lbl[n] = f[1]
                    c_owner[n] = f[2]
                    c_kind[n] = f[3]
                    c_cls[n] = f[4]
                    c_stout[n] = f[5]
                    c_sterr[n] = f[6]
                }
                close(cases_file)

                r = 0
                asm_ms = 0; fb_ms = 0; frc_ms = 0; st_ms = 0
                while ((getline rline < results_file) > 0) {
                    sub(/\r$/, "", rline)
                    r++
                    if (r > n) fail("FAIL: Windows integration assembler returned an unexpected extra result")
                    split(rline, rf, "\t")
                    if (rf[1] != c_lbl[r]) fail("FAIL: Windows integration assemble result order changed: expected " c_lbl[r] ", got " rf[1])
                    status = rf[2]; code = rf[3]; err64 = rf[4]; ms = rf[5] + 0; cmd64 = rf[6]
                    tstatus = (status == "ok" ? 0 : (status == "failed" ? code : 1))
                    if (c_kind[r] == "asm") {
                        asm_ms += ms
                        if (c_cls[r] == "fallback") fb_ms += ms
                        else if (c_cls[r] == "forced") frc_ms += ms
                        else if (c_cls[r] == "standalone") st_ms += ms
                        if (timing_file != "") {
                            printf "%s\t%s\t%s\t%s\t%s\t%s\n", timing_gate, c_owner[r], "assemble", ms, tstatus, timing_host >> timing_file
                        }
                    }
                    if (status != "ok") {
                        print c_owner[r] "\t" c_kind[r] "\t" status "\t" code "\t" err64 "\t" cmd64 "\t" c_stout[r] "\t" c_sterr[r] >> failures_out
                        if (!failed_owner_seen[c_owner[r]]++) {
                            print c_owner[r] >> failed_owners_out
                        }
                    }
                }
                close(results_file)
                if (r != n) fail("FAIL: Windows integration assembler attributed " r " of " n " requests")
                if (timing_file != "") close(timing_file)
                close(failures_out)
                close(failed_owners_out)
                print asm_ms "|" fb_ms "|" frc_ms "|" st_ms > totals_out
                close(totals_out)
            }
            END { if (bad) exit 1 }
        ' < /dev/null; then
            return 1
        fi
        IFS='|' read -r _asm_sum _fb_sum _frc_sum _st_sum < "$_win_asm_totals" || return 1
        WINDOWS_MANIFEST_ASSEMBLE_MS=$((WINDOWS_MANIFEST_ASSEMBLE_MS + _asm_sum))
        WINDOWS_MANIFEST_FALLBACK_ASSEMBLE_MS=$((WINDOWS_MANIFEST_FALLBACK_ASSEMBLE_MS + _fb_sum))
        WINDOWS_MANIFEST_FORCED_ASSEMBLE_MS=$((WINDOWS_MANIFEST_FORCED_ASSEMBLE_MS + _frc_sum))
        WINDOWS_MANIFEST_STANDALONE_ASSEMBLE_MS=$((WINDOWS_MANIFEST_STANDALONE_ASSEMBLE_MS + _st_sum))

        if [ -s "$_win_asm_failures" ]; then
            while IFS="$(printf '\t')" read -r _af_owner _af_kind _af_status _af_code _af_err64 _af_cmd64 _af_stout _af_sterr || [ -n "$_af_owner" ]; do
                [ -n "$_af_owner" ] || continue
                _af_err=$(windows_queue_decode "$_af_err64")
                _af_cmd=$(windows_queue_decode "$_af_cmd64")
                if [ "$_af_kind" = cdep ]; then
                    echo "FAIL: $_af_owner C dependency compile failed (status=$_af_status exit=$_af_code)" >&2
                else
                    echo "FAIL: $_af_owner assemble failed (status=$_af_status exit=$_af_code)" >&2
                fi
                echo "  command: $_af_cmd" >&2
                [ -z "$_af_err" ] || echo "  error: $_af_err" >&2
                show_compile_stream_diagnostic stdout "$WORKDIR/$_af_owner/$_af_stout"
                show_compile_stream_diagnostic stderr "$WORKDIR/$_af_owner/$_af_sterr"
            done < "$_win_asm_failures"
        fi
    fi

    # Account for any rows (owners + aliases) whose compile or assemble failed
    # or was diagnostic-only, and build the NUL-delimited lld-link.exe queue for
    # all passing unique builds in one awk pass.
    ci_timing_set_now_ms
    _link_plan_started=$CI_TIMING_NOW_MS
    _win_link_prep_counts="$WORKDIR/windows-link.prep-counts"
    printf 'tlwinlink1\000' > "$WINDOWS_LINK_REQUEST"
    : > "$WINDOWS_LINK_CASES"
    if ! AWK_WORKDIR_WIN="$WINDOWS_WORKDIR_WIN" \
        AWK_LLD_WIN="$WINDOWS_LLD_LINK_WIN" \
        AWK_STDLIB_ARCHIVE_WIN="$WINDOWS_STDLIB_ARCHIVE_WIN" \
        awk -F '|' \
        -v failed_file="$_win_failed_owners" \
        -v diag_file="$_win_diag_owners" \
        -v cdep_file="$_win_cdep_objs" \
        -v plan_file="$MANIFEST_PLAN" \
        -v ready_file="$_win_ready" \
        -v req_out="$WINDOWS_LINK_REQUEST" \
        -v cases_out="$WINDOWS_LINK_CASES" \
        -v counts_out="$_win_link_prep_counts" '
        function fail(msg) {
            print msg > "/dev/stderr"
            bad = 1
            exit 1
        }
        BEGIN {
            workdir_win = ENVIRON["AWK_WORKDIR_WIN"]
            lld_win = ENVIRON["AWK_LLD_WIN"]
            stdlib_archive_win = ENVIRON["AWK_STDLIB_ARCHIVE_WIN"]
            while ((getline line < failed_file) > 0) { sub(/\r$/, "", line); if (line != "") fail_owner[line] = 1 }
            close(failed_file)
            while ((getline line < diag_file) > 0) { sub(/\r$/, "", line); if (line != "") diag_owner[line] = 1 }
            close(diag_file)
            while ((getline line < cdep_file) > 0) {
                sub(/\r$/, "", line)
                if (line == "") continue
                split(line, cf, "|")
                cdep_cnt[cf[1]]++
                cdep_obj[cf[1], cdep_cnt[cf[1]]] = cf[2]
            }
            close(cdep_file)

            fail_rows = 0; diag_rows = 0
            while ((getline pline < plan_file) > 0) {
                sub(/\r$/, "", pline)
                if (pline == "") continue
                split(pline, pf, "|")
                ow = pf[1]; nm = pf[2]
                if (ow in fail_owner) {
                    if (nm != ow) print "FAIL: " nm " build failed (shared build " ow ")" > "/dev/stderr"
                    fail_rows++
                } else if (ow in diag_owner) {
                    diag_rows++
                }
            }
            close(plan_file)

            link_count = 0
            while ((getline rline < ready_file) > 0) {
                sub(/\r$/, "", rline)
                if (rline == "") continue
                split(rline, rf, "|")
                owner = rf[1]; arch = rf[5]
                if ((owner in fail_owner) || (owner in diag_owner)) continue
                cdir = workdir_win "\\" owner
                obj_win = cdir "\\" owner ".obj"
                bin_win = cdir "\\" owner ".exe"
                stout_win = cdir "\\" owner ".build.stdout"
                sterr_win = cdir "\\" owner ".build.stderr"

                argc = 0
                argv[++argc] = "-NOLOGO"
                argv[++argc] = obj_win
                for (i = 1; i <= cdep_cnt[owner]; i++) {
                    argv[++argc] = cdep_obj[owner, i]
                }
                if (arch == "stdlib-archive") {
                    if (stdlib_archive_win == "") {
                        fail("FAIL: " owner " needs the prebuilt stdlib archive, but no lib/x86_64-pc-windows-msvc/libstdlib.a was found")
                    }
                    argv[++argc] = "-OPT:REF"
                    argv[++argc] = stdlib_archive_win
                }
                argv[++argc] = "-OUT:" bin_win
                argv[++argc] = "-SUBSYSTEM:CONSOLE"
                argv[++argc] = "-STACK:268435456"
                argv[++argc] = "-ENTRY:_tl_start"
                argv[++argc] = "-NODEFAULTLIB"
                argv[++argc] = "kernel32.lib"
                argv[++argc] = "ntdll.lib"

                printf "%s%c%s%c%s%c%s%c%s%c%d%c", owner, 0, lld_win, 0, bin_win, 0, stout_win, 0, sterr_win, 0, argc, 0 >> req_out
                for (i = 1; i <= argc; i++) printf "%s%c", argv[i], 0 >> req_out
                print owner >> cases_out
                link_count++
            }
            close(ready_file)
            if (link_count > 0 && (close(req_out) != 0 || close(cases_out) != 0)) exit 1
            print link_count "|" fail_rows "|" diag_rows > counts_out
            if (close(counts_out) != 0) exit 1
        }
        END { if (bad) exit 1 }
    ' < /dev/null; then
        return 1
    fi
    IFS='|' read -r WINDOWS_LINK_REQUESTS _win_prelink_failed _win_prelink_diag < "$_win_link_prep_counts" || return 1
    WINDOWS_MANIFEST_LINKS=$WINDOWS_LINK_REQUESTS
    failed=$((failed + _win_prelink_failed))
    ran=$((ran + _win_prelink_failed + _win_prelink_diag))
    ci_timing_set_now_ms
    WINDOWS_MANIFEST_LINK_PREP_MS=$((CI_TIMING_NOW_MS - _link_plan_started))
}

windows_run_manifest_links() {
    WINDOWS_LINK_POWERSHELL_STARTS=1
    ci_timing_set_now_ms
    _link_helper_started=$CI_TIMING_NOW_MS
    set +e
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_LINKER_WIN" \
        -RequestPath "$WINDOWS_LINK_REQUEST_WIN" \
        -ResultPath "$WINDOWS_LINK_RESULTS_WIN" \
        -SummaryPath "$WINDOWS_LINK_SUMMARY_WIN" \
        -Jobs "$WINDOWS_LINK_JOBS" \
        > "$WINDOWS_LINK_RUNNER_STDOUT" 2> "$WINDOWS_LINK_RUNNER_STDERR"
    _link_helper_status=$?
    set -e
    ci_timing_set_now_ms
    _link_helper_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_LINK_HELPER_MS=$((_link_helper_finished - _link_helper_started))
    if [ "$_link_helper_status" -ne 0 ]; then
        echo "FAIL: Windows integration link scheduler failed" >&2
        show_stream_if_nonempty stdout "$WINDOWS_LINK_RUNNER_STDOUT"
        show_stream_if_nonempty stderr "$WINDOWS_LINK_RUNNER_STDERR"
        return 1
    fi

    WINDOWS_LINK_SUMMARY_REQUESTS=
    WINDOWS_LINK_SUMMARY_CHILD_STARTS=
    WINDOWS_LINK_SUMMARY_LAUNCH_FAILURES=
    WINDOWS_LINK_SUMMARY_FAILED_PROCESSES=
    WINDOWS_LINK_SUMMARY_MISSING_OUTPUTS=
    WINDOWS_LINK_SUMMARY_JOBS=
    WINDOWS_LINK_SUMMARY_PEAK_CONCURRENCY=
    WINDOWS_LINK_SUMMARY_CHILD_MS=
    WINDOWS_LINK_SUMMARY_RESULT_PROCESS_MS=
    WINDOWS_LINK_SUMMARY_ELAPSED_MS=
    while IFS='=' read -r _link_summary_key _link_summary_value || [ -n "$_link_summary_key" ]; do
        case "$_link_summary_key" in
            requests) WINDOWS_LINK_SUMMARY_REQUESTS=$_link_summary_value ;;
            child_starts) WINDOWS_LINK_SUMMARY_CHILD_STARTS=$_link_summary_value ;;
            launch_failures) WINDOWS_LINK_SUMMARY_LAUNCH_FAILURES=$_link_summary_value ;;
            failed_processes) WINDOWS_LINK_SUMMARY_FAILED_PROCESSES=$_link_summary_value ;;
            missing_outputs) WINDOWS_LINK_SUMMARY_MISSING_OUTPUTS=$_link_summary_value ;;
            jobs) WINDOWS_LINK_SUMMARY_JOBS=$_link_summary_value ;;
            peak_concurrency) WINDOWS_LINK_SUMMARY_PEAK_CONCURRENCY=$_link_summary_value ;;
            child_ms) WINDOWS_LINK_SUMMARY_CHILD_MS=$_link_summary_value ;;
            result_process_ms) WINDOWS_LINK_SUMMARY_RESULT_PROCESS_MS=$_link_summary_value ;;
            elapsed_ms) WINDOWS_LINK_SUMMARY_ELAPSED_MS=$_link_summary_value ;;
        esac
    done < "$WINDOWS_LINK_SUMMARY"
    for _link_summary_required in \
        "$WINDOWS_LINK_SUMMARY_REQUESTS" \
        "$WINDOWS_LINK_SUMMARY_CHILD_STARTS" \
        "$WINDOWS_LINK_SUMMARY_LAUNCH_FAILURES" \
        "$WINDOWS_LINK_SUMMARY_FAILED_PROCESSES" \
        "$WINDOWS_LINK_SUMMARY_MISSING_OUTPUTS" \
        "$WINDOWS_LINK_SUMMARY_JOBS" \
        "$WINDOWS_LINK_SUMMARY_PEAK_CONCURRENCY" \
        "$WINDOWS_LINK_SUMMARY_CHILD_MS" \
        "$WINDOWS_LINK_SUMMARY_RESULT_PROCESS_MS" \
        "$WINDOWS_LINK_SUMMARY_ELAPSED_MS"; do
        if [ -z "$_link_summary_required" ]; then
            echo "FAIL: Windows integration link scheduler wrote an incomplete summary" >&2
            return 1
        fi
    done
    if [ "$WINDOWS_LINK_SUMMARY_REQUESTS" -ne "$WINDOWS_LINK_REQUESTS" ]; then
        echo "FAIL: Windows integration linker returned $WINDOWS_LINK_SUMMARY_REQUESTS results for $WINDOWS_LINK_REQUESTS requests" >&2
        return 1
    fi
    if [ "$WINDOWS_LINK_SUMMARY_JOBS" -ne "$WINDOWS_LINK_JOBS" ]; then
        echo "FAIL: Windows integration linker used $WINDOWS_LINK_SUMMARY_JOBS jobs, expected $WINDOWS_LINK_JOBS" >&2
        return 1
    fi

    WINDOWS_MANIFEST_LINK_MS=$WINDOWS_LINK_SUMMARY_CHILD_MS
    WINDOWS_MANIFEST_LINK_WALL_MS=$WINDOWS_LINK_SUMMARY_ELAPSED_MS
    WINDOWS_MANIFEST_LINK_RESULT_PROCESS_MS=$WINDOWS_LINK_SUMMARY_RESULT_PROCESS_MS
    ci_timing_record_elapsed windows-manifest link-plan "$WINDOWS_MANIFEST_LINK_PREP_MS" 0
    ci_timing_record_elapsed windows-manifest link-helper "$WINDOWS_MANIFEST_LINK_HELPER_MS" 0
    ci_timing_record_elapsed windows-manifest link-scheduler "$WINDOWS_MANIFEST_LINK_WALL_MS" 0
    ci_timing_record_elapsed windows-manifest link-result-process "$WINDOWS_MANIFEST_LINK_RESULT_PROCESS_MS" 0
}

windows_process_manifest_link_results() {
    ci_timing_set_now_ms
    _link_attribution_started=$CI_TIMING_NOW_MS
    _link_timing_file=
    if ci_timing_enabled; then
        _link_timing_file=$TYPELISP_CI_TIMING_FILE
    fi
    _link_failures="$WORKDIR/windows-link.failures"
    _expected_fallback="$WORKDIR/windows-expected.fallback"
    _link_attr_counts="$WORKDIR/windows-link.attr-counts"
    : > "$_link_failures" || return 1
    : > "$_expected_fallback" || return 1

    # Single-pass awk validates link results in exact order, emits link timing
    # rows, writes expected stdout/stderr streams for simple/empty specs, and
    # queues every manifest row (owners + deduplicated aliases) into tlwinq4.
    if ! AWK_WORKDIR_WIN="$WINDOWS_WORKDIR_WIN" \
        awk \
        -v cases_file="$WINDOWS_LINK_CASES" \
        -v results_file="$WINDOWS_LINK_RESULTS" \
        -v plan_file="$MANIFEST_PLAN" \
        -v expected_requests="$WINDOWS_LINK_REQUESTS" \
        -v workdir="$WORKDIR" \
        -v timeout_sec="$INTEGRATION_CASE_TIMEOUT_SECONDS" \
        -v queue_out="$WINDOWS_QUEUE" \
        -v queued_out="$WINDOWS_QUEUED_CASES" \
        -v timing_file="$_link_timing_file" \
        -v timing_gate="${TYPELISP_CI_TIMING_GATE:-ungated}" \
        -v timing_host="${TYPELISP_CI_TIMING_HOST:-$HOST_OS}" \
        -v failures_out="$_link_failures" \
        -v fallback_out="$_expected_fallback" \
        -v counts_out="$_link_attr_counts" '
        function fail(msg) {
            print msg > "/dev/stderr"
            bad = 1
            exit 1
        }
        function file_exists(p,    rc, tmp) {
            rc = (getline tmp < p)
            close(p)
            return rc >= 0
        }
        function write_expected_or_defer(spec, out_path,    i, len, ch, nxt, decoded) {
            if (spec == "" || spec == "-") {
                printf "" > out_path
                close(out_path)
                return
            }
            if (substr(spec, 1, 1) == "@" || index(spec, "@loc{") > 0) {
                print out_path "|" spec >> fallback_out
                return
            }
            if (index(spec, "\\") == 0) {
                printf "%s", spec > out_path
                close(out_path)
                return
            }
            decoded = ""
            len = length(spec)
            for (i = 1; i <= len; i++) {
                ch = substr(spec, i, 1)
                if (ch == "\\" && i < len) {
                    nxt = substr(spec, i + 1, 1)
                    if (nxt == "n") { decoded = decoded "\n"; i++ }
                    else if (nxt == "t") { decoded = decoded "\t"; i++ }
                    else if (nxt == "r") { decoded = decoded "\r"; i++ }
                    else if (nxt == "\\") { decoded = decoded "\\"; i++ }
                    else {
                        print out_path "|" spec >> fallback_out
                        return
                    }
                } else {
                    decoded = decoded ch
                }
            }
            printf "%s", decoded > out_path
            close(out_path)
        }
        BEGIN {
            workdir_win = ENVIRON["AWK_WORKDIR_WIN"]
            nc = 0
            while ((getline cline < cases_file) > 0) {
                sub(/\r$/, "", cline)
                if (cline == "") continue
                nc++
                link_case[nc] = cline
            }
            close(cases_file)

            nr = 0
            while ((getline rline < results_file) > 0) {
                sub(/\r$/, "", rline)
                nr++
                if (nr > nc) fail("FAIL: Windows integration linker returned an unexpected extra result")
                split(rline, rf, "\t")
                owner = link_case[nr]
                if (rf[1] != owner) fail("FAIL: Windows integration link result order changed: expected " owner ", got " rf[1])
                status = rf[2]; code = rf[3]; err64 = rf[4]; elapsed = rf[5]; cmd64 = rf[6]
                tstatus = (status == "ok" ? 0 : (status == "failed" ? code : 1))
                if (timing_file != "") {
                    printf "%s\t%s\t%s\t%s\t%s\t%s\n", timing_gate, owner, "link", elapsed, tstatus, timing_host >> timing_file
                }
                if (status == "ok") {
                    if (!file_exists(workdir "/" owner "/" owner ".exe")) {
                        link_state[owner] = "missing-exe"
                    } else {
                        link_state[owner] = "ok"
                    }
                } else {
                    link_state[owner] = "failed"
                    print owner "\t" status "\t" code "\t" err64 "\t" cmd64 >> failures_out
                }
            }
            close(results_file)
            if (nr != nc) fail("FAIL: Windows integration link results ended before " link_case[nr + 1])
            if (nr != expected_requests) fail("FAIL: Windows integration linker attributed " nr " of " expected_requests " requests")

            queued = 0
            failed_rows = 0
            while ((getline pline < plan_file) > 0) {
                sub(/\r$/, "", pline)
                if (pline == "") continue
                nf = split(pline, pf, "|")
                owner = pf[1]
                name = pf[2]
                want = pf[4]
                stdout_spec = pf[5]
                runtime_args = pf[6]
                extra = (nf >= 8 ? pf[8] : "")
                if (!(owner in link_state)) continue
                if (link_state[owner] == "missing-exe") {
                    print "FAIL: " name " link result omitted its executable (" owner ")" > "/dev/stderr"
                    failed_rows++
                    continue
                }
                if (link_state[owner] != "ok") {
                    if (name != owner) {
                        print "FAIL: " name " link failed (shared build " owner ")" > "/dev/stderr"
                    }
                    failed_rows++
                    continue
                }
                rest = extra
                if (rest ~ /^opt-level:/) {
                    sub(/^opt-level:[^+]+\+/, "", rest)
                }
                if (rest ~ /^backend-mode:scalar\+/) {
                    sub(/^backend-mode:scalar\+/, "", rest)
                } else if (rest == "backend-mode:scalar") {
                    rest = ""
                }
                stderr_spec = "-"
                if (rest ~ /^stage-stdlib\+expected-stderr:/) {
                    stderr_spec = substr(rest, length("stage-stdlib+expected-stderr:") + 1)
                } else if (rest ~ /^expected-stderr:/) {
                    stderr_spec = substr(rest, length("expected-stderr:") + 1)
                }

                cdir = workdir "/" name
                write_expected_or_defer(stdout_spec, cdir "/" name ".expected.stdout")
                write_expected_or_defer(stderr_spec, cdir "/" name ".expected.stderr")

                exe_win = workdir_win "\\" owner "\\" owner ".exe"
                cdir_win = workdir_win "\\" name
                # compiler_codegen_smoke_suite and compiler_lower_smoke both
                # write under target/typelisp-fs/; serialize only that pair.
                lock_group = (name == "compiler_codegen_smoke_suite" || name == "compiler_lower_smoke") ? "typelisp-fs" : "-"

                nargs = 0
                if (runtime_args != "" && runtime_args != "-") {
                    nargs = split(runtime_args, argv)
                }
                printf "%s%c%s%c%s%c%s%c%s%c%s%c%s%c%s%c%s%c%s%c%d%c", \
                    name, 0, \
                    exe_win, 0, \
                    cdir_win "\\" name ".stdout", 0, \
                    cdir_win "\\" name ".stderr", 0, \
                    cdir_win "\\" name ".exit", 0, \
                    timeout_sec, 0, \
                    want, 0, \
                    cdir_win "\\" name ".expected.stdout", 0, \
                    cdir_win "\\" name ".expected.stderr", 0, \
                    lock_group, 0, \
                    nargs, 0 >> queue_out
                for (i = 1; i <= nargs; i++) {
                    printf "%s%c", argv[i], 0 >> queue_out
                }
                print name >> queued_out
                queued++
            }
            close(plan_file)
            if (timing_file != "") close(timing_file)
            close(failures_out)
            close(fallback_out)
            if (queued > 0 && (close(queue_out) != 0 || close(queued_out) != 0)) exit 1
            print nr "|" queued "|" failed_rows > counts_out
            if (close(counts_out) != 0) exit 1
        }
        END { if (bad) exit 1 }
    ' < /dev/null; then
        return 1
    fi

    if [ -s "$_expected_fallback" ]; then
        while IFS='|' read -r _exp_out _exp_spec || [ -n "$_exp_out" ]; do
            [ -n "$_exp_out" ] || continue
            write_expected_stream "$_exp_spec" "$_exp_out"
        done < "$_expected_fallback"
    fi

    if [ -s "$_link_failures" ]; then
        while IFS="$(printf '\t')" read -r _lf_owner _lf_status _lf_exit _lf_err64 _lf_cmd64 || [ -n "$_lf_owner" ]; do
            [ -n "$_lf_owner" ] || continue
            _link_decoded_error=$(windows_queue_decode "$_lf_err64")
            _link_decoded_command=$(windows_queue_decode "$_lf_cmd64")
            echo "FAIL: $_lf_owner link status=$_lf_status exit=$_lf_exit" >&2
            echo "  command: $_link_decoded_command" >&2
            if [ -n "$_link_decoded_error" ]; then
                echo "  error: $_link_decoded_error" >&2
            fi
            show_compile_stream_diagnostic \
                stdout \
                "$WORKDIR/$_lf_owner/$_lf_owner.build.stdout"
            show_compile_stream_diagnostic \
                stderr \
                "$WORKDIR/$_lf_owner/$_lf_owner.build.stderr"
        done < "$_link_failures"
    fi

    IFS='|' read -r _link_result_rows _link_queued_rows _link_failed_rows < "$_link_attr_counts" || return 1
    WINDOWS_MANIFEST_QUEUED=$((WINDOWS_MANIFEST_QUEUED + _link_queued_rows))
    WINDOWS_QUEUE_REQUESTS=$((WINDOWS_QUEUE_REQUESTS + _link_queued_rows))
    failed=$((failed + _link_failed_rows))
    ran=$((ran + _link_failed_rows))

    ci_timing_set_now_ms
    _link_attribution_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS=$((_link_attribution_finished - _link_attribution_started))
    ci_timing_record_elapsed \
        windows-manifest \
        link-attribution \
        "$WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS" \
        0
}

windows_enqueue_runner_self_tests() {
    WINDOWS_RUNNER_MISSING_LABEL=windows_runner_missing_executable
    WINDOWS_RUNNER_DEADLINE_LABEL=windows_runner_case_deadline
    _dir="$WORKDIR/windows-runner-self-test"
    mkdir -p "$_dir"
    windows_queue_append_request "$WINDOWS_QUEUE" "$WINDOWS_RUNNER_MISSING_LABEL" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.exe" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.stdout" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.stderr" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.exit" \
        - - - serial
    # cmd.exe waits on a ping.exe child that inherits the output pipe, so the
    # request completes near its 1 s deadline only if the tree kill reaches
    # the child too. Kept strictly serial to prevent CPU contention jitter.
    (
        INTEGRATION_CASE_TIMEOUT_SECONDS=1
        windows_queue_append_request "$WINDOWS_QUEUE" "$WINDOWS_RUNNER_DEADLINE_LABEL" \
            cmd.exe \
            "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\deadline.stdout" \
            "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\deadline.stderr" \
            "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\deadline.exit" \
            - - - serial /d /c ping -n 60 127.0.0.1
    )
    WINDOWS_QUEUE_REQUESTS=$((WINDOWS_QUEUE_REQUESTS + 2))
}

windows_run_manifest_queue() {
    mkdir -p "$ROOT/target/exp"
    windows_enqueue_runner_self_tests
    WINDOWS_MANIFEST_POWERSHELL_STARTS=1
    if ! windows_run_request_file \
        "$WINDOWS_QUEUE_WIN" \
        "$WINDOWS_RESULTS_WIN" \
        "$WINDOWS_ASSERTIONS_WIN" \
        "$WINDOWS_SUMMARY_WIN" \
        "$WINDOWS_RUNNER_STDOUT" \
        "$WINDOWS_RUNNER_STDERR" \
        "$WINDOWS_RUNNER_JOBS"; then
        echo "FAIL: Windows integration queue runner failed" >&2
        show_stream_if_nonempty stdout "$WINDOWS_RUNNER_STDOUT"
        show_stream_if_nonempty stderr "$WINDOWS_RUNNER_STDERR"
        return 1
    fi
    WINDOWS_MANIFEST_RUN_MS=$WINDOWS_LAST_RUN_MS
    WINDOWS_SUMMARY_REQUESTS=
    WINDOWS_SUMMARY_CHILD_STARTS=
    WINDOWS_SUMMARY_LAUNCH_FAILURES=
    WINDOWS_SUMMARY_TIMEOUTS=
    WINDOWS_SUMMARY_ASSERTIONS=
    WINDOWS_SUMMARY_JOBS=
    WINDOWS_SUMMARY_PEAK_CONCURRENCY=
    WINDOWS_SUMMARY_CHILD_MS=
    WINDOWS_SUMMARY_RESULT_PROCESS_MS=
    WINDOWS_SUMMARY_ASSERT_MS=
    WINDOWS_SUMMARY_ELAPSED_MS=
    while IFS='=' read -r _summary_key _summary_value || [ -n "$_summary_key" ]; do
        case "$_summary_key" in
            requests) WINDOWS_SUMMARY_REQUESTS=$_summary_value ;;
            child_starts) WINDOWS_SUMMARY_CHILD_STARTS=$_summary_value ;;
            launch_failures) WINDOWS_SUMMARY_LAUNCH_FAILURES=$_summary_value ;;
            timeouts) WINDOWS_SUMMARY_TIMEOUTS=$_summary_value ;;
            assertions) WINDOWS_SUMMARY_ASSERTIONS=$_summary_value ;;
            jobs) WINDOWS_SUMMARY_JOBS=$_summary_value ;;
            peak_concurrency) WINDOWS_SUMMARY_PEAK_CONCURRENCY=$_summary_value ;;
            child_ms) WINDOWS_SUMMARY_CHILD_MS=$_summary_value ;;
            result_process_ms) WINDOWS_SUMMARY_RESULT_PROCESS_MS=$_summary_value ;;
            assert_ms) WINDOWS_SUMMARY_ASSERT_MS=$_summary_value ;;
            elapsed_ms) WINDOWS_SUMMARY_ELAPSED_MS=$_summary_value ;;
        esac
    done < "$WINDOWS_SUMMARY"
    if [ "$WINDOWS_SUMMARY_REQUESTS" -ne "$WINDOWS_QUEUE_REQUESTS" ]; then
        echo "FAIL: Windows integration queue returned $WINDOWS_SUMMARY_REQUESTS results for $WINDOWS_QUEUE_REQUESTS requests" >&2
        return 1
    fi
    if [ "$WINDOWS_SUMMARY_ASSERTIONS" -ne "$WINDOWS_MANIFEST_QUEUED" ]; then
        echo "FAIL: Windows integration runner asserted $WINDOWS_SUMMARY_ASSERTIONS cases for $WINDOWS_MANIFEST_QUEUED queued manifest cases" >&2
        return 1
    fi
    if [ "${WINDOWS_SUMMARY_JOBS:-}" != "$WINDOWS_RUNNER_JOBS" ]; then
        echo "FAIL: Windows integration runner used ${WINDOWS_SUMMARY_JOBS:-none} jobs, expected $WINDOWS_RUNNER_JOBS" >&2
        return 1
    fi
    WINDOWS_MANIFEST_RESULT_PROCESS_MS=$WINDOWS_SUMMARY_RESULT_PROCESS_MS
    ci_timing_record_elapsed windows-manifest runner "$WINDOWS_MANIFEST_RUN_MS" 0
    ci_timing_record_elapsed windows-manifest result-process "$WINDOWS_MANIFEST_RESULT_PROCESS_MS" 0
    if ! windows_result_for_label "$WINDOWS_RUNNER_MISSING_LABEL"; then
        echo "FAIL: Windows integration queue omitted launch-failure self-test" >&2
        return 1
    fi
    if [ "$WINDOWS_RESULT_STATUS" != launch-failed ]; then
        echo "FAIL: Windows integration queue missing executable status was $WINDOWS_RESULT_STATUS" >&2
        return 1
    fi
    if [ -e "$WORKDIR/windows-runner-self-test/missing.exit" ]; then
        echo "FAIL: Windows integration queue wrote an exit code for a missing executable" >&2
        return 1
    fi
    if ! windows_result_for_label "$WINDOWS_RUNNER_DEADLINE_LABEL"; then
        echo "FAIL: Windows integration queue omitted case-deadline self-test" >&2
        return 1
    fi
    if [ "$WINDOWS_RESULT_STATUS" != timeout ] ||
        [ "$WINDOWS_RESULT_ERROR" != "timeout after 1 s" ] ||
        [ "$WINDOWS_RESULT_MS" -ge 10000 ]; then
        echo "FAIL: Windows integration queue case-deadline self-test settled as" \
            "$WINDOWS_RESULT_STATUS in $WINDOWS_RESULT_MS ms: $WINDOWS_RESULT_ERROR" >&2
        return 1
    fi
    if [ -e "$WORKDIR/windows-runner-self-test/deadline.exit" ]; then
        echo "FAIL: Windows integration queue wrote an exit code for a timed-out case" >&2
        return 1
    fi
}

windows_assert_queued_cases() {
    ci_timing_set_now_ms
    _assert_report_started=$CI_TIMING_NOW_MS

    # Run assembly text assertions for any queued forced-assembly cases (only 3).
    for _asm_req_case in $(windows_manifest_assembly_assertion_cases); do
        if grep -F -x "$_asm_req_case" "$WINDOWS_QUEUED_CASES" >/dev/null 2>&1; then
            assert_manifest_assembly_requirements "$_asm_req_case" "$WORKDIR/$_asm_req_case/$_asm_req_case.s"
        fi
    done

    _assert_timing_file=
    if ci_timing_enabled; then
        _assert_timing_file=$TYPELISP_CI_TIMING_FILE
    fi
    _assert_failures="$WORKDIR/windows-assert.failures"
    _assert_totals="$WORKDIR/windows-assert.totals"
    : > "$_assert_failures" || return 1

    # Single-pass awk prints PASS lines, emits run/assert timing rows, sums
    # counters, and filters only failed rows for shell diff diagnostics.
    awk -F '\t' \
        -v timing_file="$_assert_timing_file" \
        -v timing_gate="${TYPELISP_CI_TIMING_GATE:-ungated}" \
        -v timing_host="${TYPELISP_CI_TIMING_HOST:-$HOST_OS}" \
        -v failures_out="$_assert_failures" \
        -v totals_out="$_assert_totals" '
        {
            sub(/\r$/, "")
            if ($0 == "" || $1 == "") next
            name = $1; status = $2; code = $3; want = $4; err = $5
            run_ms = $6; assert_ms = $7 + 0
            ex_ok = $8 + 0; out_ok = $9 + 0; err_ok = $10 + 0
            rows++
            total_assert_ms += assert_ms
            if (status == "ok" && timing_file != "") {
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", timing_gate, name, "run", run_ms, code, timing_host >> timing_file
            }
            if (status == "ok" && ex_ok == 1 && out_ok == 1 && err_ok == 1) {
                print "PASS: " name
                astat = 0
            } else {
                print $0 >> failures_out
                failed_cnt++
                astat = 1
            }
            if (timing_file != "") {
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", timing_gate, name, "assert", assert_ms, astat, timing_host >> timing_file
            }
        }
        END {
            if (timing_file != "") close(timing_file)
            close(failures_out)
            print (rows + 0) "|" (failed_cnt + 0) "|" (total_assert_ms + 0) > totals_out
            close(totals_out)
        }
    ' "$WINDOWS_ASSERTIONS" || return 1

    if [ -s "$_assert_failures" ]; then
        while IFS="$(printf '\t')" read -r \
            _name _status _exit _want _error _run_ms _assert_ms \
            _exit_matches _stdout_matches _stderr_matches || [ -n "$_name" ]; do
            [ -n "$_name" ] || continue
            _case_dir="$WORKDIR/$_name"
            _run_shell_stderr="$_case_dir/$_name.run-shell.stderr"
            if [ "$_status" = timeout ]; then
                report_case_timeout "$_name" "$(windows_queue_decode "$_error")" \
                    "$_case_dir/$_name.stdout" "$_case_dir/$_name.stderr"
            elif [ "$_status" != ok ]; then
                _decoded_error=$(windows_queue_decode "$_error")
                echo "FAIL: $_name Windows launch failed: $_decoded_error" >&2
            else
                if [ "$_exit_matches" -ne 1 ]; then
                    echo "FAIL: $_name expected exit $_want, got $_exit" >&2
                fi
                if [ "$_stdout_matches" -ne 1 ]; then
                    echo "FAIL: $_name stdout mismatch" >&2
                    if command -v diff >/dev/null 2>&1; then
                        diff -u \
                            "$_case_dir/$_name.expected.stdout.cmp" \
                            "$_case_dir/$_name.stdout.cmp" >&2 || true
                    fi
                fi
                if [ "$_stderr_matches" -ne 1 ]; then
                    echo "FAIL: $_name stderr mismatch" >&2
                    if command -v diff >/dev/null 2>&1; then
                        diff -u \
                            "$_case_dir/$_name.expected.stderr.cmp" \
                            "$_case_dir/$_name.stderr.cmp" >&2 || true
                    fi
                fi
            fi
            if [ -s "$_run_shell_stderr" ]; then
                echo "NOTE: $_name shell run diagnostics:" >&2
                sed 's/^/  /' "$_run_shell_stderr" >&2
            fi
        done < "$_assert_failures"
    fi

    IFS='|' read -r _assertion_rows _assert_failed_rows _assert_ms_sum < "$_assert_totals" || return 1
    ran=$((ran + _assertion_rows))
    failed=$((failed + _assert_failed_rows))
    WINDOWS_MANIFEST_ASSERT_MS=$((WINDOWS_MANIFEST_ASSERT_MS + _assert_ms_sum))
    WINDOWS_MANIFEST_ASSERTS=$((WINDOWS_MANIFEST_ASSERTS + _assertion_rows))
    if [ "$_assertion_rows" -ne "$WINDOWS_MANIFEST_QUEUED" ]; then
        echo "FAIL: Windows integration assertion stream contained $_assertion_rows cases for $WINDOWS_MANIFEST_QUEUED queued manifest cases" >&2
        return 1
    fi
    ci_timing_set_now_ms
    _assert_report_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_ASSERT_REPORT_MS=$((_assert_report_finished - _assert_report_started))
    ci_timing_record_elapsed \
        windows-manifest \
        assert-report \
        "$WINDOWS_MANIFEST_ASSERT_REPORT_MS" \
        0
}

windows_legacy_exit_to_unsigned() {
    case "$1" in
        -*) printf '%s\n' "$(( $1 + 4294967296 ))" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

windows_legacy_run_case() {
    _case=$1
    shift
    _legacy_dir="$WORKDIR/windows-runner-differential/$_case"
    mkdir -p "$_legacy_dir"
    _legacy_stdout="$_legacy_dir/$_case.stdout"
    _legacy_stderr="$_legacy_dir/$_case.stderr"
    _legacy_code="$_legacy_dir/$_case.exit"
    _exe_win=$(cygpath -aw "$WORKDIR/$_case/$_case.exe")
    _stdout_win=$(cygpath -aw "$_legacy_stdout")
    _stderr_win=$(cygpath -aw "$_legacy_stderr")
    _code_win=$(cygpath -aw "$_legacy_code")
    WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS=$((WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS + 4))
    WINDOWS_DIFFERENTIAL_POWERSHELL_STARTS=$((WINDOWS_DIFFERENTIAL_POWERSHELL_STARTS + 1))
    set +e
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_LEGACY_RUNNER_WIN" \
        "$_exe_win" "$_stdout_win" "$_stderr_win" "$_code_win" "$@" \
        > "$_legacy_dir/runner.stdout" 2> "$_legacy_dir/runner.stderr"
    _legacy_status=$?
    set -e
    if [ "$_legacy_status" -ne 0 ]; then
        echo "FAIL: Windows legacy differential runner failed for $_case" >&2
        show_stream_if_nonempty stdout "$_legacy_dir/runner.stdout"
        show_stream_if_nonempty stderr "$_legacy_dir/runner.stderr"
        return 1
    fi
    if [ ! -f "$_legacy_code" ]; then
        echo "FAIL: Windows legacy differential runner omitted exit code for $_case" >&2
        return 1
    fi
    _legacy_raw=$(tr -cd '0-9-' < "$_legacy_code")
    if [ -z "$_legacy_raw" ]; then
        echo "FAIL: Windows legacy differential runner wrote an invalid exit code for $_case" >&2
        return 1
    fi
    WINDOWS_LEGACY_STDOUT=$_legacy_stdout
    WINDOWS_LEGACY_STDERR=$_legacy_stderr
    WINDOWS_LEGACY_EXIT=$(windows_legacy_exit_to_unsigned "$_legacy_raw")
}

windows_compare_legacy_case() {
    _case=$1
    shift
    if ! grep -F -x "$_case" "$WINDOWS_QUEUED_CASES" >/dev/null 2>&1; then
        echo "FAIL: Windows runner differential fixture was not linked: $_case" >&2
        return 1
    fi
    if ! windows_result_for_label "$_case"; then
        echo "FAIL: Windows queue omitted differential fixture: $_case" >&2
        return 1
    fi
    if [ "$WINDOWS_RESULT_STATUS" != ok ]; then
        echo "FAIL: Windows queue did not launch differential fixture $_case: $WINDOWS_RESULT_ERROR" >&2
        return 1
    fi
    _queued_exit=$WINDOWS_RESULT_EXIT
    if ! windows_legacy_run_case "$_case" "$@"; then
        return 1
    fi
    if [ "$_queued_exit" != "$WINDOWS_LEGACY_EXIT" ]; then
        echo "FAIL: Windows queued/legacy exit mismatch for $_case: queued=$_queued_exit legacy=$WINDOWS_LEGACY_EXIT" >&2
        return 1
    fi
    if ! cmp -s "$WORKDIR/$_case/$_case.stdout" "$WINDOWS_LEGACY_STDOUT"; then
        echo "FAIL: Windows queued/legacy stdout mismatch for $_case" >&2
        return 1
    fi
    if ! cmp -s "$WORKDIR/$_case/$_case.stderr" "$WINDOWS_LEGACY_STDERR"; then
        echo "FAIL: Windows queued/legacy stderr mismatch for $_case" >&2
        return 1
    fi
}

windows_runner_differential_self_test() {
    # These are ordinary, already-built manifest binaries: successful no-output
    # exit, nonzero exit with stdout + argv, and a runtime trap with stderr.
    # The one-shot path is intentionally exercised only here as an oracle; the
    # corpus itself uses the one persistent queue runner above.
    windows_compare_legacy_case aggregate_globals || return 1
    windows_compare_legacy_case argv alpha beta || return 1
    windows_compare_legacy_case div_zero_trap || return 1

    _mismatch_dir="$WORKDIR/windows-runner-differential/mismatch"
    mkdir -p "$_mismatch_dir"
    printf '%s\n' 'deliberately wrong stdout' > "$_mismatch_dir/argv.expected.stdout"
    printf '%s\n' 'deliberately wrong stderr' > "$_mismatch_dir/div_zero.expected.stderr"
    if cmp -s "$_mismatch_dir/argv.expected.stdout" "$WORKDIR/argv/argv.stdout"; then
        echo "FAIL: Windows queue differential stdout mismatch witness unexpectedly matched" >&2
        return 1
    fi
    if cmp -s "$_mismatch_dir/div_zero.expected.stderr" "$WORKDIR/div_zero_trap/div_zero_trap.stderr"; then
        echo "FAIL: Windows queue differential stderr mismatch witness unexpectedly matched" >&2
        return 1
    fi
    echo "Windows queue runner differential self-test passed."
}

windows_validate_manifest_artifact_counts() {
    _selected_artifacts=$((
        WINDOWS_MANIFEST_DIRECT_OBJECTS +
        WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES +
        WINDOWS_MANIFEST_FORCED_ASSEMBLIES
    ))
    _assembly_selected=$((
        WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES +
        WINDOWS_MANIFEST_FORCED_ASSEMBLIES +
        INTEGRATION_STANDALONE_COMPILES
    ))
    if [ "$_selected_artifacts" -ne "$WINDOWS_MANIFEST_PLAN_ROWS" ] ||
        [ "$WINDOWS_MANIFEST_PLAN_ROWS" -ne "$INTEGRATION_BATCHED_CASES" ]; then
        echo "FAIL: Windows COFF plan accounting mismatch: selected=$_selected_artifacts plan_rows=$WINDOWS_MANIFEST_PLAN_ROWS consumed=$INTEGRATION_BATCHED_CASES" >&2
        return 1
    fi
    if [ "$_assembly_selected" -ne "$WINDOWS_MANIFEST_ASSEMBLES" ]; then
        echo "FAIL: Windows COFF plan launched clang for the wrong artifact set: selected_assembly=$_assembly_selected clang=$WINDOWS_MANIFEST_ASSEMBLES" >&2
        return 1
    fi
    if [ "$WINDOWS_MANIFEST_BATCH_COMPILES" -ne "$INTEGRATION_BATCH_CHUNKS" ]; then
        echo "FAIL: Windows COFF batch process accounting mismatch: plan=$WINDOWS_MANIFEST_BATCH_COMPILES chunks=$INTEGRATION_BATCH_CHUNKS" >&2
        return 1
    fi
    if [ $((INTEGRATION_BATCHED_CASES + INTEGRATION_STANDALONE_COMPILES)) -ne "$WINDOWS_MANIFEST_LINKS" ] ||
        [ $((WINDOWS_MANIFEST_LINKS + INTEGRATION_DEDUP_ALIAS_CASES)) -ne "$WINDOWS_MANIFEST_QUEUED" ]; then
        echo "FAIL: Windows COFF plan did not account for every unique build and queued manifest case (batched=$INTEGRATION_BATCHED_CASES standalone=$INTEGRATION_STANDALONE_COMPILES links=$WINDOWS_MANIFEST_LINKS aliases=$INTEGRATION_DEDUP_ALIAS_CASES queued=$WINDOWS_MANIFEST_QUEUED)" >&2
        return 1
    fi
    _fallback_reason_rows=0
    if [ -s "$WINDOWS_COFF_FALLBACK_REASONS" ]; then
        _fallback_reason_rows=$(wc -l < "$WINDOWS_COFF_FALLBACK_REASONS" | tr -d ' ')
    fi
    if [ "$_fallback_reason_rows" -ne "$WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES" ]; then
        echo "FAIL: Windows COFF fallback reason accounting mismatch: reasons=$_fallback_reason_rows fallbacks=$WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES" >&2
        return 1
    fi
}

windows_print_manifest_summary() {
    _legacy_launch_cygpath=$((WINDOWS_MANIFEST_QUEUED * 4))
    echo "Windows integration process/timing summary:"
    echo "  manifest cases queued: $WINDOWS_MANIFEST_QUEUED (unique_builds=$INTEGRATION_UNIQUE_BUILDS dedup_aliases=$INTEGRATION_DEDUP_ALIAS_CASES)"
    echo "  process starts: legacy powershell=$WINDOWS_MANIFEST_QUEUED, queued powershell=$WINDOWS_MANIFEST_POWERSHELL_STARTS, child executables=$WINDOWS_SUMMARY_CHILD_STARTS"
    echo "  queue encoding helper processes: 0"
    echo "  cygpath conversions: legacy launch-path lower bound=$_legacy_launch_cygpath, queued manifest=$WINDOWS_MANIFEST_CYGPATH_CONVERSIONS"
    echo "  assemble scheduler: requests=$WINDOWS_ASSEMBLE_REQUESTS asm=$WINDOWS_MANIFEST_ASSEMBLES cdeps=$WINDOWS_MANIFEST_CDEP_ASSEMBLES jobs=$WINDOWS_ASSEMBLE_JOBS peak=${WINDOWS_ASSEMBLE_SUMMARY_PEAK_CONCURRENCY:-0} wall_ms=$WINDOWS_MANIFEST_ASSEMBLE_WALL_MS child_ms=$WINDOWS_MANIFEST_ASSEMBLE_MS powershell=$WINDOWS_ASSEMBLE_POWERSHELL_STARTS"
    echo "  links: requests=$WINDOWS_LINK_SUMMARY_REQUESTS child_starts=$WINDOWS_LINK_SUMMARY_CHILD_STARTS launch_failures=$WINDOWS_LINK_SUMMARY_LAUNCH_FAILURES failed=$WINDOWS_LINK_SUMMARY_FAILED_PROCESSES missing_outputs=$WINDOWS_LINK_SUMMARY_MISSING_OUTPUTS"
    echo "  link scheduler: jobs=$WINDOWS_LINK_SUMMARY_JOBS peak=$WINDOWS_LINK_SUMMARY_PEAK_CONCURRENCY wall_ms=$WINDOWS_MANIFEST_LINK_WALL_MS child_ms=$WINDOWS_MANIFEST_LINK_MS powershell=$WINDOWS_LINK_POWERSHELL_STARTS"
    echo "  runner scheduler: jobs=$WINDOWS_SUMMARY_JOBS peak=$WINDOWS_SUMMARY_PEAK_CONCURRENCY wall_ms=$WINDOWS_SUMMARY_ELAPSED_MS child_ms=$WINDOWS_SUMMARY_CHILD_MS"
    echo "  queue: requests=$WINDOWS_SUMMARY_REQUESTS launch_failures=$WINDOWS_SUMMARY_LAUNCH_FAILURES timeouts=$WINDOWS_SUMMARY_TIMEOUTS elapsed_ms=$WINDOWS_SUMMARY_ELAPSED_MS"
    echo "  COFF plan: rows=$WINDOWS_MANIFEST_PLAN_ROWS direct_objects=$WINDOWS_MANIFEST_DIRECT_OBJECTS compiler_fallback_assembly=$WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES forced_assertion_assembly=$WINDOWS_MANIFEST_FORCED_ASSEMBLIES"
    echo "  direct-object render: count=$WINDOWS_MANIFEST_DIRECT_OBJECTS timing=included-in-batch-compile batch_compile_ms=$WINDOWS_MANIFEST_BATCH_COMPILE_MS"
    echo "  assembly: compiler_fallback_ms=$WINDOWS_MANIFEST_FALLBACK_ASSEMBLE_MS forced_assertion_ms=$WINDOWS_MANIFEST_FORCED_ASSEMBLE_MS standalone_replay_ms=$WINDOWS_MANIFEST_STANDALONE_ASSEMBLE_MS clang_launches=$WINDOWS_MANIFEST_ASSEMBLES"
    if [ -s "$WINDOWS_COFF_FALLBACK_REASONS" ]; then
        echo "  compiler fallback reasons:"
        LC_ALL=C sort "$WINDOWS_COFF_FALLBACK_REASONS" |
            uniq -c |
            while read -r _reason_count _reason; do
                echo "    $_reason=$_reason_count"
            done
    fi
    echo "  forced assembly reasons: stdlib-helper-symbol-elision=2 u64-float-cast-instruction-shape=1"
    echo "  phase_ms: batch_compile=$WINDOWS_MANIFEST_BATCH_COMPILE_MS standalone_compile=$WINDOWS_MANIFEST_COMPILE_MS plan_process=$WINDOWS_MANIFEST_PLAN_PROCESS_MS assemble=$WINDOWS_MANIFEST_ASSEMBLE_MS assemble_scheduler=$WINDOWS_MANIFEST_ASSEMBLE_WALL_MS assemble_helper=$WINDOWS_MANIFEST_ASSEMBLE_HELPER_MS link_child_sum=$WINDOWS_MANIFEST_LINK_MS link_scheduler=$WINDOWS_MANIFEST_LINK_WALL_MS link_helper=$WINDOWS_MANIFEST_LINK_HELPER_MS link_plan=$WINDOWS_MANIFEST_LINK_PREP_MS link_result_process=$WINDOWS_MANIFEST_LINK_RESULT_PROCESS_MS link_attribution=$WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS runner=$WINDOWS_MANIFEST_RUN_MS result_process=$WINDOWS_MANIFEST_RESULT_PROCESS_MS assertions=$WINDOWS_MANIFEST_ASSERT_MS assertion_report=$WINDOWS_MANIFEST_ASSERT_REPORT_MS"
    echo "  phase_counts: batch_compile=$WINDOWS_MANIFEST_BATCH_COMPILES standalone_compile=$WINDOWS_MANIFEST_COMPILES assemble=$WINDOWS_MANIFEST_ASSEMBLES link=$WINDOWS_MANIFEST_LINKS assert=$WINDOWS_MANIFEST_ASSERTS"
    echo "  differential oracle: legacy powershell=$WINDOWS_DIFFERENTIAL_POWERSHELL_STARTS cygpath=$WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS"
}

# Batched compile pre-pass. Every manifest case is a compile-success
# case -- the third field is the *program's* exit code, not a compile
# expectation -- so the only thing that partitions them is whether the case
# opted into the on-disk stdlib layout and whether it pins an optimization
# level. Each exact argv group compiles in bounded `compile --batch` chunks
# instead of one compiler process per case.
#
# On Linux the pre-pass populates per-case assembly. On Windows each row asks
# the compiler for both destinations and consumes its deterministic COFF plan:
# linkable rows write an object directly, while explicit text assertions and
# compiler-classified fallbacks write assembly for the existing clang path.
# Failed chunks remove both candidate outputs, so the case loop still replays
# those sources standalone with source-specific diagnostics.
INTEGRATION_BATCH_SIZE=${TYPELISP_INTEGRATION_BATCH_SIZE:-20}
INTEGRATION_BATCH_CHUNKS=0
INTEGRATION_BATCH_FAILED_CHUNKS=0
INTEGRATION_BATCHED_CASES=0
INTEGRATION_STANDALONE_COMPILES=0


# Stage every unique build's source and dependencies once, before anything
# compiles them: the batch pre-pass and the case loop read the same staged tree.
# The plan is built without forking (see stage_plan_copy), then one helper
# process creates the directories and writes the files.
STAGE_PLAN="$WORKDIR/stage.plan"

integration_stage_plan() {
    : > "$STAGE_PLAN" || return 1
    _stage_manifest=${MANIFEST_UNIQUE:-$NORMALIZED_MANIFEST}
    [ -f "$_stage_manifest" ] || _stage_manifest=$NORMALIZED_MANIFEST
    while IFS='|' read -r _s_name _s_source _s_want _s_stdout _s_args _s_deps _s_extra _s_suite || [ -n "$_s_name" ]; do
        case "$_s_name" in
            "" | \#*) continue ;;
        esac
        manifest_row_split_opt_level "${_s_extra:-}" || return 1
        _s_stage=0
        case "$MANIFEST_ROW_EXTRA" in
            stage-stdlib | stage-stdlib+expected-stderr:*) _s_stage=1 ;;
        esac
        _s_source_path="$ROOT/$_s_source"
        _s_case_dir="$WORKDIR/$_s_name"
        stage_plan_copy "$_s_source_path" "$_s_case_dir/$_s_name.tl" || return 1
        case "$_s_deps" in
            "" | -) continue ;;
        esac
        for _s_dep in $_s_deps; do
            copy_dep "$_s_dep" "${_s_source_path%/*}" "$_s_case_dir" "$_s_stage" \
                || return 1
        done
    done < "$_stage_manifest" || return 1
}

# Build the staging helper once per run with the host toolchain the manifest
# programs use, so every plan it executes costs one process, not a compile.
integration_stage_helper_build() {
    _helper_dir="$WORKDIR/stage-helper"
    _helper_asm="$_helper_dir/stage.s"
    [ -d "$_helper_dir" ] || mkdir -p "$_helper_dir" || return 1
    if [ "$HOST_OS" = windows ]; then
        STAGE_HELPER="$_helper_dir/stage.exe"
        run_build "$COMPILER" compile tools/integration-staging/stage.tl \
            --target windows-x86_64 --cfg windows -o "$_helper_asm" \
            > "$_helper_dir/build.stdout" 2> "$_helper_dir/build.stderr" || return 1
    else
        STAGE_HELPER="$_helper_dir/stage"
        run_build "$COMPILER" compile tools/integration-staging/stage.tl \
            -o "$_helper_asm" \
            > "$_helper_dir/build.stdout" 2> "$_helper_dir/build.stderr" || return 1
    fi
    if [ "$build_rc" -ne 0 ]; then
        echo "FAIL: integration staging helper compile failed" >&2
        show_build_streams "$_helper_dir/build.stdout" "$_helper_dir/build.stderr"
        return 1
    fi
    if [ "$HOST_OS" = windows ]; then
        assemble_link_windows "$_helper_asm" "$_helper_dir/stage.obj" \
            "$STAGE_HELPER" integration-staging
    else
        _helper_stdlib=$(linux_stdlib_archive_for_asm "$_helper_asm" "${COMPILER:-}")
        as "$_helper_asm" -o "$_helper_dir/stage.o" &&
            if [ -n "$_helper_stdlib" ]; then
                ld "$_helper_dir/stage.o" -z noexecstack --gc-sections -z start-stop-gc --start-group "$_helper_stdlib" --end-group -o "$STAGE_HELPER" -e _tl_start
            else
                ld "$_helper_dir/stage.o" -o "$STAGE_HELPER" -e _tl_start
            fi || {
            echo "FAIL: integration staging helper link failed" >&2
            return 1
        }
    fi
}

integration_stage_copy() {
    stage_plan_path "$STAGE_PLAN" || return 1
    "$STAGE_HELPER" "$STAGE_PLAN_PATH"
}

# The helper's plan contract, checked with the binary the corpus is staged by:
# order-preserving rewrites (A, B, A ends at A), repeated pairs, empty sources,
# nested and unusual paths, and a failing line that names its source or
# destination and stops the plan. The plan writer's own refusals come last.
integration_stage_self_test() {
    _t="$WORKDIR/stage-self-test"
    _tp="${_t#"$ROOT"/}"
    _odd="sp ace'q$(printf '\303\251')"
    mkdir -p "$_t/src" || return 1
    printf 'A\n' > "$_t/src/a.tl" || return 1
    printf 'B\n' > "$_t/src/b.tl" || return 1
    : > "$_t/src/empty.tl" || return 1
    printf 'odd\n' > "$_t/src/$_odd.tl" || return 1
    : > "$_t/src/not-a-dir" || return 1
    : > "$_t/empty.plan" || return 1
    "$STAGE_HELPER" "$_tp/empty.plan" || {
        echo "FAIL: staging helper rejected an empty plan" >&2
        return 1
    }
    printf '%s\t%s\n' \
        "$_tp/src/a.tl" "$_tp/out/n/d.tl" \
        "$_tp/src/b.tl" "$_tp/out/n/d.tl" \
        "$_tp/src/a.tl" "$_tp/out/n/d.tl" \
        "$_tp/src/b.tl" "$_tp/out/r.tl" \
        "$_tp/src/b.tl" "$_tp/out/r.tl" \
        "$_tp/src/empty.tl" "$_tp/out/e.tl" \
        "$_tp/src/$_odd.tl" "$_tp/out/sp ace/$_odd.tl" \
        > "$_t/ok.plan" || return 1
    "$STAGE_HELPER" "$_tp/ok.plan" || {
        echo "FAIL: staging helper rejected a valid plan" >&2
        return 1
    }
    if ! cmp -s "$_t/src/a.tl" "$_t/out/n/d.tl" ||
        ! cmp -s "$_t/src/b.tl" "$_t/out/r.tl" ||
        [ ! -f "$_t/out/e.tl" ] || [ -s "$_t/out/e.tl" ] ||
        ! cmp -s "$_t/src/$_odd.tl" "$_t/out/sp ace/$_odd.tl"; then
        echo "FAIL: staging helper wrote the wrong bytes for a valid plan" >&2
        return 1
    fi
    for _case in \
        "missing|$_tp/src/missing.tl|$_tp/out/m.tl|plan line 2: cannot read $_tp/src/missing.tl" \
        "write|$_tp/src/a.tl|$_tp/src/not-a-dir/x.tl|plan line 2: cannot write $_tp/src/not-a-dir/x.tl"; do
        _name=${_case%%|*}
        _rest=${_case#*|}
        _from=${_rest%%|*}
        _rest=${_rest#*|}
        _to=${_rest%%|*}
        _want=${_rest#*|}
        printf '%s\t%s\n' \
            "$_tp/src/a.tl" "$_tp/out/$_name-first.tl" \
            "$_from" "$_to" \
            "$_tp/src/a.tl" "$_tp/out/$_name-after.tl" \
            > "$_t/$_name.plan" || return 1
        if "$STAGE_HELPER" "$_tp/$_name.plan" 2> "$_t/$_name.stderr"; then
            echo "FAIL: staging helper accepted a plan with a $_name failure" >&2
            return 1
        fi
        if ! grep -F -q -- "$_want" "$_t/$_name.stderr" ||
            [ ! -f "$_t/out/$_name-first.tl" ] || [ -e "$_t/out/$_name-after.tl" ]; then
            echo "FAIL: staging helper $_name failure was not reported in plan order" >&2
            cat "$_t/$_name.stderr" >&2
            return 1
        fi
    done
    printf 'no tab here\n' > "$_t/malformed.plan" || return 1
    if "$STAGE_HELPER" "$_tp/malformed.plan" 2> "$_t/malformed.stderr" ||
        ! grep -F -q 'plan line 1: expected `source<TAB>destination`' "$_t/malformed.stderr"; then
        echo "FAIL: staging helper accepted a malformed plan line" >&2
        return 1
    fi
    if (stage_plan_path "/elsewhere/x.tl") 2> /dev/null ||
        (stage_plan_path "$ROOT/a${STAGE_TAB}b.tl") 2> /dev/null; then
        echo "FAIL: the staging plan accepted a path it cannot represent" >&2
        return 1
    fi
}

integration_stage_corpus() {
    # ci_timing_run disables errexit, including for nested shell functions.
    ci_timing_run manifest stage-helper integration_stage_helper_build || return 1
    integration_stage_self_test || return 1
    ci_timing_run manifest stage-plan integration_stage_plan || return 1
    ci_timing_run manifest stage-copy integration_stage_copy
}


integration_batch_precompile() {
    [ "$INTEGRATION_BATCH_SIZE" -gt 0 ] || return 0
    ci_timing_run manifest batch-queue integration_batch_queue || return 1
    _pool_queue="$WORKDIR/batch-pool.queue"
    if [ -s "$_pool_queue" ]; then
        integration_batch_run_pool "$_pool_queue" || return 1
    fi
    echo "[integration] batched compile: $INTEGRATION_BATCH_CHUNKS chunk(s)" \
        "of up to $INTEGRATION_BATCH_SIZE, $INTEGRATION_BATCH_FAILED_CHUNKS failed"
    if [ "$INTEGRATION_POOL_PEAK_BYTES" -gt 0 ]; then
        echo "[integration] batch pool: ${INTEGRATION_POOL_WALL_MS}ms wall;" \
            "largest chunk $((INTEGRATION_POOL_PEAK_BYTES / 1048576)) MiB" \
            "($INTEGRATION_POOL_PEAK_LABEL) of a $INTEGRATION_POOL_CHUNK_CAP_MIB MiB cap"
    fi
}

if [ "$HOST_OS" = windows ]; then
    INTEGRATION_BATCH_TARGET_ARGS="--target windows-x86_64 --cfg windows"
else
    INTEGRATION_BATCH_TARGET_ARGS=
fi

# The batch route must produce the same assembly as the per-case route, or the
# amortization is buying a different compile. Prove it on one case per group
# rather than trusting the argv construction above.
integration_batch_sentinel() {
    [ "$INTEGRATION_BATCH_SIZE" -gt 0 ] || return 0
    # Windows plan rows intentionally select either object or assembly. Their
    # object/forced-assembly differential lives in the focused COFF verifier;
    # this legacy assembly byte comparison remains the Linux batch oracle.
    [ "$HOST_OS" = linux ] || return 0
    for _group in $INTEGRATION_BATCH_GROUPS; do
        _list="$WORKDIR/batch-$_group-1.list"
        [ -s "$_list" ] || continue
        # The final entry has the most warmed-session predecessors available in
        # a chunk. Selecting it exercises state contamination at a cost of one
        # standalone compile per group.
        _entry=$(integration_batch_sentinel_entry "$_list")
        _sent_src=${_entry%%|*}
        _sent_asm=${_entry#*|}
        [ -s "$_sent_asm" ] || continue
        _sent_ref="$WORKDIR/batch-$_group.sentinel.s"
        integration_batch_group_run "$_group" "$COMPILER" compile \
            "$_sent_src" -o "$_sent_ref" \
            > "$WORKDIR/batch-$_group.sentinel.stdout" \
            2> "$WORKDIR/batch-$_group.sentinel.stderr"
        if ! cmp -s "$_sent_asm" "$_sent_ref"; then
            echo "FAIL: batched and standalone assembly differ for $_sent_src" >&2
            echo "  batch:      $_sent_asm" >&2
            echo "  standalone: $_sent_ref" >&2
            exit 1
        fi
        echo "[integration] batch/standalone assembly identical for $_sent_src"
    done
}

# Staging stays inside the batch-compile phase row it has always been part of.
integration_source_location_self_test() (
    # Exercise the real assertion on every anchored row for this host. Planted
    # failures stay in private logs and do not enter the corpus timing/counts.
    TYPELISP_CI_TIMING=0
    sl_checked=0
    while IFS='|' read -r sl_name sl_source sl_want sl_stdout sl_args sl_deps sl_extra sl_suite; do
        case "$sl_extra" in *'@loc{'*) ;; *) continue ;; esac
        sl_spec=${sl_extra#*expected-stderr:}
        sl_token=${sl_spec#*@loc\{}
        sl_token=${sl_token%%\}*}
        sl_location=$(resolve_source_locations "@loc{$sl_token}") || exit 1
        sl_column=${sl_location##*:}
        sl_prefix=${sl_location%:*}
        sl_line=${sl_prefix##*:}
        sl_dir="$WORKDIR/source-location-self-test/$sl_name"
        mkdir -p "$sl_dir" || exit 1
        : > "$sl_dir/stdout" || exit 1
        : > "$sl_dir/shell-stderr" || exit 1
        write_expected_stream "$sl_spec" "$sl_dir/correct" || exit 1
        for sl_mutation in correct wrong-line wrong-column; do
            case "$sl_mutation" in
                correct) cp "$sl_dir/correct" "$sl_dir/actual" || exit 1; sl_failures=0 ;;
                wrong-line)
                    sed "s/:$sl_line:$sl_column:/:$((sl_line + 1)):$sl_column:/" "$sl_dir/correct" > "$sl_dir/actual" || exit 1
                    sl_failures=1 ;;
                wrong-column)
                    sed "s/:$sl_line:$sl_column:/:$sl_line:$((sl_column + 1)):/" "$sl_dir/correct" > "$sl_dir/actual" || exit 1
                    sl_failures=1 ;;
            esac
            got=$sl_want
            failed=0
            ran=0
            case_timed_out=0
            assert_manifest_case "$sl_name" "$sl_want" "$sl_stdout" "$sl_spec" \
                "$sl_dir/unused.s" "$sl_dir/stdout" "$sl_dir/actual" "$sl_dir" "$sl_dir/shell-stderr" \
                > "$sl_dir/$sl_mutation.log" 2>&1 || exit 1
            [ "$ran" -eq 1 ] && [ "$failed" -eq "$sl_failures" ] || {
                echo "source location assertion self-test failed: $sl_name $sl_mutation" >&2
                exit 1
            }
            sl_checked=$((sl_checked + 1))
        done
    done < "$NORMALIZED_MANIFEST"
    echo "native source location assertions passed $sl_checked mutation/control cases"
)

integration_prepare() {
    integration_stage_corpus || return 1
    integration_source_location_self_test || exit 1
    integration_batch_precompile
}

# Exercise the actual preparation chain without another compiler build. Each
# child has ordinary errexit semantics, its own timing file and phase trace;
# only leaf work is planted. The real staging self-test rejects the deliberately
# broken empty-plan helper, as in #9368's original reproduction.
run_preparation_failure_self_test() (
    prep_root="$WORKDIR/preparation-failure-self-test"
    prep_failures='success helper-build helper-assemble helper-link self-test stage-plan dependency stage-copy location batch-queue pool'
    prep_hosts='linux windows'
    prep_count=46
    if [ "$HOST_OS" = windows ]; then prep_hosts=windows; prep_count=24; fi
    # Create the independent case directories together. Every child still runs
    # with ordinary errexit and writes only its own streams and timing rows.
    set --
    for prep_host in $prep_hosts; do
        for prep_timing in 0 1; do
            for prep_failure in $prep_failures; do
                set -- "$@" "$prep_root/$prep_host-$prep_timing-$prep_failure/stage-helper"
            done
        done
    done
    mkdir -p "$@" "$prep_root/windows-0-invalid-result-plan" "$prep_root/windows-1-invalid-result-plan"
    printf 'host\ttiming\tfailure\texit\n' > "$prep_root/results.tsv"
    : > "$prep_root/expected-traces"
    : > "$prep_root/actual-traces"
    for prep_host in $prep_hosts; do
        for prep_timing in 0 1; do
            for prep_failure in $prep_failures; do
                prep_dir="$prep_root/$prep_host-$prep_timing-$prep_failure"
                (
                    set -e
                    HOST_OS=$prep_host
                    WORKDIR=$prep_dir
                    STAGE_PLAN="$WORKDIR/stage.plan"
                    NORMALIZED_MANIFEST="$WORKDIR/manifest"
                    prep_deps=-
                    [ "$prep_failure" != dependency ] || prep_deps=missing-regression.tl
                    printf 'fixture|tests/integration/exit_42.tl|42|-|-|%s\n' \
                        "$prep_deps" > "$NORMALIZED_MANIFEST"
                    TYPELISP_CI_TIMING=$prep_timing
                    TYPELISP_CI_TIMING_GATE=preparation-failure-self-test
                    # The real timer runs below; initialize its private artifact
                    # directly instead of mkdir/dirname for an existing directory.
                    TYPELISP_CI_TIMING_FILE="$WORKDIR/timing.tsv"
                    TYPELISP_CI_TIMING_HOST=$HOST_OS
                    if [ "$prep_timing" -eq 1 ]; then
                        printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\n' > "$TYPELISP_CI_TIMING_FILE"
                    fi
                    INTEGRATION_BATCH_SIZE=1
                    INTEGRATION_BATCH_CHUNKS=0
                    INTEGRATION_BATCH_FAILED_CHUNKS=0
                    INTEGRATION_POOL_PEAK_BYTES=0
                    preparation_fixture_step() {
                        printf '%s\n' "$1" >> "$WORKDIR/trace" || exit 2
                        printf '%s\t%s\n' "${WORKDIR##*/}" "$1" >> "$prep_root/actual-traces" || exit 2
                        [ "$prep_failure" != "$1" ]
                    }
                    run_build() {
                        if preparation_fixture_step helper-build; then
                            build_rc=0
                        else
                            build_rc=1
                        fi
                    }
                    as() { preparation_fixture_step helper-assemble; }
                    ld() {
                        STAGE_HELPER=preparation_fixture_helper
                        preparation_fixture_step helper-link
                    }
                    assemble_link_windows() { as && ld; }
                    preparation_fixture_helper() {
                        if [ "$prep_failure" = self-test ]; then
                            preparation_fixture_step self-test
                        else
                            preparation_fixture_step stage-copy
                        fi
                    }
                    if [ "$prep_failure" != self-test ]; then
                        integration_stage_self_test() { preparation_fixture_step self-test; }
                    fi
                    stage_plan_copy() {
                        preparation_fixture_step stage-plan || return 1
                        printf '%s\t%s\n' "$1" "$2" >> "$STAGE_PLAN"
                    }
                    integration_source_location_self_test() { preparation_fixture_step location; }
                    integration_batch_queue() {
                        preparation_fixture_step batch-queue || return 1
                        printf 'batch-embedded-1|64\n' > "$WORKDIR/batch-pool.queue"
                    }
                    integration_batch_run_pool() { preparation_fixture_step pool; }
                    ci_timing_run manifest batch-compile integration_prepare
                    printf 'continued\n' >> "$WORKDIR/trace" || exit 2
                    printf '%s\tcontinued\n' "${WORKDIR##*/}" >> "$prep_root/actual-traces" || exit 2
                ) > "$prep_dir/stdout" 2> "$prep_dir/stderr" &
                prep_pid=$!
                prep_rc=0
                wait "$prep_pid" || prep_rc=$?
                printf '%s\t%s\t%s\t%s\n' "$prep_host" "$prep_timing" \
                    "$prep_failure" "$prep_rc" >> "$prep_root/results.tsv"
                prep_stop=$prep_failure
                [ "$prep_failure" != dependency ] || prep_stop=stage-plan
                : > "$prep_dir/expected-trace"
                for prep_phase in helper-build helper-assemble helper-link self-test stage-plan stage-copy location batch-queue pool continued; do
                    printf '%s\n' "$prep_phase" >> "$prep_dir/expected-trace"
                    printf '%s\t%s\n' "${prep_dir##*/}" "$prep_phase" >> "$prep_root/expected-traces"
                    [ "$prep_phase" != "$prep_stop" ] || break
                done
                [ "$prep_timing" -ne 0 ] || [ ! -e "$prep_dir/timing.tsv" ] || exit 1
            done
        done
    done
    # A successful Windows compile can still return an invalid result plan.
    # Settling must preserve the real plan validator's refusal rather than
    # replacing it with the chunk's earlier successful compile status.
    for prep_timing in 0 1; do
        prep_dir="$prep_root/windows-$prep_timing-invalid-result-plan"
        (
            set -e
            HOST_OS=windows
            WORKDIR=$prep_dir
            TYPELISP_CI_TIMING=$prep_timing
            TYPELISP_CI_TIMING_GATE=preparation-failure-self-test
            TYPELISP_CI_TIMING_FILE="$WORKDIR/timing.tsv"
            TYPELISP_CI_TIMING_HOST=$HOST_OS
            if [ "$prep_timing" -eq 1 ]; then
                printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\n' > "$TYPELISP_CI_TIMING_FILE"
            fi
            printf '0\n' > "$WORKDIR/batch-embedded-1.status"
            printf '0\n' > "$WORKDIR/batch-embedded-1.elapsed-ms"
            printf 'invalid\n' > "$WORKDIR/batch-embedded-1.plan"
            printf 'invalid\n' > "$WORKDIR/batch-embedded-1.list"
            ci_timing_run manifest batch-settle integration_batch_settle_chunk \
                "$WORKDIR/batch-embedded-1.list" embedded-1 ''
            : > "$WORKDIR/continued"
        ) > "$prep_dir/stdout" 2> "$prep_dir/stderr" &
        prep_pid=$!
        prep_rc=0
        wait "$prep_pid" || prep_rc=$?
        if [ "$prep_rc" -ne 1 ] || [ -e "$prep_dir/continued" ]; then
            echo 'FAIL: batch settlement lost the Windows plan validator failure' >&2
            cat "$prep_dir/stderr" >&2
            exit 1
        fi
        printf 'windows\t%s\tinvalid-result-plan\t%s\n' "$prep_timing" "$prep_rc" >> "$prep_root/results.tsv"
    done
    # Compare the complete tagged trace as bytes once, retaining case identity,
    # order and every phase. Read all private timing/diagnostic artifacts in one
    # assertion process, with the original fatal-location exception.
    cmp -s "$prep_root/expected-traces" "$prep_root/actual-traces" || {
        echo 'FAIL: preparation phase trace mismatch (case/phase follows)' >&2
        diff -u "$prep_root/expected-traces" "$prep_root/actual-traces" >&2 || true
        exit 1
    }
    awk -F '\t' -v root="$prep_root" -v count="$prep_count" '
        function fail(message) { print "FAIL: preparation " id ": " message > "/dev/stderr"; bad = 1 }
        NR == 1 { next }
        {
            id = $1 "-" $2 "-" $3
            if (seen[id]++ || $4 != ($3 == "success" ? 0 : 1)) fail("wrong status or duplicate case")
            cases++
            path = root "/" id "/stderr"
            diagnostic = ""
            if ($3 == "self-test") diagnostic = "FAIL: staging helper rejected an empty plan"
            else if ($3 == "invalid-result-plan") diagnostic = "FAIL: invalid Windows COFF result plan"
            if (diagnostic != "") {
                found = 0
                while ((rc = (getline line < path)) > 0) if (index(line, diagnostic)) found = 1
                close(path)
                if (rc < 0 || !found) fail("lost diagnostic: " diagnostic)
            }
            if ($2 != 1) next
            path = root "/" id "/timing.tsv"
            rows = failed = outer = status = 0
            while ((rc = (getline line < path)) > 0) {
                if (++rows == 1) continue
                split(line, field, "\t")
                if (failed && field[5] == 0) fail("successful timing after failure")
                if (field[5] != 0) failed = 1
                phase = ($3 == "invalid-result-plan" ? "batch-settle" : "batch-compile")
                if (field[3] == phase) { outer++; status = field[5] }
                if ($3 == "invalid-result-plan" && (field[3] != phase || field[5] != 1)) fail("wrong settlement timing")
            }
            close(path)
            if (rc < 0 || rows < 1 || outer != ($3 == "location" ? 0 : 1) ||
                ($3 != "location" && status != ($3 == "success" ? 0 : 1))) fail("misleading or missing timing")
            if ($3 == "invalid-result-plan" && rows != 2) fail("wrong settlement row count")
        }
        END { if (cases != count) { print "FAIL: preparation case inventory" > "/dev/stderr"; bad = 1 }; exit bad }
    ' "$prep_root/results.tsv" || exit 1
    echo "verify-integration preparation failure self-test passed ($prep_count host/timing/control cases)"
)

if [ "$SELF_TEST_BATCH_OBSERVABILITY" -eq 1 ]; then
    _integration_physical_host=$(uname -s) || exit $?
    _integration_cost_gate=${TYPELISP_CI_TIMING_GATE:-}
    _integration_cost_file=${TYPELISP_CI_TIMING_FILE:-}
    _integration_cost_enabled=${TYPELISP_CI_TIMING:-0}
    _integration_cost_host=${TYPELISP_CI_TIMING_HOST:-$HOST_OS}
    ci_timing_set_now_ms
    _integration_fixture_started=$CI_TIMING_NOW_MS
    sh "$ROOT/scripts/verify-native-link-failures.sh" "$WORKDIR/native-link-failure-self-test"
    run_preparation_failure_self_test
    ci_timing_set_now_ms
    _integration_matrix_started=$CI_TIMING_NOW_MS
    run_bounded_completion_self_test
    ci_timing_set_now_ms
    _integration_matrix_finished=$CI_TIMING_NOW_MS
    run_batch_observability_self_test
    ci_timing_set_now_ms
    TYPELISP_CI_TIMING_GATE=$_integration_cost_gate
    TYPELISP_CI_TIMING_FILE=$_integration_cost_file
    TYPELISP_CI_TIMING=$_integration_cost_enabled
    TYPELISP_CI_TIMING_HOST=$_integration_cost_host
    . "$ROOT/scripts/lib-bounded-completion-fixtures.sh"
    bounded_completion_fixture_cost integration \
        "$((_integration_matrix_started - _integration_fixture_started + CI_TIMING_NOW_MS - _integration_matrix_finished))" \
        "$((_integration_matrix_finished - _integration_matrix_started))" || exit 1
    if [ "$_integration_physical_host" = Linux ]; then
        ci_timing_run linux-entry-callers failure-controls \
            sh "$ROOT/scripts/verify-linux-entry-callers.sh" "$WORKDIR/linux-entry-caller-self-test" || exit $?
    fi
    exit 0
fi

if [ "$BACKEND_CMP_MEM_FOLD_PARITY_ONLY" -eq 1 ]; then
    if [ "$HOST_OS" = linux ]; then
        run_linux_fixture_cases --only backend-cmp-mem-fold-parity
    else
        run_backend_cmp_mem_fold_parity_fixtures
    fi
    exit 0
fi

# The wide-struct literal declarations are generated, not committed.
awk -f "$ROOT/tests/integration/wide_struct_literal_decls.awk" > "$WORKDIR/wide_struct_literal_decls.tl"
mv "$WORKDIR/wide_struct_literal_decls.tl" "$ROOT/tests/integration/wide_struct_literal_decls.tl"

ci_timing_run manifest shard integration_select_shard || exit 1
ci_timing_run manifest validate validate_manifest
if [ "$VALIDATE_MANIFEST_ONLY" -eq 1 ]; then
    echo "integration manifest validation passed for $HOST_OS"
    exit 0
fi
ci_timing_run manifest dedup integration_build_dedup_plan || exit 1
echo "[integration] build deduplication: $INTEGRATION_UNIQUE_BUILDS unique build(s) for $INTEGRATION_TOTAL_CASES case(s) ($INTEGRATION_DEDUP_ALIAS_CASES deduplicated alias(es))"

ci_timing_run manifest batch-compile integration_prepare
integration_batch_sentinel

# Create per-case output directories for deduplicated aliases in one batch so
# neither Linux nor Windows creates them in per-row loops.
if [ "$INTEGRATION_DEDUP_ALIAS_CASES" -gt 0 ]; then
    awk -F '|' -v wr="target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX" \
        '$1 != $2 { print wr "/" $2 }' "$MANIFEST_PLAN" |
        xargs mkdir -p || exit 1
fi

failed=0
ran=0

if [ "$HOST_OS" = windows ]; then
    if ! windows_build_and_assemble_manifest; then
        exit 1
    fi
fi

while IFS='|' read -r owner name source want stdout_spec runtime_args deps extra suite_members || [ -n "$name" ]; do
    [ "$HOST_OS" != windows ] || break
    case "$name" in
        "" | \#*) continue ;;
    esac

    expected_stderr_spec=-
    stage_stdlib=0
    manifest_row_split_opt_level "${extra:-}"
    opt_level=$MANIFEST_ROW_OPT_LEVEL
    backend_mode=$MANIFEST_ROW_BACKEND_MODE
    case "$MANIFEST_ROW_EXTRA" in
        "") ;;
        stage-stdlib) stage_stdlib=1 ;;
        stage-stdlib+expected-stderr:*)
            stage_stdlib=1
            expected_stderr_spec=${MANIFEST_ROW_EXTRA#stage-stdlib+expected-stderr:}
            ;;
        expected-stderr:*) expected_stderr_spec=${MANIFEST_ROW_EXTRA#expected-stderr:} ;;
    esac
    if [ -n "$opt_level" ]; then
        opt_level_args="--opt-level $opt_level"
    else
        opt_level_args=
    fi
    if [ -n "$backend_mode" ]; then
        opt_level_args="${opt_level_args:+$opt_level_args }--backend-mode $backend_mode"
    fi

    case_dir="$WORKDIR/$name"
    owner_dir="$WORKDIR/$owner"
    asm="$owner_dir/$owner.s"
    bin="$owner_dir/$owner"
    stdout="$case_dir/$name.stdout"
    stderr="$case_dir/$name.stderr"
    run_shell_stderr="$case_dir/$name.run-shell.stderr"

    if [ "$HOST_OS" = windows ]; then
        continue
    else
        if [ "$name" = "$owner" ]; then
            work_src_rel="target/integration-verify/$HOST_OS$INTEGRATION_SHARD_SUFFIX/$name/$name.tl"
            work_src="$case_dir/$name.tl"
            obj="$case_dir/$name.o"
            build_stdout="$case_dir/$name.build.stdout"
            build_stderr="$case_dir/$name.build.stderr"

            echo "[$name] build -> run ($HOST_OS)"
            set +e
            # Stdlib comes from the embedded payload unless the case opted into
            # the on-disk layout (stage-stdlib), matching the staged copies.
            if [ -s "$asm" ]; then
                # Produced by the batch pre-pass. A failed chunk removes its
                # outputs, so reaching here with no assembly means compiling now.
                INTEGRATION_BATCHED_CASES=$((INTEGRATION_BATCHED_CASES + 1))
                : > "$build_stdout"
                : > "$build_stderr"
                true
            elif [ "$stage_stdlib" -eq 1 ]; then
                INTEGRATION_STANDALONE_COMPILES=$((INTEGRATION_STANDALONE_COMPILES + 1))
                # shellcheck disable=SC2086
                ci_timing_run "$name" compile integration_standalone_compile "$case_dir/standalone.memory" \
                    "$COMPILER" compile "$work_src_rel" --verify-ir \
                    --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" -o "$asm" \
                    $opt_level_args \
                    > "$build_stdout" 2> "$build_stderr"
            else
                INTEGRATION_STANDALONE_COMPILES=$((INTEGRATION_STANDALONE_COMPILES + 1))
                # shellcheck disable=SC2086
                ci_timing_run "$name" compile integration_standalone_compile "$case_dir/standalone.memory" \
                    "$COMPILER" compile "$work_src_rel" --verify-ir \
                    --stdlib-root "$ROOT/src" -o "$asm" \
                    $opt_level_args \
                    > "$build_stdout" 2> "$build_stderr"
            fi
            build_rc=$?
            set -e
            if [ "$build_rc" -ne 0 ]; then
                echo "FAIL: $name compile failed" >&2
                show_compile_failure_diagnostics \
                    "$name" \
                    "$build_rc" \
                    "$COMPILER" \
                    "$work_src" \
                    linux-x86_64 \
                    "$build_stdout" \
                    "$build_stderr" \
                    "$asm" \
                    "compile $work_src_rel --verify-ir --stdlib-root $ROOT/src -o $asm $opt_level_args (stage-stdlib=$stage_stdlib)"
                printf 'failed\n' > "$case_dir/.build-status"
                failed=$((failed + 1))
                ran=$((ran + 1))
                continue
            fi
            if integration_diagnostic_only "$case_dir" "$name"; then
                printf 'diagnostic-only\n' > "$case_dir/.build-status"
                ran=$((ran + 1))
                continue
            fi
            if ! ci_timing_run "$name" assemble \
                as "$asm" -o "$obj" >> "$build_stdout" 2>> "$build_stderr"; then
                echo "FAIL: $name assemble failed" >&2
                show_build_streams "$build_stdout" "$build_stderr"
                printf 'failed\n' > "$case_dir/.build-status"
                failed=$((failed + 1))
                ran=$((ran + 1))
                continue
            fi
            entry=$(ci_timing_run "$name" entry-selection \
                linux_entry_symbol_for_asm "$asm") || exit $?
            if ! native_objs=$(compile_linux_c_deps "$deps" "$case_dir" "$build_stdout" "$build_stderr"); then
                echo "FAIL: $name C dependency compile failed" >&2
                show_build_streams "$build_stdout" "$build_stderr"
                printf 'failed\n' > "$case_dir/.build-status"
                failed=$((failed + 1))
                ran=$((ran + 1))
                continue
            fi
            # Programs with no native FFI objects link freestanding (no libc, no
            # loader) like every other typelisp binary. Tests that pull in native
            # objects opt into the C toolchain and still link against libc.
            if [ -n "$native_objs" ]; then
                link_extra="-dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc"
            else
                link_extra="-static"
            fi
            stdlib_archive=$(linux_stdlib_archive_for_asm "$asm" "${COMPILER:-}")
            if [ -n "$stdlib_archive" ]; then
                link_extra="$link_extra -z noexecstack --gc-sections -z start-stop-gc --start-group $stdlib_archive --end-group"
            fi
            # shellcheck disable=SC2086
            if ! ci_timing_run "$name" link \
                ld "$obj" $native_objs -o "$bin" $link_extra -e "$entry" \
                >> "$build_stdout" 2>> "$build_stderr"; then
                echo "FAIL: $name link failed" >&2
                show_build_streams "$build_stdout" "$build_stderr"
                printf 'failed\n' > "$case_dir/.build-status"
                failed=$((failed + 1))
                ran=$((ran + 1))
                continue
            fi
            printf 'ok\n' > "$case_dir/.build-status"
        else
            echo "[$name] run (reusing build $owner, $HOST_OS)"
            _owner_status=failed
            if [ -f "$owner_dir/.build-status" ]; then
                IFS= read -r _owner_status < "$owner_dir/.build-status" || _owner_status=failed
            fi
            if [ "$_owner_status" = diagnostic-only ]; then
                ran=$((ran + 1))
                continue
            fi
            if [ "$_owner_status" != ok ]; then
                echo "FAIL: $name build failed (shared build $owner)" >&2
                failed=$((failed + 1))
                ran=$((ran + 1))
                continue
            fi
        fi

        set +e
        if ci_timing_enabled; then
            ci_timing_set_now_ms
            run_started=$CI_TIMING_NOW_MS
        fi
        # Keep shell crash notices (for example dash's "Segmentation fault
        # (core dumped)") out of both the program stderr comparison and this
        # runner's global stderr. The manifest still checks the exact exit code.
        # shellcheck disable=SC2086
        run_linux_manifest_program \
            "$bin" "$stdout" "$stderr" "$run_shell_stderr" \
            $(deps_or_empty "$runtime_args")
        got=$?
        set -e
        if ci_timing_enabled; then
            ci_timing_set_now_ms
            run_finished=$CI_TIMING_NOW_MS
            ci_timing_record_elapsed "$name" run "$((run_finished - run_started))" "$got"
        fi
    fi

    assert_manifest_case \
        "$name" \
        "$want" \
        "$stdout_spec" \
        "$expected_stderr_spec" \
        "$asm" \
        "$stdout" \
        "$stderr" \
        "$case_dir" \
        "$run_shell_stderr"
done < "$MANIFEST_PLAN"

if [ "$HOST_OS" = windows ] && [ "$WINDOWS_LINK_REQUESTS" -gt 0 ]; then
    if ! windows_run_manifest_links; then
        exit 1
    fi
    if ! windows_process_manifest_link_results; then
        exit 1
    fi
fi

if [ "$HOST_OS" = windows ] && [ "$WINDOWS_MANIFEST_QUEUED" -gt 0 ]; then
    if ! windows_run_manifest_queue; then
        exit 1
    fi
    # The differential compares three already-built default-level corpus
    # binaries, so the canonical shard that stages them runs it for the host.
    if [ "$INTEGRATION_SHARD_CANONICAL" -eq 1 ] && [ "$INTEGRATION_LOCAL_FILTER_ACTIVE" -eq 0 ]; then
        if ! windows_runner_differential_self_test; then
            exit 1
        fi
    fi
    windows_assert_queued_cases
    if [ "$failed" -eq 0 ]; then
        windows_validate_manifest_artifact_counts
    fi
    windows_print_manifest_summary
fi

integration_batch_require_success || exit 1
if [ "$failed" -gt 0 ]; then
    echo "$failed integration case(s) failed out of $ran" >&2
    exit 1
fi

assert_frontend_smoke_timing_rows() {
    if ! ci_timing_enabled; then
        return 0
    fi
    if ! awk -F '\t' -v gate="${TYPELISP_CI_TIMING_GATE:-ungated}" '
        BEGIN {
            expected["child-symbols"] = 42
            expected["child-check"] = 42
            expected["child-ctfe"] = 42
            expected["child-reflection"] = 42
            expected["child-doc-test"] = 42
            expected["semantic-base"] = 0
            expected["semantic-macro-call-sites"] = 0
            expected["semantic-inferred-locals"] = 0
            expected["semantic-retained-transitions"] = 0
            expected["semantic-dense-scopes"] = 0
            expected["semantic-partial"] = 0
            expected["semantic-canonical"] = 0
            expected["semantic-nominal-members"] = 0
            expected["semantic-exact-top-candidate-storage"] = 0
            expected["semantic-nominal-build"] = 0
            expected["semantic-nominal-select"] = 0
            expected["semantic-nominal-assert"] = 0
            expected["semantic-nominal-release"] = 0
        }
        NR == 1 { next }
        $1 == gate && $2 == "compiler_frontend_smoke_suite" && ($3 in expected) {
            count[$3] += 1
            if ($4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $5 != expected[$3]) bad = 1
        }
        END {
            for (phase in expected) if (count[phase] != 1) bad = 1
            if (bad) exit 1
        }
    ' "$TYPELISP_CI_TIMING_FILE"; then
        echo "FAIL: compiler_frontend_smoke_suite timing rows are missing, duplicated, or malformed" >&2
        exit 1
    fi
}

# The compile-once suite is a case of the canonical shard, which also runs the
# host fixture corpora and the Windows runner differential. Require its manifest
# row so deleting or renaming it fails CI, then check the timing rows it wrote.
if [ "$INTEGRATION_SHARD_CANONICAL" -eq 1 ]; then
    grep -q '^compiler_frontend_smoke_suite|' "$HOST_MANIFEST" || {
        echo "FAIL: $HOST_MANIFEST has no compiler_frontend_smoke_suite row" >&2
        exit 1
    }
    if [ "$INTEGRATION_LOCAL_FILTER_ACTIVE" -eq 0 ]; then
        assert_frontend_smoke_timing_rows
    fi
fi

# The host fixture corpora publish into the canonical work root, which is the
# shard other gates read, so exactly that shard runs them.
if [ "$INTEGRATION_SHARD_CANONICAL" -eq 1 ]; then
    if [ "$HOST_OS" = linux ]; then
        run_linux_fixture_cases
    else
        run_backend_cmp_mem_fold_parity_fixtures
        run_windows_backend_fixtures
    fi
fi

echo "[integration] compile processes: $INTEGRATION_BATCH_CHUNKS batch chunk(s)" \
    "+ $INTEGRATION_STANDALONE_COMPILES standalone," \
    "$INTEGRATION_BATCHED_CASES unique build(s) served from a batch" \
    "($INTEGRATION_DEDUP_ALIAS_CASES deduplicated alias(es))"
echo "All $ran integration case(s) passed for $HOST_OS."
