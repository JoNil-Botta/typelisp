#!/usr/bin/env sh
set -eu

# verify-integration.sh - manifest-driven native integration runner.
#
# The runner builds each listed TypeLisp program to a native executable, runs it
# outside the Rust test harness, and checks exit code, stdout, and stderr. Linux
# uses the explicit compile -> as -> ld flow; Windows Git Bash/MSYS/Cygwin uses
# bounded native-link and persistent execution queues so independent links can
# overlap while full Windows exit values and byte streams survive without a
# PowerShell launch per manifest case.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-ci-timing.sh"

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-integration.sh [--self-test-batch-observability | --self-test-empty-compile-diagnostic | --self-test-signal-notice-capture | --validate-manifest-only]

Runs manifest-driven native integration tests.
--self-test-batch-observability exercises the batch sentinel selection and
per-chunk timing row without invoking a compiler or native toolchain.
--self-test-empty-compile-diagnostic exercises the compile-failure diagnostic
helper without invoking a compiler or native toolchain.
--self-test-signal-notice-capture exercises Linux signal exit and shell-notice
capture without invoking a compiler or native toolchain.
--validate-manifest-only validates the host manifest and exits before builds.
EOF
}

SELF_TEST_BATCH_OBSERVABILITY=0
SELF_TEST_EMPTY_COMPILE_DIAGNOSTIC=0
SELF_TEST_SIGNAL_NOTICE_CAPTURE=0
SELF_TEST_WITHOUT_COMPILER=0
VALIDATE_MANIFEST_ONLY=0
case "${1:-}" in
    "")
        ;;
    --self-test-batch-observability)
        SELF_TEST_BATCH_OBSERVABILITY=1
        SELF_TEST_WITHOUT_COMPILER=1
        shift
        ;;
    --self-test-empty-compile-diagnostic)
        SELF_TEST_EMPTY_COMPILE_DIAGNOSTIC=1
        SELF_TEST_WITHOUT_COMPILER=1
        shift
        ;;
    --self-test-signal-notice-capture)
        SELF_TEST_SIGNAL_NOTICE_CAPTURE=1
        SELF_TEST_WITHOUT_COMPILER=1
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
run_linux_manifest_program() {
    _bin=$1
    _stdout=$2
    _stderr=$3
    _run_shell_stderr=$4
    shift 4

    sh -c '
        _bin=$1
        _stdout=$2
        _stderr=$3
        shift 3
        set +e
        (
            exec "$_bin" "$@" > "$_stdout" 2> "$_stderr"
        )
        _rc=$?
        exit "$_rc"
    ' typelisp-integration-run \
        "$_bin" "$_stdout" "$_stderr" "$@" 2> "$_run_shell_stderr"
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

MANIFEST="$ROOT/tests/integration/native-$HOST_OS.manifest"
WORKDIR="$ROOT/target/integration-verify/$HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
NORMALIZED_MANIFEST="$WORKDIR/manifest.normalized"
tr -d '\r' < "$MANIFEST" > "$NORMALIZED_MANIFEST"

# Compile one batch chunk. The timing row deliberately describes the actual
# compiler process rather than attributing its elapsed time to individual
# cases, which would turn a measurement into a derived estimate (#5793).
integration_batch_run_chunk() {
    _chunk_list=$1
    _chunk_label=$2
    shift 2
    INTEGRATION_BATCH_CHUNKS=$((INTEGRATION_BATCH_CHUNKS + 1))
    _chunk_stdout="$WORKDIR/batch-$_chunk_label.stdout"
    _chunk_stderr="$WORKDIR/batch-$_chunk_label.stderr"
    _chunk_plan=
    if [ "$HOST_OS" = windows ]; then
        _chunk_plan="$WORKDIR/batch-$_chunk_label.plan"
        rm -f "$_chunk_plan"
        ci_timing_set_now_ms
        _windows_batch_started=$CI_TIMING_NOW_MS
    fi
    set +e
    if [ "$HOST_OS" = windows ]; then
        ci_timing_run "batch-$_chunk_label" compile \
            "$COMPILER" compile --batch "$_chunk_list" \
            --windows-coff-plan "$_chunk_plan" "$@" \
            > "$_chunk_stdout" 2> "$_chunk_stderr"
    else
        ci_timing_run "batch-$_chunk_label" compile \
            "$COMPILER" compile --batch "$_chunk_list" "$@" \
            > "$_chunk_stdout" 2> "$_chunk_stderr"
    fi
    _chunk_rc=$?
    set -e
    if [ "$HOST_OS" = windows ]; then
        ci_timing_set_now_ms
        _windows_batch_finished=$CI_TIMING_NOW_MS
        WINDOWS_MANIFEST_BATCH_COMPILE_MS=$((
            WINDOWS_MANIFEST_BATCH_COMPILE_MS +
            _windows_batch_finished -
            _windows_batch_started
        ))
        WINDOWS_MANIFEST_BATCH_COMPILES=$((WINDOWS_MANIFEST_BATCH_COMPILES + 1))
    fi
    if [ "$_chunk_rc" -eq 0 ]; then
        if [ "$HOST_OS" = windows ]; then
            integration_windows_register_plan \
                "$_chunk_list" "$_chunk_plan" "$_chunk_label"
        fi
        return 0
    fi
    INTEGRATION_BATCH_FAILED_CHUNKS=$((INTEGRATION_BATCH_FAILED_CHUNKS + 1))
    echo "[integration] batch chunk $_chunk_label exited $_chunk_rc;" \
        "replaying its entries standalone" >&2
    sed 's/^/  /' "$_chunk_stderr" >&2 || true
    while IFS='|' read -r _batch_src _batch_artifact1 _batch_artifact2 _batch_mode; do
        [ -n "$_batch_artifact1" ] || continue
        rm -f "$_batch_artifact1"
        if [ -n "$_batch_artifact2" ]; then
            rm -f "$_batch_artifact2"
            _batch_case_path=${_batch_src%/*}
            _batch_case=${_batch_case_path##*/}
            rm -f "$WORKDIR/$_batch_case/windows-coff.artifact"
        fi
    done < "$_chunk_list"
    [ -z "$_chunk_plan" ] || rm -f "$_chunk_plan"
    return 0
}

integration_batch_sentinel_entry() {
    sed -n '$p' "$1"
}

WINDOWS_RUNNER_WIN=
WINDOWS_LEGACY_RUNNER_WIN=
WINDOWS_LINKER_WIN=
WINDOWS_LLD_LINK_WIN=
WINDOWS_WORKDIR_WIN=
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
WINDOWS_COFF_FALLBACK_REASONS=
WINDOWS_LINK_REQUESTS=0
WINDOWS_MANIFEST_QUEUED=0
WINDOWS_QUEUE_REQUESTS=0
WINDOWS_MANIFEST_COMPILE_MS=0
WINDOWS_MANIFEST_BATCH_COMPILE_MS=0
WINDOWS_MANIFEST_PLAN_PROCESS_MS=0
WINDOWS_MANIFEST_ASSEMBLE_MS=0
WINDOWS_MANIFEST_FALLBACK_ASSEMBLE_MS=0
WINDOWS_MANIFEST_FORCED_ASSEMBLE_MS=0
WINDOWS_MANIFEST_STANDALONE_ASSEMBLE_MS=0
WINDOWS_MANIFEST_LINK_MS=0
WINDOWS_MANIFEST_LINK_WALL_MS=0
WINDOWS_MANIFEST_LINK_HELPER_MS=0
WINDOWS_MANIFEST_LINK_PREP_MS=0
WINDOWS_MANIFEST_LINK_RESULT_PROCESS_MS=0
WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS=0
WINDOWS_MANIFEST_QUEUE_PREP_MS=0
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
WINDOWS_MANIFEST_LINKS=0
WINDOWS_MANIFEST_ASSERTS=0
WINDOWS_CURRENT_ASSEMBLY_CLASS=standalone
WINDOWS_LINK_POWERSHELL_STARTS=0
WINDOWS_MANIFEST_POWERSHELL_STARTS=0
WINDOWS_MANIFEST_CYGPATH_CONVERSIONS=0
WINDOWS_DIRECT_POWERSHELL_STARTS=0
WINDOWS_DIRECT_CYGPATH_CONVERSIONS=0
WINDOWS_DIFFERENTIAL_POWERSHELL_STARTS=0
WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS=0
# Five native-Windows samples over the 355-case manifest (#5817) put jobs=4 at
# p10/median/p90 3.577/4.050/4.742s. Jobs=8 had a faster median but a worse
# 5.446s p90 and substantially more summed child time, so four is the
# conservative CI default. Set TYPELISP_WINDOWS_LINK_JOBS=1 for serial debugging
# or override it up to 64 for host-specific measurements.
WINDOWS_LINK_JOBS=${TYPELISP_WINDOWS_LINK_JOBS:-4}

if [ "$HOST_OS" = windows ] && [ "$SELF_TEST_WITHOUT_COMPILER" -eq 0 ]; then
    case "$WINDOWS_LINK_JOBS" in
        "" | *[!0-9]* | 0)
            echo "TYPELISP_WINDOWS_LINK_JOBS must be an integer from 1 to 64" >&2
            exit 2
            ;;
    esac
    if [ "$WINDOWS_LINK_JOBS" -gt 64 ]; then
        echo "TYPELISP_WINDOWS_LINK_JOBS must be an integer from 1 to 64" >&2
        exit 2
    fi
    WINDOWS_RUNNER_WIN=$(cygpath -aw "$ROOT/scripts/windows-integration-runner.ps1")
    WINDOWS_LEGACY_RUNNER_WIN=$(cygpath -aw "$ROOT/scripts/windows-integration-legacy-runner.ps1")
    WINDOWS_LINKER_WIN=$(cygpath -aw "$ROOT/scripts/windows-integration-linker.ps1")
    WINDOWS_LLD_LINK_WIN=$(cygpath -aw "$(command -v lld-link)")
    WINDOWS_WORKDIR_WIN=$(cygpath -aw "$WORKDIR")
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
    WINDOWS_COFF_FALLBACK_REASONS="$WORKDIR/windows-coff-fallback-reasons.txt"
    printf 'tlwinlink1\000' > "$WINDOWS_LINK_REQUEST"
    : > "$WINDOWS_LINK_CASES"
    printf 'tlwinq2\000' > "$WINDOWS_QUEUE"
    : > "$WINDOWS_QUEUED_CASES"
    : > "$WINDOWS_COFF_FALLBACK_REASONS"
    # The two queue helpers, lld-link, and their common work root are the only
    # manifest path conversions. Per-case inputs/outputs are constructed from
    # validated case names below.
    WINDOWS_MANIFEST_CYGPATH_CONVERSIONS=4
    WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS=1
fi

integration_windows_register_plan() {
    _windows_plan_batch=$1
    _windows_plan_result=$2
    _windows_plan_label=$3
    _windows_plan_normalized="$WORKDIR/batch-$_windows_plan_label.validated"
    ci_timing_set_now_ms
    _windows_plan_started=$CI_TIMING_NOW_MS

    if ! awk -f "$ROOT/scripts/validate-windows-coff-plan.awk" \
        "$_windows_plan_batch" "$_windows_plan_result" \
        > "$_windows_plan_normalized"; then
        echo "FAIL: invalid Windows COFF result plan for batch $_windows_plan_label" >&2
        return 1
    fi

    while IFS='|' read -r \
        _plan_source \
        _plan_kind \
        _plan_selected \
        _plan_reason \
        _plan_object \
        _plan_assembly \
        _plan_forced || [ -n "$_plan_source" ]; do
        [ -n "$_plan_source" ] || continue
        _plan_case_path=${_plan_source%/*}
        _plan_case=${_plan_case_path##*/}
        _plan_expected_source="target/integration-verify/windows/$_plan_case/$_plan_case.tl"
        if [ "$_plan_source" != "$_plan_expected_source" ]; then
            echo "FAIL: Windows COFF plan source is outside its validated case path: $_plan_source" >&2
            return 1
        fi
        _plan_case_dir="$WORKDIR/$_plan_case"
        _plan_marker="$_plan_case_dir/windows-coff.artifact"
        if [ -e "$_plan_marker" ]; then
            echo "FAIL: Windows COFF plan selected $_plan_case more than once" >&2
            return 1
        fi

        _plan_selected_abs="$ROOT/$_plan_selected"
        _plan_object_abs="$ROOT/$_plan_object"
        _plan_assembly_abs="$ROOT/$_plan_assembly"
        case "$_plan_kind" in
            coff-object)
                if [ ! -s "$_plan_selected_abs" ]; then
                    echo "FAIL: Windows COFF plan omitted object for $_plan_case: $_plan_selected" >&2
                    return 1
                fi
                if [ -e "$_plan_assembly_abs" ]; then
                    echo "FAIL: Windows COFF object row also wrote assembly for $_plan_case" >&2
                    return 1
                fi
                WINDOWS_MANIFEST_DIRECT_OBJECTS=$((WINDOWS_MANIFEST_DIRECT_OBJECTS + 1))
                ;;
            assembly)
                if [ ! -s "$_plan_selected_abs" ]; then
                    echo "FAIL: Windows COFF plan omitted assembly for $_plan_case: $_plan_selected" >&2
                    return 1
                fi
                if [ -e "$_plan_object_abs" ]; then
                    echo "FAIL: Windows COFF assembly row also wrote an object for $_plan_case" >&2
                    return 1
                fi
                if [ "$_plan_forced" -eq 1 ]; then
                    if ! _plan_requirement_reason=$(windows_manifest_assembly_reason "$_plan_case"); then
                        echo "FAIL: Windows COFF plan forced unclassified assembly for $_plan_case" >&2
                        return 1
                    fi
                    WINDOWS_MANIFEST_FORCED_ASSEMBLIES=$((WINDOWS_MANIFEST_FORCED_ASSEMBLIES + 1))
                else
                    WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES=$((WINDOWS_MANIFEST_FALLBACK_ASSEMBLIES + 1))
                    printf '%s\n' "$_plan_reason" >> "$WINDOWS_COFF_FALLBACK_REASONS"
                fi
                ;;
        esac

        printf '%s|%s|%s\n' \
            "$_plan_kind" "$_plan_selected_abs" "$_plan_reason" \
            > "$_plan_marker"
        WINDOWS_MANIFEST_PLAN_ROWS=$((WINDOWS_MANIFEST_PLAN_ROWS + 1))
    done < "$_windows_plan_normalized"

    ci_timing_set_now_ms
    _windows_plan_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_PLAN_PROCESS_MS=$((
        WINDOWS_MANIFEST_PLAN_PROCESS_MS +
        _windows_plan_finished -
        _windows_plan_started
    ))
}

deps_or_empty() {
    case "$1" in
        "" | -) ;;
        *) printf '%s\n' "$1" ;;
    esac
}

dep_source_path() {
    _dep=$1
    _source_dir=$2

    case "$_dep" in
        stdlib/*)
            printf '%s\n' "$ROOT/$_dep"
            return
            ;;
        benchmarks/*)
            printf '%s\n' "$ROOT/$_dep"
            return
            ;;
        sym_i64_env_core.tl)
            printf '%s\n' "$ROOT/src/sym_i64_env.tl"
            return
            ;;
    esac

    if [ -f "$_source_dir/$_dep" ]; then
        printf '%s\n' "$_source_dir/$_dep"
    elif [ -f "$ROOT/src/$_dep" ]; then
        printf '%s\n' "$ROOT/src/$_dep"
    elif [ -f "$ROOT/src/tests/$_dep" ]; then
        printf '%s\n' "$ROOT/src/tests/$_dep"
    elif [ -f "$ROOT/tests/integration/$_dep" ]; then
        printf '%s\n' "$ROOT/tests/integration/$_dep"
    else
        echo "missing integration dependency: $_dep" >&2
        return 1
    fi
}

copy_dep() {
    _dep=$1
    _source_dir=$2
    _case_dir=$3
    _stage_stdlib=${4:-1}
    # Stdlib modules resolve from the compiler's embedded payload by default,
    # so their staged copies are never read. Cases that exercise on-disk
    # stdlib layouts at runtime opt back in with the manifest `stage-stdlib`
    # extra (which also restores the on-disk stdlib compile root).
    case "$_dep" in
        stdlib/*)
            if [ "$_stage_stdlib" -eq 0 ]; then
                return 0
            fi
            ;;
    esac
    _src=$(dep_source_path "$_dep" "$_source_dir")
    # src/ sources import `../stdlib/...`; src/tests/ smoke drivers import
    # `../src_module.tl` and `../../stdlib/...` so they stay directly runnable
    # from the repository root while staged integration copies keep the same
    # relative layout.
    case "$_dep" in
        stdlib/*)
            case "$_source_dir" in
                "$ROOT/src")
                    _dst="$(dirname -- "$_case_dir")/$_dep"
                    ;;
                "$ROOT/src/tests")
                    _dst="$(dirname -- "$(dirname -- "$_case_dir")")/$_dep"
                    ;;
                *)
                    _dst="$_case_dir/$_dep"
                    ;;
            esac
            ;;
        *)
            if [ "$_source_dir" = "$ROOT/src/tests" ]; then
                case "$_src" in
                    "$ROOT/src/tests/"*)
                        _dst="$_case_dir/$_dep"
                        ;;
                    "$ROOT/src/"*)
                        _dst="$(dirname -- "$_case_dir")/$_dep"
                        ;;
                    *)
                        _dst="$_case_dir/$_dep"
                        ;;
                esac
            else
                _dst="$_case_dir/$_dep"
            fi
            ;;
    esac
    mkdir -p "$(dirname -- "$_dst")"
    cp "$_src" "$_dst"

    case "$_dep" in
        stdlib/core_macros.tl) ;;
        stdlib/*)
            case "$_source_dir" in
                "$ROOT/src")
                    _core_dst="$(dirname -- "$_case_dir")/stdlib/core_macros.tl"
                    ;;
                "$ROOT/src/tests")
                    _core_dst="$(dirname -- "$(dirname -- "$_case_dir")")/stdlib/core_macros.tl"
                    ;;
                *)
                    _core_dst="$_case_dir/stdlib/core_macros.tl"
                    ;;
            esac
            mkdir -p "$(dirname -- "$_core_dst")"
            cp "$ROOT/stdlib/core_macros.tl" "$_core_dst"
            ;;
    esac
}

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

compile_windows_c_deps() {
    _deps=$1
    _case_dir=$2
    _build_stdout=$3
    _build_stderr=$4
    _case_dir_win=$5

    for _dep in $(deps_or_empty "$_deps"); do
        case "$_dep" in
            *.c)
                if ! command -v clang >/dev/null 2>&1; then
                    echo "missing C compiler: clang" >> "$_build_stderr"
                    return 1
                fi
                _base=$(basename -- "$_dep" .c)
                _src="$_case_dir/$_dep"
                _obj="$_case_dir/$_base.native.obj"
                if ! clang --target=x86_64-pc-windows-msvc -std=c99 -Wall -Wextra -c "$_src" -o "$_obj" \
                    >> "$_build_stdout" 2>> "$_build_stderr"; then
                    return 1
                fi
                # One path per line lets the link-plan builder preserve a
                # checkout root containing spaces without re-parsing argv.
                printf '%s\n' "$_case_dir_win\\$_base.native.obj"
                ;;
        esac
    done
}

# Integration cases that are not Windows-applicable in this manifest
# (kept covered on Linux via native-linux.manifest):
#   arena_poison_stale_array_trap  the poison-on-reclaim trap cannot fire on
#                             Windows: poison mode retains reset segments but
#                             does not overwrite or guard their pages, so the
#                             stale access does not fault (Linux asserts 139)
#   c_abi_sysv_*              Linux System V C ABI fixtures
#   syscall_arg_alias         raw Linux syscall (rejected on the Windows target)
#   dead_frame_store          raw Linux syscall (getpid) fixture (rejected on the Windows target)
windows_integration_non_applicable_cases() {
    cat <<'EOF'
arena_poison_stale_array_trap
c_abi_sysv_register_aggregate_args
c_abi_sysv_memory_aggregate
c_abi_sysv_enum_aggregate
c_abi_sysv_tag_only_enum
c_abi_sysv_two_register_return
syscall_arg_alias
dead_frame_store
EOF
}

# Integration cases that are Windows-only in this manifest
# (kept covered on Windows via native-windows.manifest):
#   c_abi_win64_sret_return  Win64 hidden-sret aggregate return ABI
#   c_abi_win64_enum_*       Win64 enum aggregate C ABI fixtures
#   c_abi_win64_small_*      Win64 small aggregate register ABI
#   c_abi_win64_nested_*     Win64 nested aggregate C ABI fixtures
#   windows_allocation_abort  Win32 VirtualAlloc provenance reporter transcript
linux_integration_non_applicable_cases() {
    cat <<'EOF'
c_abi_win64_sret_return
c_abi_win64_aggregate_args
c_abi_win64_enum_aggregate
c_abi_win64_small_aggregate_float_mixed
c_abi_win64_nested_aggregate
windows_allocation_abort
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
# emitter tests cover both targets and this source is the native matrix driver.
compiler_cfg_native_fixture_cases() {
    cat <<'EOF'
compiler_arena_debug
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
    ' "$_requirements" "$_assertions" "$NORMALIZED_MANIFEST"
}

validate_manifest() {
    _known="$WORKDIR/manifest-known.txt"
    _known_sorted="$WORKDIR/manifest-known.sorted"
    _actual="$WORKDIR/integration-sources.txt"
    _catalog="$WORKDIR/repository-files.txt"
    : > "$_known"

    find benchmarks examples src stdlib tests/integration -type f -print |
        sed 's#^\./##' > "$_catalog"
    awk -v root="$ROOT" -v catalog="$_catalog" -v known_out="$_known" \
        -f "$ROOT/scripts/validate-integration-manifest.awk" \
        "$_catalog" "$NORMALIZED_MANIFEST"

    if [ "$HOST_OS" = windows ]; then
        validate_windows_manifest_assembly_requirements
        windows_integration_non_applicable_cases >> "$_known"
    fi
    if [ "$HOST_OS" = linux ]; then
        linux_integration_non_applicable_cases >> "$_known"
    fi
    selfhost_native_manifest_cases >> "$_known"
    spmd_simd_manifest_cases >> "$_known"
    compiler_cfg_native_fixture_cases >> "$_known"

    find tests/integration -maxdepth 1 -type f -name '*.tl' |
        sed 's#^tests/integration/##; s#\.tl$##' | sort > "$_actual"
    sort -u "$_known" > "$_known_sorted"
    if ! cmp -s "$_actual" "$_known_sorted"; then
        echo "integration manifest is out of date for $HOST_OS" >&2
        echo "every tests/integration/*.tl file must be a manifest case, dependency, or documented host exception" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_known_sorted" "$_actual" >&2 || true
        fi
        exit 1
    fi
}

write_expected_stream() {
    _spec=$1
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

normalized_stream() {
    _in=$1
    _out=$2
    if [ "$HOST_OS" = windows ]; then
        tr -d '\r' < "$_in" > "$_out"
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

# Append one native-path request to the NUL-delimited UTF-8 queue. NUL cannot
# occur in a Windows path or process argument, so this preserves the already
# split argument vector without launching per-field base64/tr helpers.
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
    if [ ! -s "$_queue" ]; then
        printf 'tlwinq2\000' > "$_queue"
    fi
    printf '%s\000' \
        "$_label" \
        "$_exe" \
        "$_stdout" \
        "$_stderr" \
        "$_code" \
        "$_expected_exit" \
        "$_expected_stdout" \
        "$_expected_stderr" \
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
    ci_timing_set_now_ms
    _started=$CI_TIMING_NOW_MS
    set +e
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_RUNNER_WIN" \
        -RequestPath "$_request_win" \
        -ResultPath "$_result_win" \
        -AssertionPath "$_assertion_win" \
        -SummaryPath "$_summary_win" \
        > "$_runner_stdout" 2> "$_runner_stderr"
    WINDOWS_RUNNER_STATUS=$?
    set -e
    ci_timing_set_now_ms
    _finished=$CI_TIMING_NOW_MS
    WINDOWS_LAST_RUN_MS=$((_finished - _started))
    return "$WINDOWS_RUNNER_STATUS"
}

windows_queue_manifest_case() {
    _name=$1
    _want=$2
    _stdout_spec=$3
    _stderr_spec=$4
    _runtime_args=$5
    ci_timing_set_now_ms
    _queue_started=$CI_TIMING_NOW_MS
    _case_dir="$WORKDIR/$_name"
    _expected_stdout="$_case_dir/$_name.expected.stdout"
    _expected_stderr="$_case_dir/$_name.expected.stderr"
    write_expected_stream "$_stdout_spec" "$_expected_stdout"
    write_expected_stream "$_stderr_spec" "$_expected_stderr"
    _exe_win="$WINDOWS_WORKDIR_WIN\\$_name\\$_name.exe"
    _stdout_win="$WINDOWS_WORKDIR_WIN\\$_name\\$_name.stdout"
    _stderr_win="$WINDOWS_WORKDIR_WIN\\$_name\\$_name.stderr"
    _code_win="$WINDOWS_WORKDIR_WIN\\$_name\\$_name.exit"
    _expected_stdout_win="$WINDOWS_WORKDIR_WIN\\$_name\\$_name.expected.stdout"
    _expected_stderr_win="$WINDOWS_WORKDIR_WIN\\$_name\\$_name.expected.stderr"
    case "$_runtime_args" in
        "" | -)
            windows_queue_append_request "$WINDOWS_QUEUE" "$_name" \
                "$_exe_win" "$_stdout_win" "$_stderr_win" "$_code_win" \
                "$_want" "$_expected_stdout_win" "$_expected_stderr_win"
            ;;
        *)
            # The manifest argument field is an already whitespace-separated
            # vector; preserve the same splitting contract as the old
            # `deps_or_empty` command substitution without its subshell.
            # shellcheck disable=SC2086
            windows_queue_append_request "$WINDOWS_QUEUE" "$_name" \
                "$_exe_win" "$_stdout_win" "$_stderr_win" "$_code_win" \
                "$_want" "$_expected_stdout_win" "$_expected_stderr_win" \
                $_runtime_args
            ;;
    esac
    ci_timing_set_now_ms
    _queue_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_QUEUE_PREP_MS=$((WINDOWS_MANIFEST_QUEUE_PREP_MS + _queue_finished - _queue_started))
    printf '%s\n' "$_name" >> "$WINDOWS_QUEUED_CASES"
    WINDOWS_MANIFEST_QUEUED=$((WINDOWS_MANIFEST_QUEUED + 1))
    WINDOWS_QUEUE_REQUESTS=$((WINDOWS_QUEUE_REQUESTS + 1))
}

windows_link_queue_append_request() {
    _link_queue=$1
    _link_label=$2
    _link_exe=$3
    _link_output=$4
    _link_stdout=$5
    _link_stderr=$6
    shift 6
    if [ ! -s "$_link_queue" ]; then
        printf 'tlwinlink1\000' > "$_link_queue"
    fi
    printf '%s\000' \
        "$_link_label" \
        "$_link_exe" \
        "$_link_output" \
        "$_link_stdout" \
        "$_link_stderr" \
        "$#" \
        "$@" >> "$_link_queue"
}

windows_queue_manifest_link() {
    _link_name=$1
    _link_obj_win=$2
    _link_native_objs=$3
    _link_bin_win=$4
    _link_build_stdout_win=$5
    _link_build_stderr_win=$6
    _link_want=$7
    _link_stdout_spec=$8
    _link_stderr_spec=$9
    shift 9
    _link_runtime_args=$1

    ci_timing_set_now_ms
    _link_prepare_started=$CI_TIMING_NOW_MS
    set -- -NOLOGO "$_link_obj_win"
    _link_saved_ifs=$IFS
    IFS='
'
    for _link_native_obj in $_link_native_objs; do
        set -- "$@" "$_link_native_obj"
    done
    IFS=$_link_saved_ifs
    set -- "$@" \
        "-OUT:$_link_bin_win" \
        -SUBSYSTEM:CONSOLE \
        -STACK:268435456 \
        -ENTRY:_tl_start \
        -NODEFAULTLIB \
        kernel32.lib
    windows_link_queue_append_request \
        "$WINDOWS_LINK_REQUEST" \
        "$_link_name" \
        "$WINDOWS_LLD_LINK_WIN" \
        "$_link_bin_win" \
        "$_link_build_stdout_win" \
        "$_link_build_stderr_win" \
        "$@"
    printf '%s|%s|%s|%s|%s\n' \
        "$_link_name" \
        "$_link_want" \
        "$_link_stdout_spec" \
        "$_link_stderr_spec" \
        "$_link_runtime_args" >> "$WINDOWS_LINK_CASES"
    ci_timing_set_now_ms
    _link_prepare_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_LINK_PREP_MS=$((WINDOWS_MANIFEST_LINK_PREP_MS + _link_prepare_finished - _link_prepare_started))
    WINDOWS_LINK_REQUESTS=$((WINDOWS_LINK_REQUESTS + 1))
    WINDOWS_MANIFEST_LINKS=$((WINDOWS_MANIFEST_LINKS + 1))
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

windows_timed_assemble() {
    ci_timing_set_now_ms
    _started=$CI_TIMING_NOW_MS
    set +e
    clang "$@"
    _status=$?
    set -e
    ci_timing_set_now_ms
    _finished=$CI_TIMING_NOW_MS
    _elapsed=$((_finished - _started))
    WINDOWS_MANIFEST_ASSEMBLE_MS=$((WINDOWS_MANIFEST_ASSEMBLE_MS + _elapsed))
    case "$WINDOWS_CURRENT_ASSEMBLY_CLASS" in
        fallback)
            WINDOWS_MANIFEST_FALLBACK_ASSEMBLE_MS=$((WINDOWS_MANIFEST_FALLBACK_ASSEMBLE_MS + _elapsed))
            ;;
        forced)
            WINDOWS_MANIFEST_FORCED_ASSEMBLE_MS=$((WINDOWS_MANIFEST_FORCED_ASSEMBLE_MS + _elapsed))
            ;;
        standalone)
            WINDOWS_MANIFEST_STANDALONE_ASSEMBLE_MS=$((WINDOWS_MANIFEST_STANDALONE_ASSEMBLE_MS + _elapsed))
            ;;
        *)
            echo "FAIL: unknown Windows assembly timing class: $WINDOWS_CURRENT_ASSEMBLY_CLASS" >&2
            return 1
            ;;
    esac
    WINDOWS_MANIFEST_ASSEMBLES=$((WINDOWS_MANIFEST_ASSEMBLES + 1))
    ci_timing_record_elapsed "$name" assemble "$_elapsed" "$_status"
    return "$_status"
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
        "$_exe_win" "$_stdout_win" "$_stderr_win" "$_code_win" - - - "$@"
    WINDOWS_RESULTS=$_direct_results
    if ! windows_run_request_file \
        "$_direct_queue_win" \
        "$_direct_results_win" \
        "$_direct_assertions_win" \
        "$_direct_summary_win" \
        "$_direct_stdout" \
        "$_direct_stderr"; then
        echo "Windows direct runner failed:" >&2
        show_stream_if_nonempty stdout "$_direct_stdout"
        show_stream_if_nonempty stderr "$_direct_stderr"
        return 1
    fi
    if ! windows_result_for_label "windows_direct_$_direct_id"; then
        echo "Windows direct runner did not report its request" >&2
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

assert_matches() {
    _file=$1
    _regex=$2
    _label=$3
    if ! grep -E "$_regex" "$_file" >/dev/null 2>&1; then
        echo "FAIL: $_label missing regex: $_regex" >&2
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
    assert_contains "$_asm" "    js " "$_label"
    assert_contains "$_asm" '    andq $1, ' "$_label"
    assert_contains "$_asm" '    shrq $1, ' "$_label"
    assert_contains "$_asm" "    orq " "$_label"
    assert_contains "$_asm" "    addsd " "$_label"
    assert_contains "$_asm" "    addss " "$_label"
    assert_contains "$_asm" "    movzbq" "$_label"
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

    printf '%s\n' "verify-integration signal notice capture self-test passed"
}

run_batch_observability_self_test() {
    _dir="$WORKDIR/batch-observability-self-test"
    rm -rf "$_dir"
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

    printf '%s\n' "verify-integration batch observability self-test passed"
}

if [ "$SELF_TEST_BATCH_OBSERVABILITY" -eq 1 ]; then
    run_batch_observability_self_test
    exit 0
fi
if [ "$SELF_TEST_EMPTY_COMPILE_DIAGNOSTIC" -eq 1 ]; then
    run_empty_compile_diagnostic_self_test
    exit 0
fi
if [ "$SELF_TEST_SIGNAL_NOTICE_CAPTURE" -eq 1 ]; then
    run_signal_notice_capture_self_test
    exit 0
fi

build_linux_fixture_driver() {
    _label=$1
    _source=$2
    _bin=$3
    _asm="$_bin.s"
    _obj="$_bin.o"
    _build_stdout="$_bin.build.stdout"
    _build_stderr="$_bin.build.stderr"

    run_build "$COMPILER" compile "$_source" -o "$_asm" > "$_build_stdout" 2> "$_build_stderr"
    if [ "$build_rc" -ne 0 ]; then
        echo "FAIL: $_label compile failed" >&2
        show_build_streams "$_build_stdout" "$_build_stderr"
        exit 1
    fi
    if ! as "$_asm" -o "$_obj" >> "$_build_stdout" 2>> "$_build_stderr"; then
        echo "FAIL: $_label assemble failed" >&2
        show_build_streams "$_build_stdout" "$_build_stderr"
        exit 1
    fi
    if ! ld -static -e _tl_start "$_obj" -o "$_bin" \
        >> "$_build_stdout" 2>> "$_build_stderr"; then
        echo "FAIL: $_label link failed" >&2
        show_build_streams "$_build_stdout" "$_build_stderr"
        exit 1
    fi
}

run_linux_program_fixture() {
    _label=$1
    _source=$2
    _want=$3
    _opt_level=$4
    _dir="$WORKDIR/$_label"
    mkdir -p "$_dir"
    _asm="$_dir/$_label.s"
    _obj="$_dir/$_label.o"
    _bin="$_dir/$_label"
    _stdout="$_dir/$_label.stdout"
    _stderr="$_dir/$_label.stderr"
    _build_stdout="$_dir/$_label.build.stdout"
    _build_stderr="$_dir/$_label.build.stderr"

    echo "[$_label] compile --opt-level $_opt_level -> run"
    run_build "$COMPILER" compile "$ROOT/$_source" \
        --stdlib-root "$ROOT/src" \
        --opt-level "$_opt_level" -o "$_asm" > "$_build_stdout" 2> "$_build_stderr"
    if [ "$build_rc" -ne 0 ]; then
        echo "FAIL: $_label compile failed" >&2
        show_build_streams "$_build_stdout" "$_build_stderr"
        exit 1
    fi
    if ! as "$_asm" -o "$_obj" >> "$_build_stdout" 2>> "$_build_stderr"; then
        echo "FAIL: $_label assemble failed" >&2
        show_build_streams "$_build_stdout" "$_build_stderr"
        exit 1
    fi
    if ! ld -static -e "$(linux_entry_symbol_for_asm "$_asm")" "$_obj" -o "$_bin" \
        >> "$_build_stdout" 2>> "$_build_stderr"; then
        echo "FAIL: $_label link failed" >&2
        show_build_streams "$_build_stdout" "$_build_stderr"
        exit 1
    fi
    set +e
    "$_bin" > "$_stdout" 2> "$_stderr"
    _got=$?
    set -e
    if [ "$_got" -ne "$_want" ] || [ -s "$_stdout" ] || [ -s "$_stderr" ]; then
        echo "FAIL: $_label expected exit $_want with no output, got $_got" >&2
        show_stream_if_nonempty stdout "$_stdout"
        show_stream_if_nonempty stderr "$_stderr"
        exit 1
    fi
}

run_linux_backend_fixtures() {
    run_linux_program_fixture \
        regalloc-loop-split-evicted-region-var-opt2 \
        tests/integration/regalloc_loop_split_evicted_region_var.tl \
        42 \
        2
    run_linux_program_fixture \
        phi-forward-scavenge-live-through-opt2 \
        tests/integration/phi_forward_scavenge_live_through.tl \
        42 \
        2
    run_linux_program_fixture \
        inline-alloc-scavenge-live-through-opt2 \
        tests/integration/inline_alloc_scavenge_live_through.tl \
        42 \
        2
    run_linux_program_fixture \
        f32-mandelbrot-loop-opt0 \
        tests/integration/opt2_f32_mandelbrot_loop.tl \
        42 \
        0
    run_linux_program_fixture \
        f32-mandelbrot-loop-opt2 \
        tests/integration/opt2_f32_mandelbrot_loop.tl \
        42 \
        2

    _runtime_dir="$WORKDIR/backend-runtime"
    mkdir -p "$_runtime_dir"
    _runtime_asm="$_runtime_dir/runtime_helpers.s"
    _runtime_obj="$_runtime_dir/runtime_helpers.o"
    _runtime_bin="$_runtime_dir/runtime_helpers"
    _runtime_driver="$_runtime_dir/runtime_fixture_driver"

    echo "[backend-runtime] emit -> assemble -> link -> run"
    build_linux_fixture_driver backend-runtime-driver \
        src/tests/compiler_backend_runtime_fixture.tl "$_runtime_driver"
    "$_runtime_driver" "$_runtime_asm"
    for _snippet in \
        ".globl tl_alloc" \
        "tl_alloc:" \
        "call tl_substring" \
        "call tl_string_concat" \
        "rep movsb" \
        "tl_current_arena:" \
        "tl_thread_init:" \
        "tl_current_arena@tpoff" \
        ".L_tl_alloc_new_arena:" \
        "call .L_tl_alloc8"
    do
        assert_contains "$_runtime_asm" "$_snippet" backend-runtime
    done
    _rep_movsb_count=$(grep -c -F "rep movsb" "$_runtime_asm" || true)
    if [ "$_rep_movsb_count" -lt 1 ]; then
        echo "FAIL: backend-runtime expected at least 1 rep movsb copy, got $_rep_movsb_count" >&2
        exit 1
    fi
    for _snippet in \
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
        ".globl tl_string_eq" \
        "tl_string_eq:" \
        ".globl tl_string_to_int" \
        "tl_string_to_int:" \
        ".globl tl_hash_string" \
        "tl_hash_string:" \
        ".extern tl_string_to_int" \
        ".extern tl_hash_string" \
        "tl_print_err:" \
        "tl_print_string:" \
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
        ".extern .L_tl_read_stdin_line" \
        ".extern .L_tl_read_stdin_bytes" \
        ".extern .L_tl_stdin_eof" \
        ".extern .L_tl_flush_stdout" \
        ".L_tl_read_stdin_line:" \
        ".L_tl_read_stdin_bytes:" \
        ".L_tl_stdin_eof:" \
        ".L_tl_flush_stdout:" \
        "tl_process_output:" \
        "tl_process_start:" \
        "tl_process_wait:" \
        ".L_tl_process_read_all:" \
        ".L_tl_process_exec_marker:" \
        ".L_tl_substring_copy_loop:" \
        ".L_tl_string_concat_copy_a:" \
        ".L_tl_string_concat_copy_b:" \
        "path_copy_loop:" \
        "path_copy_done:"
    do
        assert_not_contains "$_runtime_asm" "$_snippet" backend-runtime
    done
    # The direct backend fixture does not lower TypeLisp runtime-prelude bodies.
    # Provide freestanding link-only targets for tl_alloc's OOM path and the
    # moved string construction helpers; the happy path must not execute them.
    _runtime_abort_asm="$_runtime_dir/runtime_abort.s"
    _runtime_abort_obj="$_runtime_dir/runtime_abort.o"
    cat > "$_runtime_abort_asm" <<'EOF'
    .text
    .globl tl_oom_abort
tl_oom_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall
    .globl tl_substring
tl_substring:
    xorl %eax, %eax
    ret
    .globl tl_string_concat
tl_string_concat:
    xorl %eax, %eax
    ret
EOF
    as "$_runtime_asm" -o "$_runtime_obj"
    as "$_runtime_abort_asm" -o "$_runtime_abort_obj"
    ld "$_runtime_obj" "$_runtime_abort_obj" -o "$_runtime_bin" -e "$(linux_entry_symbol_for_asm "$_runtime_asm")"
    set +e
    "$_runtime_bin" < /dev/null > "$_runtime_dir/runtime.stdout" 2> "$_runtime_dir/runtime.stderr"
    _got=$?
    set -e
    if [ "$_got" -ne 42 ] || [ -s "$_runtime_dir/runtime.stdout" ] || [ -s "$_runtime_dir/runtime.stderr" ]; then
        echo "FAIL: backend runtime fixture expected exit 42 with no output, got $_got" >&2
        exit 1
    fi

    _stack_dir="$WORKDIR/backend-stack-args"
    mkdir -p "$_stack_dir"
    _stack_asm="$_stack_dir/stack_args.s"
    _stack_obj="$_stack_dir/stack_args.o"
    _stack_bin="$_stack_dir/stack_args"
    _stack_driver="$_stack_dir/stack_args_fixture_driver"

    echo "[backend-stack-args] emit -> assemble -> link -> run"
    build_linux_fixture_driver backend-stack-args-driver \
        src/tests/compiler_backend_stack_args_fixture.tl "$_stack_driver"
    "$_stack_driver" "$_stack_asm" linux-x86_64
    for _snippet in \
        "call _tl_add8" \
        "call _tl_f10check" \
        "call _tl_mixcheck"
    do
        assert_contains "$_stack_asm" "$_snippet" backend-stack-args
    done
    # The former per-call `subq $16 / addq $16` outgoing-arg dip was replaced by
    # the frame-pointer-omission prologue, which folds the outgoing stack-arg
    # reservation into the function frame (`subq $N,%rsp` released by a matching
    # `addq $N,%rsp`; N is codegen-dependent, e.g. 104/200/232/344). Assert a
    # frame is reserved and released rather than hardcoding the pre-campaign 16
    # (the load-bearing stack-arg stores below are unchanged by the campaign).
    assert_matches "$_stack_asm" '^[[:space:]]+subq \$[0-9]+, %rsp$' backend-stack-args
    assert_matches "$_stack_asm" '^[[:space:]]+addq \$[0-9]+, %rsp$' backend-stack-args
    assert_matches "$_stack_asm" '^[[:space:]]+movq .* 0\(%rsp\)$' backend-stack-args
    assert_matches "$_stack_asm" '^[[:space:]]+movq .* 8\(%rsp\)$' backend-stack-args
    assert_matches "$_stack_asm" '^[[:space:]]+movsd .* [0-9]+\(%rsp\)$' backend-stack-args
    assert_not_contains "$_stack_asm" "backend: too many call args" backend-stack-args
    as "$_stack_asm" -o "$_stack_obj"
    ld "$_stack_obj" -o "$_stack_bin" -e "$(linux_entry_symbol_for_asm "$_stack_asm")"
    set +e
    "$_stack_bin" < /dev/null > "$_stack_dir/stack.stdout" 2> "$_stack_dir/stack.stderr"
    _got=$?
    set -e
    if [ "$_got" -ne 96 ] || [ -s "$_stack_dir/stack.stdout" ] || [ -s "$_stack_dir/stack.stderr" ]; then
        echo "FAIL: backend stack-args fixture expected exit 96 with no output, got $_got" >&2
        exit 1
    fi

    _raw_ptr_dir="$WORKDIR/backend-raw-pointer"
    mkdir -p "$_raw_ptr_dir"
    _raw_ptr_asm="$_raw_ptr_dir/raw_pointer.s"
    _raw_ptr_obj="$_raw_ptr_dir/raw_pointer.o"
    _raw_ptr_abort_asm="$_raw_ptr_dir/raw_pointer_abort.s"
    _raw_ptr_abort_obj="$_raw_ptr_dir/raw_pointer_abort.o"
    _raw_ptr_bin="$_raw_ptr_dir/raw_pointer"
    _raw_ptr_driver="$_raw_ptr_dir/raw_pointer_fixture_driver"

    echo "[backend-raw-pointer] emit -> assemble -> link -> run"
    build_linux_fixture_driver backend-raw-pointer-driver \
        src/tests/compiler_backend_raw_pointer_fixture.tl "$_raw_ptr_driver"
    "$_raw_ptr_driver" "$_raw_ptr_asm" linux-x86_64
    for _snippet in \
        "_tl_write_i64:" \
        "_tl_read_i64:" \
        "call _tl_write_i64" \
        "call _tl_read_i64" \
        "call tl_alloc" \
        "tl_alloc:"
    do
        assert_contains "$_raw_ptr_asm" "$_snippet" backend-raw-pointer
    done
    assert_matches "$_raw_ptr_asm" '^[[:space:]]+movq \(%r(ax|bx|cx|dx|si|di|8|9|10|11|12|13|14|15)\), %r(ax|bx|cx|dx|si|di|8|9|10|11|12|13|14|15)$' backend-raw-pointer
    assert_not_contains "$_raw_ptr_asm" "# TODO" backend-raw-pointer
    # This direct backend fixture bypasses the driver-owned runtime prelude.
    # Provide freestanding support for runtime calls this fixture can emit:
    # bounds-check abort, tl_alloc's out-of-memory tail-jump (tl_oom_abort,
    # #2221), and the non-zero array initialization helper. `tl_array_zero`
    # is emitted by the backend runtime prelude itself.
    cat > "$_raw_ptr_abort_asm" <<'EOF'
    .text
    .globl tl_oob_abort
tl_oob_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_oob_abort_at
tl_oob_abort_at:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_oom_abort
tl_oom_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_array_fill8
tl_array_fill8:
    testq %rsi, %rsi
    jle .L_tl_array_fill8_done
.L_tl_array_fill8_loop:
    movq %rdx, (%rdi)
    addq $8, %rdi
    subq $1, %rsi
    jg .L_tl_array_fill8_loop
.L_tl_array_fill8_done:
    ret
EOF
    as "$_raw_ptr_asm" -o "$_raw_ptr_obj"
    as "$_raw_ptr_abort_asm" -o "$_raw_ptr_abort_obj"
    ld "$_raw_ptr_obj" "$_raw_ptr_abort_obj" -o "$_raw_ptr_bin" -e "$(linux_entry_symbol_for_asm "$_raw_ptr_asm")"
    set +e
    "$_raw_ptr_bin" < /dev/null > "$_raw_ptr_dir/raw_pointer.stdout" 2> "$_raw_ptr_dir/raw_pointer.stderr"
    _got=$?
    set -e
    if [ "$_got" -ne 42 ] || [ -s "$_raw_ptr_dir/raw_pointer.stdout" ] || [ -s "$_raw_ptr_dir/raw_pointer.stderr" ]; then
        echo "FAIL: backend raw-pointer fixture expected exit 42 with no output, got $_got" >&2
        exit 1
    fi

    echo "Backend runtime fixture checks passed."
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
    lld-link -NOLOGO "$(cygpath -aw "$_obj")" "-OUT:$(cygpath -aw "$_bin")" -SUBSYSTEM:CONSOLE \
        -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib || {
        echo "FAIL: $_label link failed" >&2
        exit 1
    }
}

run_windows_program_fixture() {
    _label=$1
    _source=$2
    _want=$3
    _opt_level=$4
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
    if [ "$got" -ne "$_want" ] || [ -s "$_stdout" ] || [ -s "$_stderr" ]; then
        echo "FAIL: $_label expected exit $_want with no output, got $got" >&2
        show_stream_if_nonempty stdout "$_stdout"
        show_stream_if_nonempty stderr "$_stderr"
        exit 1
    fi
}

run_windows_backend_fixtures() {
    run_windows_program_fixture \
        regalloc-loop-split-evicted-region-var-opt2 \
        tests/integration/regalloc_loop_split_evicted_region_var.tl \
        42 \
        2
    run_windows_program_fixture \
        phi-forward-scavenge-live-through-opt2 \
        tests/integration/phi_forward_scavenge_live_through.tl \
        42 \
        2
    run_windows_program_fixture \
        inline-alloc-scavenge-live-through-opt2 \
        tests/integration/inline_alloc_scavenge_live_through.tl \
        42 \
        2
    run_windows_program_fixture \
        f32-mandelbrot-loop-opt0 \
        tests/integration/opt2_f32_mandelbrot_loop.tl \
        42 \
        0
    run_windows_program_fixture \
        f32-mandelbrot-loop-opt2 \
        tests/integration/opt2_f32_mandelbrot_loop.tl \
        42 \
        2

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
    # (mirrors build_linux_fixture_driver).
    _driver_asm="$_runtime_dir/fixture_driver.s"
    _driver_obj="$_runtime_dir/fixture_driver.obj"
    _driver_bin="$_runtime_dir/fixture_driver.exe"
    "$COMPILER" compile src/tests/compiler_backend_runtime_fixture.tl \
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
        "tl_print_string:" \
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
    _driver_bin="$_driver_dir/selfhost-compile.exe"
    _driver_source="$_driver_dir/main.tl"
    _driver_asm="$_driver_dir/main.s"
    _driver_linux_asm="$_driver_dir/main-linux.s"
    _driver_windows_asm="$_driver_dir/main-windows.s"
    _driver_stdout="$_driver_dir/run.stdout"
    _driver_stderr="$_driver_dir/run.stderr"
    _driver_code="$_driver_dir/run.exit"

    echo "[windows-selfhost-compile-driver] build -> exercise"
    # The compile-only bootstrapped stage1 has no `build` host action, so build the
    # driver via compile + clang + lld-link (mirrors the runtime fixture above).
    _driver_self_asm="$_driver_dir/selfhost-compile.s"
    _driver_self_obj="$_driver_dir/selfhost-compile.obj"
    "$COMPILER" compile src/main.tl --target windows-x86_64 --cfg windows -o "$_driver_self_asm" || {
        echo "FAIL: windows-selfhost-compile-driver compile failed" >&2
        exit 1
    }
    assemble_link_windows "$_driver_self_asm" "$_driver_self_obj" "$_driver_bin" windows-selfhost-compile-driver
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
    assert_contains "$_driver_stderr" "Error: unknown target 'plan9-x86_64'. Expected linux-x86_64 or windows-x86_64" \
        windows-selfhost-compile-driver-bad-target
    if [ -e "$_bad_target_asm" ]; then
        echo "FAIL: invalid target wrote assembly: $_bad_target_asm" >&2
        exit 1
    fi

    _comptime_source="$_driver_dir/comptime-type.tl"
    _comptime_asm="$_driver_dir/comptime-type.s"
    cat > "$_comptime_source" <<'EOF'
(define (alloc [comptime T : type] [n : i64]) : (Array i64) (make-array T n))
(define (main) : (Array i64) (alloc (type i64) 4))
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
    _link_result_rows=0
    _link_result_structure_ok=1
    exec 3< "$WINDOWS_LINK_RESULTS"
    while IFS='|' read -r \
        _link_case \
        _link_want \
        _link_stdout_spec \
        _link_stderr_spec \
        _link_runtime_args || [ -n "$_link_case" ]; do
        [ -n "$_link_case" ] || continue
        if ! IFS="$(printf '\t')" read -r \
            _link_result_label \
            _link_status \
            _link_exit \
            _link_error \
            _link_elapsed \
            _link_command <&3; then
            echo "FAIL: Windows integration link results ended before $_link_case" >&2
            _link_result_structure_ok=0
            break
        fi
        _link_result_rows=$((_link_result_rows + 1))
        if [ "$_link_result_label" != "$_link_case" ]; then
            echo "FAIL: Windows integration link result order changed: expected $_link_case, got $_link_result_label" >&2
            _link_result_structure_ok=0
            break
        fi

        case "$_link_status" in
            ok) _link_timing_status=0 ;;
            failed) _link_timing_status=$_link_exit ;;
            *) _link_timing_status=1 ;;
        esac
        ci_timing_record_elapsed \
            "$_link_case" \
            link \
            "$_link_elapsed" \
            "$_link_timing_status"

        if [ "$_link_status" = ok ]; then
            if [ ! -f "$WORKDIR/$_link_case/$_link_case.exe" ]; then
                echo "FAIL: $_link_case link result omitted its executable" >&2
                failed=$((failed + 1))
                ran=$((ran + 1))
                continue
            fi
            windows_queue_manifest_case \
                "$_link_case" \
                "$_link_want" \
                "$_link_stdout_spec" \
                "$_link_stderr_spec" \
                "$_link_runtime_args"
            continue
        fi

        _link_decoded_error=$(windows_queue_decode "$_link_error")
        _link_decoded_command=$(windows_queue_decode "$_link_command")
        echo "FAIL: $_link_case link status=$_link_status exit=$_link_exit" >&2
        echo "  command: $_link_decoded_command" >&2
        if [ -n "$_link_decoded_error" ]; then
            echo "  error: $_link_decoded_error" >&2
        fi
        show_compile_stream_diagnostic \
            stdout \
            "$WORKDIR/$_link_case/$_link_case.build.stdout"
        show_compile_stream_diagnostic \
            stderr \
            "$WORKDIR/$_link_case/$_link_case.build.stderr"
        failed=$((failed + 1))
        ran=$((ran + 1))
    done < "$WINDOWS_LINK_CASES"

    if [ "$_link_result_structure_ok" -eq 1 ] && IFS= read -r _link_extra_result <&3; then
        echo "FAIL: Windows integration linker returned an unexpected extra result" >&2
        _link_result_structure_ok=0
    fi
    exec 3<&-
    if [ "$_link_result_structure_ok" -ne 1 ]; then
        return 1
    fi
    if [ "$_link_result_rows" -ne "$WINDOWS_LINK_REQUESTS" ]; then
        echo "FAIL: Windows integration linker attributed $_link_result_rows of $WINDOWS_LINK_REQUESTS requests" >&2
        return 1
    fi

    ci_timing_set_now_ms
    _link_attribution_finished=$CI_TIMING_NOW_MS
    WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS=$((_link_attribution_finished - _link_attribution_started))
    ci_timing_record_elapsed \
        windows-manifest \
        link-attribution \
        "$WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS" \
        0
}

windows_enqueue_missing_launch_self_test() {
    WINDOWS_RUNNER_MISSING_LABEL=windows_runner_missing_executable
    _dir="$WORKDIR/windows-runner-self-test"
    mkdir -p "$_dir"
    windows_queue_append_request "$WINDOWS_QUEUE" "$WINDOWS_RUNNER_MISSING_LABEL" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.exe" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.stdout" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.stderr" \
        "$WINDOWS_WORKDIR_WIN\\windows-runner-self-test\\missing.exit" \
        - - -
    WINDOWS_QUEUE_REQUESTS=$((WINDOWS_QUEUE_REQUESTS + 1))
}

windows_run_manifest_queue() {
    windows_enqueue_missing_launch_self_test
    WINDOWS_MANIFEST_POWERSHELL_STARTS=1
    if ! windows_run_request_file \
        "$WINDOWS_QUEUE_WIN" \
        "$WINDOWS_RESULTS_WIN" \
        "$WINDOWS_ASSERTIONS_WIN" \
        "$WINDOWS_SUMMARY_WIN" \
        "$WINDOWS_RUNNER_STDOUT" \
        "$WINDOWS_RUNNER_STDERR"; then
        echo "FAIL: Windows integration queue runner failed" >&2
        show_stream_if_nonempty stdout "$WINDOWS_RUNNER_STDOUT"
        show_stream_if_nonempty stderr "$WINDOWS_RUNNER_STDERR"
        return 1
    fi
    WINDOWS_MANIFEST_RUN_MS=$WINDOWS_LAST_RUN_MS
    WINDOWS_SUMMARY_REQUESTS=
    WINDOWS_SUMMARY_CHILD_STARTS=
    WINDOWS_SUMMARY_LAUNCH_FAILURES=
    WINDOWS_SUMMARY_ASSERTIONS=
    WINDOWS_SUMMARY_RESULT_PROCESS_MS=
    WINDOWS_SUMMARY_ASSERT_MS=
    WINDOWS_SUMMARY_ELAPSED_MS=
    while IFS='=' read -r _summary_key _summary_value || [ -n "$_summary_key" ]; do
        case "$_summary_key" in
            requests) WINDOWS_SUMMARY_REQUESTS=$_summary_value ;;
            child_starts) WINDOWS_SUMMARY_CHILD_STARTS=$_summary_value ;;
            launch_failures) WINDOWS_SUMMARY_LAUNCH_FAILURES=$_summary_value ;;
            assertions) WINDOWS_SUMMARY_ASSERTIONS=$_summary_value ;;
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
    WINDOWS_MANIFEST_RESULT_PROCESS_MS=$WINDOWS_SUMMARY_RESULT_PROCESS_MS
    ci_timing_record_elapsed windows-manifest queue-prepare "$WINDOWS_MANIFEST_QUEUE_PREP_MS" 0
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
}

windows_assert_queued_cases() {
    ci_timing_set_now_ms
    _assert_report_started=$CI_TIMING_NOW_MS
    _assertion_rows=0
    while IFS="$(printf '\t')" read -r \
        _name \
        _status \
        _exit \
        _want \
        _error \
        _run_ms \
        _assert_ms \
        _exit_matches \
        _stdout_matches \
        _stderr_matches || [ -n "$_name" ]; do
        [ -n "$_name" ] || continue
        _assertion_rows=$((_assertion_rows + 1))
        _case_dir="$WORKDIR/$_name"
        _asm="$_case_dir/$_name.s"
        _run_shell_stderr="$_case_dir/$_name.run-shell.stderr"

        assert_manifest_assembly_requirements "$_name" "$_asm"

        _case_failed=0
        if [ "$_status" != ok ]; then
            _decoded_error=$(windows_queue_decode "$_error")
            echo "FAIL: $_name Windows launch failed: $_decoded_error" >&2
            _case_failed=1
        else
            ci_timing_record_elapsed "$_name" run "$_run_ms" "$_exit"
            if [ "$_exit_matches" -ne 1 ]; then
                echo "FAIL: $_name expected exit $_want, got $_exit" >&2
                _case_failed=1
            fi
            if [ "$_stdout_matches" -ne 1 ]; then
                echo "FAIL: $_name stdout mismatch" >&2
                if command -v diff >/dev/null 2>&1; then
                    diff -u \
                        "$_case_dir/$_name.expected.stdout.cmp" \
                        "$_case_dir/$_name.stdout.cmp" >&2 || true
                fi
                _case_failed=1
            fi
            if [ "$_stderr_matches" -ne 1 ]; then
                echo "FAIL: $_name stderr mismatch" >&2
                if command -v diff >/dev/null 2>&1; then
                    diff -u \
                        "$_case_dir/$_name.expected.stderr.cmp" \
                        "$_case_dir/$_name.stderr.cmp" >&2 || true
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
        WINDOWS_MANIFEST_ASSERT_MS=$((WINDOWS_MANIFEST_ASSERT_MS + _assert_ms))
        WINDOWS_MANIFEST_ASSERTS=$((WINDOWS_MANIFEST_ASSERTS + 1))
        ci_timing_record_elapsed "$_name" assert "$_assert_ms" "$_assert_status"
    done < "$WINDOWS_ASSERTIONS"
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
    # The old one-shot path is intentionally exercised only here as an oracle;
    # the 292-case corpus itself uses the one persistent queue runner above.
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
    if [ $((INTEGRATION_BATCHED_CASES + INTEGRATION_STANDALONE_COMPILES)) -ne "$WINDOWS_MANIFEST_QUEUED" ]; then
        echo "FAIL: Windows COFF plan did not account for every queued manifest case" >&2
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
    echo "  manifest cases queued: $WINDOWS_MANIFEST_QUEUED"
    echo "  process starts: legacy powershell=$WINDOWS_MANIFEST_QUEUED, queued powershell=$WINDOWS_MANIFEST_POWERSHELL_STARTS, child executables=$WINDOWS_SUMMARY_CHILD_STARTS"
    echo "  queue encoding helper processes: 0"
    echo "  cygpath conversions: legacy launch-path lower bound=$_legacy_launch_cygpath, queued manifest=$WINDOWS_MANIFEST_CYGPATH_CONVERSIONS"
    echo "  links: requests=$WINDOWS_LINK_SUMMARY_REQUESTS child_starts=$WINDOWS_LINK_SUMMARY_CHILD_STARTS launch_failures=$WINDOWS_LINK_SUMMARY_LAUNCH_FAILURES failed=$WINDOWS_LINK_SUMMARY_FAILED_PROCESSES missing_outputs=$WINDOWS_LINK_SUMMARY_MISSING_OUTPUTS"
    echo "  link scheduler: jobs=$WINDOWS_LINK_SUMMARY_JOBS peak=$WINDOWS_LINK_SUMMARY_PEAK_CONCURRENCY wall_ms=$WINDOWS_MANIFEST_LINK_WALL_MS child_ms=$WINDOWS_MANIFEST_LINK_MS powershell=$WINDOWS_LINK_POWERSHELL_STARTS"
    echo "  queue: requests=$WINDOWS_SUMMARY_REQUESTS launch_failures=$WINDOWS_SUMMARY_LAUNCH_FAILURES elapsed_ms=$WINDOWS_SUMMARY_ELAPSED_MS"
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
    echo "  phase_ms: batch_compile=$WINDOWS_MANIFEST_BATCH_COMPILE_MS standalone_compile=$WINDOWS_MANIFEST_COMPILE_MS plan_process=$WINDOWS_MANIFEST_PLAN_PROCESS_MS assemble=$WINDOWS_MANIFEST_ASSEMBLE_MS link_child_sum=$WINDOWS_MANIFEST_LINK_MS link_scheduler=$WINDOWS_MANIFEST_LINK_WALL_MS link_helper=$WINDOWS_MANIFEST_LINK_HELPER_MS link_plan=$WINDOWS_MANIFEST_LINK_PREP_MS link_result_process=$WINDOWS_MANIFEST_LINK_RESULT_PROCESS_MS link_attribution=$WINDOWS_MANIFEST_LINK_ATTRIBUTION_MS queue_prepare=$WINDOWS_MANIFEST_QUEUE_PREP_MS runner=$WINDOWS_MANIFEST_RUN_MS result_process=$WINDOWS_MANIFEST_RESULT_PROCESS_MS assertions=$WINDOWS_MANIFEST_ASSERT_MS assertion_report=$WINDOWS_MANIFEST_ASSERT_REPORT_MS"
    echo "  phase_counts: batch_compile=$WINDOWS_MANIFEST_BATCH_COMPILES standalone_compile=$WINDOWS_MANIFEST_COMPILES assemble=$WINDOWS_MANIFEST_ASSEMBLES link=$WINDOWS_MANIFEST_LINKS assert=$WINDOWS_MANIFEST_ASSERTS"
    echo "  differential oracle: legacy powershell=$WINDOWS_DIFFERENTIAL_POWERSHELL_STARTS cygpath=$WINDOWS_DIFFERENTIAL_CYGPATH_CONVERSIONS"
}

ci_timing_run manifest validate validate_manifest
if [ "$VALIDATE_MANIFEST_ONLY" -eq 1 ]; then
    echo "integration manifest validation passed for $HOST_OS"
    exit 0
fi

# Batched compile pre-pass (#5555). Every manifest case is a compile-success
# case -- the third field is the *program's* exit code, not a compile
# expectation -- so the only thing that partitions them is whether the case
# opted into the on-disk stdlib layout. That makes two argv groups per host, and
# each group compiles in bounded `compile --batch` chunks instead of one
# compiler process per case.
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

# Stage sources and emit one chunk list per group. Staging repeats what the case
# loop does; both are plain file copies, so running them twice is idempotent.
integration_batch_precompile() {
    [ "$INTEGRATION_BATCH_SIZE" -gt 0 ] || return 0
    _group0="$WORKDIR/batch-embedded.list"
    _group1="$WORKDIR/batch-stage-stdlib.list"
    : > "$_group0"
    : > "$_group1"
    while IFS='|' read -r _b_name _b_source _b_want _b_stdout _b_args _b_deps _b_extra _b_suite || [ -n "$_b_name" ]; do
        case "$_b_name" in
            "" | \#*) continue ;;
        esac
        _b_stage=0
        case "${_b_extra:-}" in
            stage-stdlib) _b_stage=1 ;;
        esac
        _b_case_dir="$WORKDIR/$_b_name"
        mkdir -p "$_b_case_dir"
        cp "$ROOT/$_b_source" "$_b_case_dir/$_b_name.tl"
        for _b_dep in $(deps_or_empty "$_b_deps"); do
            copy_dep "$_b_dep" "$(dirname -- "$ROOT/$_b_source")" "$_b_case_dir" "$_b_stage"
        done
        # Relative to ROOT, which is the working directory: the compiler reads
        # these out of a file, so no shell path translation happens on Windows.
        _b_rel="target/integration-verify/$HOST_OS/$_b_name/$_b_name"
        if [ "$HOST_OS" = windows ]; then
            _b_force=
            if _b_assembly_reason=$(windows_manifest_assembly_reason "$_b_name"); then
                _b_force='|force-assembly'
            fi
            if [ "$_b_stage" -eq 1 ]; then
                printf '%s.tl|%s.obj|%s.s%s\n' \
                    "$_b_rel" "$_b_rel" "$_b_rel" "$_b_force" >> "$_group1"
            else
                printf '%s.tl|%s.obj|%s.s%s\n' \
                    "$_b_rel" "$_b_rel" "$_b_rel" "$_b_force" >> "$_group0"
            fi
        elif [ "$_b_stage" -eq 1 ]; then
            printf '%s.tl|%s.s\n' "$_b_rel" "$_b_rel" >> "$_group1"
        else
            printf '%s.tl|%s.s\n' "$_b_rel" "$_b_rel" >> "$_group0"
        fi
    done < "$NORMALIZED_MANIFEST"

    for _group in embedded stage-stdlib; do
        if [ "$_group" = embedded ]; then
            _group_list=$_group0
        else
            _group_list=$_group1
        fi
        [ -s "$_group_list" ] || continue
        _total=$(wc -l < "$_group_list" | tr -d ' ')
        _offset=0
        _index=0
        while [ "$_offset" -lt "$_total" ]; do
            _index=$((_index + 1))
            _chunk="$WORKDIR/batch-$_group-$_index.list"
            sed -n "$((_offset + 1)),$((_offset + INTEGRATION_BATCH_SIZE))p" \
                "$_group_list" > "$_chunk"
            if [ "$_group" = embedded ]; then
                integration_batch_run_chunk "$_chunk" "$_group-$_index" \
                    $INTEGRATION_BATCH_TARGET_ARGS \
                    --stdlib-root "$ROOT/src"
            else
                integration_batch_run_chunk "$_chunk" "$_group-$_index" \
                    $INTEGRATION_BATCH_TARGET_ARGS \
                    --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src"
            fi
            _offset=$((_offset + INTEGRATION_BATCH_SIZE))
        done
    done
    echo "[integration] batched compile: $INTEGRATION_BATCH_CHUNKS chunk(s)" \
        "of up to $INTEGRATION_BATCH_SIZE, $INTEGRATION_BATCH_FAILED_CHUNKS failed"
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
    for _group in embedded stage-stdlib; do
        _list="$WORKDIR/batch-$_group-1.list"
        [ -s "$_list" ] || continue
        # The final entry has the most warmed-session predecessors available in
        # a chunk. Selecting it exercises state contamination while retaining
        # the original one-standalone-compile-per-group cost (#5793).
        _entry=$(integration_batch_sentinel_entry "$_list")
        _sent_src=${_entry%%|*}
        _sent_asm=${_entry#*|}
        [ -s "$_sent_asm" ] || continue
        _sent_ref="$WORKDIR/batch-$_group.sentinel.s"
        if [ "$_group" = embedded ]; then
            # shellcheck disable=SC2086
            "$COMPILER" compile "$_sent_src" $INTEGRATION_BATCH_TARGET_ARGS \
                --stdlib-root "$ROOT/src" -o "$_sent_ref" \
                > "$WORKDIR/batch-$_group.sentinel.stdout" \
                2> "$WORKDIR/batch-$_group.sentinel.stderr"
        else
            # shellcheck disable=SC2086
            "$COMPILER" compile "$_sent_src" $INTEGRATION_BATCH_TARGET_ARGS \
                --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
                -o "$_sent_ref" \
                > "$WORKDIR/batch-$_group.sentinel.stdout" \
                2> "$WORKDIR/batch-$_group.sentinel.stderr"
        fi
        if ! cmp -s "$_sent_asm" "$_sent_ref"; then
            echo "FAIL: batched and standalone assembly differ for $_sent_src" >&2
            echo "  batch:      $_sent_asm" >&2
            echo "  standalone: $_sent_ref" >&2
            exit 1
        fi
        echo "[integration] batch/standalone assembly identical for $_sent_src"
    done
}

ci_timing_run manifest batch-compile integration_batch_precompile
integration_batch_sentinel

failed=0
ran=0

while IFS='|' read -r name source want stdout_spec runtime_args deps extra suite_members || [ -n "$name" ]; do
    case "$name" in
        "" | \#*) continue ;;
    esac

    expected_stderr_spec=-
    stage_stdlib=0
    case "${extra:-}" in
        "") ;;
        stage-stdlib) stage_stdlib=1 ;;
        expected-stderr:*) expected_stderr_spec=${extra#expected-stderr:} ;;
    esac

    source_path="$ROOT/$source"
    source_dir=$(dirname -- "$source_path")
    case_dir="$WORKDIR/$name"
    mkdir -p "$case_dir"
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        stage_started=$CI_TIMING_NOW_MS
    fi
    work_src="$case_dir/$name.tl"
    # The batch pre-pass already staged every case, and staging is a
    # deterministic file copy, so repeating it here would double the corpus's
    # I/O for no change in inputs (#5555).
    if [ ! -s "$work_src" ]; then
        cp "$source_path" "$work_src"

        for dep in $(deps_or_empty "$deps"); do
            copy_dep "$dep" "$source_dir" "$case_dir" "$stage_stdlib"
        done
    fi
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        stage_finished=$CI_TIMING_NOW_MS
        ci_timing_record_elapsed "$name" stage "$((stage_finished - stage_started))" 0
    fi

    asm="$case_dir/$name.s"
    if [ "$HOST_OS" = windows ]; then
        obj="$case_dir/$name.obj"
    else
        obj="$case_dir/$name.o"
    fi
    bin="$case_dir/$name"
    stdout="$case_dir/$name.stdout"
    stderr="$case_dir/$name.stderr"
    expected_stdout_cmp="$case_dir/$name.expected.stdout.cmp"
    expected_stderr_cmp="$case_dir/$name.expected.stderr.cmp"
    stdout_cmp="$case_dir/$name.stdout.cmp"
    stderr_cmp="$case_dir/$name.stderr.cmp"
    expected_stdout="$case_dir/$name.expected.stdout"
    expected_stderr="$case_dir/$name.expected.stderr"
    code_file="$case_dir/$name.exit"
    build_stdout="$case_dir/$name.build.stdout"
    build_stderr="$case_dir/$name.build.stderr"
    run_shell_stderr="$case_dir/$name.run-shell.stderr"

    echo "[$name] build -> run ($HOST_OS)"
    if [ "$HOST_OS" = windows ]; then
        # The compile-only bootstrapped stage1 has `compile` but not `build`, so
        # consume the batch COFF-or-assembly selection, invoke clang only for
        # selected assembly, then link with lld-link.
        case_dir_win="$WINDOWS_WORKDIR_WIN\\$name"
        obj_win="$case_dir_win\\$name.obj"
        bin_win="$case_dir_win\\$name.exe"
        build_stdout_win="$case_dir_win\\$name.build.stdout"
        build_stderr_win="$case_dir_win\\$name.build.stderr"
        windows_artifact="$case_dir/windows-coff.artifact"
        windows_needs_assemble=1
        windows_assembly_class=standalone
        # Stdlib comes from the embedded payload unless the case opted into
        # the on-disk layout (stage-stdlib), matching the staged copies.
        if [ -s "$windows_artifact" ]; then
            if ! IFS='|' read -r \
                windows_artifact_kind \
                windows_artifact_path \
                windows_artifact_reason < "$windows_artifact"; then
                echo "FAIL: $name has an unreadable Windows COFF artifact marker" >&2
                exit 1
            fi
            INTEGRATION_BATCHED_CASES=$((INTEGRATION_BATCHED_CASES + 1))
            build_rc=0
            : > "$build_stdout"
            : > "$build_stderr"
            case "$windows_artifact_kind" in
                coff-object)
                    if [ "$windows_artifact_path" != "$obj" ] || [ ! -s "$obj" ]; then
                        echo "FAIL: $name Windows COFF object marker does not name its object" >&2
                        exit 1
                    fi
                    windows_needs_assemble=0
                    ;;
                assembly)
                    if [ "$windows_artifact_path" != "$asm" ] || [ ! -s "$asm" ]; then
                        echo "FAIL: $name Windows COFF assembly marker does not name its assembly" >&2
                        exit 1
                    fi
                    if [ "$windows_artifact_reason" = forced-assembly ]; then
                        windows_assembly_class=forced
                    else
                        windows_assembly_class=fallback
                    fi
                    ;;
                *)
                    echo "FAIL: $name has unknown Windows COFF artifact kind: $windows_artifact_kind" >&2
                    exit 1
                    ;;
            esac
        elif [ "$stage_stdlib" -eq 1 ]; then
            INTEGRATION_STANDALONE_COMPILES=$((INTEGRATION_STANDALONE_COMPILES + 1))
            windows_timed_compile "$COMPILER" compile "$work_src" --target windows-x86_64 --cfg windows \
                --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" -o "$asm" \
                > "$build_stdout" 2> "$build_stderr"
        else
            INTEGRATION_STANDALONE_COMPILES=$((INTEGRATION_STANDALONE_COMPILES + 1))
            windows_timed_compile "$COMPILER" compile "$work_src" --target windows-x86_64 --cfg windows \
                --stdlib-root "$ROOT/src" -o "$asm" \
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
                "compile $work_src --target windows-x86_64 --cfg windows --stdlib-root $ROOT/src -o $asm (stage-stdlib=$stage_stdlib)"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if [ "$windows_needs_assemble" -eq 1 ]; then
            WINDOWS_CURRENT_ASSEMBLY_CLASS=$windows_assembly_class
            if ! windows_timed_assemble --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" \
                >> "$build_stdout" 2>> "$build_stderr"; then
                echo "FAIL: $name assemble failed" >&2
                show_build_streams "$build_stdout" "$build_stderr"
                failed=$((failed + 1))
                ran=$((ran + 1))
                continue
            fi
        fi
        if ! native_objs=$(compile_windows_c_deps "$deps" "$case_dir" "$build_stdout" "$build_stderr" "$case_dir_win"); then
            echo "FAIL: $name C dependency compile failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        windows_queue_manifest_link \
            "$name" \
            "$obj_win" \
            "$native_objs" \
            "$bin_win" \
            "$build_stdout_win" \
            "$build_stderr_win" \
            "$want" \
            "$stdout_spec" \
            "$expected_stderr_spec" \
            "$runtime_args"
        continue
    else
        set +e
        # Stdlib comes from the embedded payload unless the case opted into
        # the on-disk layout (stage-stdlib), matching the staged copies.
        if [ -s "$asm" ]; then
            # Produced by the batch pre-pass (#5555). A failed chunk removes its
            # outputs, so reaching here with no assembly means compiling now.
            INTEGRATION_BATCHED_CASES=$((INTEGRATION_BATCHED_CASES + 1))
            : > "$build_stdout"
            : > "$build_stderr"
            true
        elif [ "$stage_stdlib" -eq 1 ]; then
            INTEGRATION_STANDALONE_COMPILES=$((INTEGRATION_STANDALONE_COMPILES + 1))
            ci_timing_run "$name" compile "$COMPILER" compile "$work_src" \
                --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" -o "$asm" \
                > "$build_stdout" 2> "$build_stderr"
        else
            INTEGRATION_STANDALONE_COMPILES=$((INTEGRATION_STANDALONE_COMPILES + 1))
            ci_timing_run "$name" compile "$COMPILER" compile "$work_src" \
                --stdlib-root "$ROOT/src" -o "$asm" \
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
                "compile $work_src --stdlib-root $ROOT/src -o $asm (stage-stdlib=$stage_stdlib)"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if ! ci_timing_run "$name" assemble \
            as "$asm" -o "$obj" >> "$build_stdout" 2>> "$build_stderr"; then
            echo "FAIL: $name assemble failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if ! native_objs=$(compile_linux_c_deps "$deps" "$case_dir" "$build_stdout" "$build_stderr"); then
            echo "FAIL: $name C dependency compile failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
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
        # shellcheck disable=SC2086
        if ! ci_timing_run "$name" link \
            ld "$obj" $native_objs -o "$bin" $link_extra -e "$(linux_entry_symbol_for_asm "$asm")" \
            >> "$build_stdout" 2>> "$build_stderr"; then
            echo "FAIL: $name link failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
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
done < "$NORMALIZED_MANIFEST"

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
    if ! windows_runner_differential_self_test; then
        exit 1
    fi
    windows_assert_queued_cases
    if [ "$failed" -eq 0 ]; then
        windows_validate_manifest_artifact_counts
    fi
    windows_print_manifest_summary
fi

if [ "$failed" -gt 0 ]; then
    echo "$failed integration case(s) failed out of $ran" >&2
    exit 1
fi

if [ "$HOST_OS" = linux ]; then
    run_linux_backend_fixtures
else
    run_windows_backend_fixtures
fi

echo "[integration] compile processes: $INTEGRATION_BATCH_CHUNKS batch chunk(s)"     "+ $INTEGRATION_STANDALONE_COMPILES standalone,"     "$INTEGRATION_BATCHED_CASES case(s) served from a batch"
echo "All $ran integration case(s) passed for $HOST_OS."
