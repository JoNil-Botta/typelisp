#!/usr/bin/env sh
set -eu

# verify-integration.sh - manifest-driven native integration runner.
#
# The runner builds each listed TypeLisp program to a native executable, runs it
# outside the Rust test harness, and checks exit code, stdout, and stderr. Linux
# uses the explicit compile -> as -> ld flow; Windows Git Bash/MSYS/Cygwin uses
# host-default typelisp build and PowerShell only to preserve native Windows
# process exit codes larger than 255.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "integration verification is unsupported on this host" >&2
        exit 1
        ;;
esac

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

# Retry transient compiler crashes (#1204, #3150): long manifest runs can hit
# signal-shaped failures that pass immediately in isolation. `is_crash_code`
# (132/134/139 and Windows NTSTATUS crash codes) lets us retry ONLY those
# transient crashes, never a genuine non-zero exit (so an expected failure still
# fails).
. "$ROOT/scripts/lib-retry.sh"
# Default 6 (not 3): large corpus binaries like compiler_lower_smoke hit the
# crash path at a high enough rate that 3 attempts can all crash (observed 3/3
# on PR #1225), so the crash-only retry needs more headroom.
INTEGRATION_ATTEMPTS="${VERIFY_INTEGRATION_ATTEMPTS:-6}"

# Run a `typelisp build`/`compile` invocation, retrying a transient crash.
# Output flows to the caller's streams; sets `build_rc` to the final exit code.
build_with_retry() {
    _bwr_attempt=0
    while :; do
        _bwr_attempt=$((_bwr_attempt + 1))
        set +e
        "$@"
        build_rc=$?
        set -e
        if is_crash_code "$build_rc" && [ "$_bwr_attempt" -lt "$INTEGRATION_ATTEMPTS" ]; then
            echo "  retry ($_bwr_attempt/$INTEGRATION_ATTEMPTS): build crash exit $build_rc — likely transient (#1204/#3150)" >&2
        else
            break
        fi
    done
}

# Run a `$COMPILER run <fixture.tl> …` emit step, retrying ONLY a transient
# crash (these fixtures emit assembly deterministically, so a retry safely
# re-emits) and aborting on a real non-crash failure or exhausted retries — the
# same fail-fast behavior the bare `set -e` invocations had before guarding.
run_fixture_with_retry() {
    build_with_retry "$@"
    if [ "$build_rc" -ne 0 ]; then
        echo "FAIL: fixture run '$*' exited $build_rc" >&2
        exit 1
    fi
}

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

MANIFEST="$ROOT/tests/integration/native-$HOST_OS.manifest"
WORKDIR="$ROOT/target/integration-verify/$HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
NORMALIZED_MANIFEST="$WORKDIR/manifest.normalized"
tr -d '\r' < "$MANIFEST" > "$NORMALIZED_MANIFEST"

PS_RUNNER_WIN=
if [ "$HOST_OS" = windows ]; then
    PS_RUNNER="$WORKDIR/run-windows-program.ps1"
    cat > "$PS_RUNNER" <<'EOF'
$ErrorActionPreference = "Stop"
$exe = $args[0]
$stdout = $args[1]
$stderr = $args[2]
$codeFile = $args[3]
$runArgs = @()
if ($args.Length -gt 4) {
    $runArgs = $args[4..($args.Length - 1)]
}
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
if ($runArgs.Length -gt 0) {
    $psi.Arguments = ($runArgs -join " ")
}
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
$stdoutFile = [System.IO.File]::Create($stdout)
$stderrFile = [System.IO.File]::Create($stderr)
try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
    $process.WaitForExit()
    $stdoutTask.Wait()
    $stderrTask.Wait()
    [System.IO.File]::WriteAllText($codeFile, [string]$process.ExitCode)
}
finally {
    $stdoutFile.Dispose()
    $stderrFile.Dispose()
    $process.Dispose()
}
exit 0
EOF
    PS_RUNNER_WIN=$(cygpath -aw "$PS_RUNNER")
fi

deps_or_empty() {
    case "$1" in
        "" | -) ;;
        *) printf '%s\n' "$1" ;;
    esac
}

requires_symbol_from_deps() {
    for _dep in $(deps_or_empty "$1"); do
        case "$_dep" in
            requires-stage0-symbol:*)
                printf '%s\n' "${_dep#requires-stage0-symbol:}"
                return
                ;;
        esac
    done
}

should_skip_staged() {
    _symbols=$1
    _stderr=$2
    [ -n "$_symbols" ] || return 1
    for _symbol in $(printf '%s\n' "$_symbols" | tr ',' ' '); do
        grep -qF "$_symbol" "$_stderr" && return 0
    done
    return 1
}

should_skip_staged_diagnostic() {
    _diagnostic=$1
    _stderr=$2
    [ -n "$_diagnostic" ] || return 1
    grep -qF "$_diagnostic" "$_stderr"
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
            requires-stage0-symbol:*) continue ;;
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
    _objs=

    for _dep in $(deps_or_empty "$_deps"); do
        case "$_dep" in
            requires-stage0-symbol:*) continue ;;
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
                _objs="${_objs:+$_objs }$(cygpath -aw "$_obj")"
                ;;
        esac
    done

    printf '%s\n' "$_objs"
}

# Integration cases that are not Windows-applicable in this manifest
# (kept covered on Linux via native-linux.manifest):
#   arena_poison_*            Linux-only poison-on-reclaim debug mode
#   c_abi_sysv_*              Linux System V C ABI fixtures
windows_integration_non_applicable_cases() {
    cat <<'EOF'
arena_poison_clone_survives
arena_poison_stale_array_trap
c_abi_sysv_register_aggregate_args
c_abi_sysv_memory_aggregate
c_abi_sysv_tag_only_enum
c_abi_sysv_two_register_return
EOF
}

# Integration cases that are Windows-only in this manifest
# (kept covered on Windows via native-windows.manifest):
#   c_abi_win64_sret_return  Win64 hidden-sret aggregate return ABI
#   c_abi_win64_enum_*       Win64 enum aggregate C ABI fixtures
#   c_abi_win64_small_*      Win64 small aggregate register ABI
#   c_abi_win64_nested_*     Win64 nested aggregate C ABI fixtures
linux_integration_non_applicable_cases() {
    cat <<'EOF'
c_abi_win64_sret_return
c_abi_win64_aggregate_args
c_abi_win64_enum_aggregate
c_abi_win64_small_aggregate_float_mixed
c_abi_win64_nested_aggregate
EOF
}

# Cases covered by the selfhost-native generated-program gate rather than the
# seed-backed integration manifests.
# Immutable-reference native smoke fixtures are covered by
# verify-native-link-linux.sh until the published stage0 includes #1720.
selfhost_native_manifest_cases() {
    cat <<'EOF'
ref_fixed_array_return
ref_param_identity
ref_return
ref_tuple_return
EOF
}

validate_manifest() {
    _cases="$WORKDIR/manifest-cases.txt"
    _known="$WORKDIR/manifest-known.txt"
    _known_sorted="$WORKDIR/manifest-known.sorted"
    _dupes="$WORKDIR/manifest-dupes.txt"
    _actual="$WORKDIR/integration-sources.txt"
    _line_no=0
    : > "$_cases"
    : > "$_known"

    while IFS= read -r _line || [ -n "$_line" ]; do
        _line_no=$((_line_no + 1))
        case "$_line" in
            "" | \#*) continue ;;
        esac

        _fields=$(printf '%s\n' "$_line" | awk -F'|' '{ print NF }')
        if [ "$_fields" -ne 6 ] && [ "$_fields" -ne 7 ]; then
            echo "manifest line $_line_no must have 6 fields, or 7 with an extra field: $_line" >&2
            exit 1
        fi

        IFS='|' read -r _name _source _want _stdout_spec _runtime_args _deps _extra <<EOF
$_line
EOF

        case "$_name" in
            "" | *[!A-Za-z0-9_]*)
                echo "manifest line $_line_no has invalid case name: $_name" >&2
                exit 1
                ;;
        esac
        case "$_source" in
            "" | /* | *..* | *.tl) ;;
            *)
                echo "manifest line $_line_no has invalid source path: $_source" >&2
                exit 1
                ;;
        esac
        case "$_source" in
            "" | /* | *..*)
                echo "manifest line $_line_no has unsafe source path: $_source" >&2
                exit 1
                ;;
        esac
        case "$_want" in
            "" | *[!0-9]*)
                echo "manifest line $_line_no has invalid exit code for $_name: $_want" >&2
                exit 1
                ;;
        esac
        case "${_extra:-}" in
            "" | requires-stage0-symbol:?* | requires-stage0-diagnostic:?* | expected-stderr:?*) ;;
            requires-stage0-symbol:)
                echo "manifest line $_line_no has empty staged symbol for $_name" >&2
                exit 1
                ;;
            requires-stage0-diagnostic:)
                echo "manifest line $_line_no has empty staged diagnostic for $_name" >&2
                exit 1
                ;;
            expected-stderr:)
                echo "manifest line $_line_no has empty expected stderr for $_name" >&2
                exit 1
                ;;
            *)
                echo "manifest line $_line_no has invalid extra field for $_name: $_extra" >&2
                exit 1
                ;;
        esac

        _source_path="$ROOT/$_source"
        if [ ! -f "$_source_path" ]; then
            echo "manifest line $_line_no names missing source: $_source" >&2
            exit 1
        fi

        printf '%s\n' "$_name" >> "$_cases"
        case "$_source" in
            tests/integration/*.tl)
                basename "$_source" .tl >> "$_known"
                ;;
        esac

        _source_dir=$(dirname -- "$_source_path")
        for _dep in $(deps_or_empty "$_deps"); do
            case "$_dep" in
                requires-stage0-symbol:)
                    echo "manifest line $_line_no has empty staged symbol for $_name" >&2
                    exit 1
                    ;;
                requires-stage0-symbol:*) continue ;;
            esac
            case "$_dep" in
                /* | *..*)
                    echo "manifest line $_line_no has unsafe dependency path: $_dep" >&2
                    exit 1
                    ;;
            esac
            _dep_src=$(dep_source_path "$_dep" "$_source_dir")
            case "$_dep_src" in
                "$ROOT"/tests/integration/*.tl)
                    basename "$_dep_src" .tl >> "$_known"
                    ;;
            esac
        done
    done < "$NORMALIZED_MANIFEST"

    sort "$_cases" | uniq -d > "$_dupes"
    if [ -s "$_dupes" ]; then
        echo "manifest has duplicate integration case(s):" >&2
        sed 's/^/  /' "$_dupes" >&2
        exit 1
    fi

    if [ "$HOST_OS" = windows ]; then
        windows_integration_non_applicable_cases >> "$_known"
    fi
    if [ "$HOST_OS" = linux ]; then
        linux_integration_non_applicable_cases >> "$_known"
    fi
    selfhost_native_manifest_cases >> "$_known"

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

run_windows_program() {
    _exe=$(cygpath -aw "$1")
    _stdout=$(cygpath -aw "$2")
    _stderr=$(cygpath -aw "$3")
    _code_posix=$4
    _code=$(cygpath -aw "$4")
    _expected_code=$5
    shift 5

    # Retry only a transient #1204 crash exit (132/134/139), but stop
    # immediately when a crash-shaped exit is the case's expected result.
    _rwp_attempt=0
    while :; do
        _rwp_attempt=$((_rwp_attempt + 1))
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS_RUNNER_WIN" \
            "$_exe" "$_stdout" "$_stderr" "$_code" "$@"
        got=$(tr -d '\r\n' < "$_code_posix")
        if [ "$_expected_code" != "-" ] && [ "$got" = "$_expected_code" ]; then
            break
        fi
        if is_crash_code "$got" && [ "$_rwp_attempt" -lt "$INTEGRATION_ATTEMPTS" ]; then
            echo "  retry ($_rwp_attempt/$INTEGRATION_ATTEMPTS): '$_exe' crash exit $got — likely transient (#1204)" >&2
        else
            break
        fi
    done
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
    assert_contains "$_asm" "    js " "$_label"
    assert_contains "$_asm" "    movq %rax, %r11" "$_label"
    assert_contains "$_asm" "    orq %r11, %rax" "$_label"
    assert_contains "$_asm" "    addsd %xmm0, %xmm0" "$_label"
    assert_contains "$_asm" "    addss %xmm0, %xmm0" "$_label"
    assert_contains "$_asm" "    movzbq" "$_label"
    if ! awk '
        /u8_to_f64/ { in_u8 = 1 }
        in_u8 && /ret/ { exit bad }
        in_u8 && (/cast_u64_float_/ || /addsd %xmm0, %xmm0/ || /testq %rax, %rax/) { bad = 1 }
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

build_linux_fixture_driver() {
    _label=$1
    _source=$2
    _bin=$3
    _asm="$_bin.s"
    _obj="$_bin.o"
    _build_stdout="$_bin.build.stdout"
    _build_stderr="$_bin.build.stderr"

    build_with_retry "$COMPILER" compile "$_source" -o "$_asm" > "$_build_stdout" 2> "$_build_stderr"
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

run_linux_backend_fixtures() {
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
        "subq \$16, %rsp" \
        "movq %r11, 0(%rsp)" \
        "movsd %xmm15, 0(%rsp)" \
        "movsd %xmm15, 8(%rsp)" \
        "addq \$16, %rsp" \
        "call _tl_add8" \
        "call _tl_f10check" \
        "call _tl_mixcheck"
    do
        assert_contains "$_stack_asm" "$_snippet" backend-stack-args
    done
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
        "tl_alloc:" \
        "movq (%r10), %rax"
    do
        assert_contains "$_raw_ptr_asm" "$_snippet" backend-raw-pointer
    done
    assert_not_contains "$_raw_ptr_asm" "# TODO" backend-raw-pointer
    # This direct backend fixture bypasses the driver-owned runtime prelude.
    # Provide freestanding support for runtime calls this fixture can emit:
    # bounds-check abort, tl_alloc's out-of-memory tail-jump (tl_oom_abort,
    # #2221), and array initialization helpers.
    cat > "$_raw_ptr_abort_asm" <<'EOF'
    .text
    .globl tl_oob_abort
tl_oob_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_oom_abort
tl_oom_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_array_zero
tl_array_zero:
    testq %rsi, %rsi
    jle .L_tl_array_zero_done
.L_tl_array_zero_loop:
    movb $0, (%rdi)
    addq $1, %rdi
    subq $1, %rsi
    jg .L_tl_array_zero_loop
.L_tl_array_zero_done:
    ret

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

run_windows_backend_fixtures() {
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
        ".extern ExitProcess" \
        ".extern WriteFile" \
        "call VirtualAlloc" \
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
        ".L_tl_substring_copy_loop:" \
        ".L_tl_string_concat_copy_a:" \
        ".L_tl_string_concat_copy_b:" \
        "path_copy_loop:" \
        "path_copy_done:"
    do
        assert_not_contains "$_runtime_asm" "$_snippet" windows-backend-runtime
    done
    # The direct backend fixture does not lower TypeLisp runtime-prelude bodies.
    # Append freestanding link-only targets for tl_alloc's OOM path and the
    # moved string construction helpers; the happy path must not execute them.
    cat >> "$_runtime_asm" <<'EOF'
    .globl tl_oom_abort
tl_oom_abort:
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

validate_manifest

failed=0
ran=0
skipped=0

while IFS='|' read -r name source want stdout_spec runtime_args deps extra || [ -n "$name" ]; do
    case "$name" in
        "" | \#*) continue ;;
    esac

    requires_symbol=
    requires_diagnostic=
    expected_stderr_spec=-
    case "${extra:-}" in
        "") ;;
        requires-stage0-symbol:*) requires_symbol=${extra#requires-stage0-symbol:} ;;
        requires-stage0-diagnostic:*) requires_diagnostic=${extra#requires-stage0-diagnostic:} ;;
        expected-stderr:*) expected_stderr_spec=${extra#expected-stderr:} ;;
    esac

    source_path="$ROOT/$source"
    source_dir=$(dirname -- "$source_path")
    case_dir="$WORKDIR/$name"
    mkdir -p "$case_dir"
    work_src="$case_dir/$name.tl"
    cp "$source_path" "$work_src"

    if [ -z "$requires_symbol" ]; then
        requires_symbol=$(requires_symbol_from_deps "$deps")
    fi

    for dep in $(deps_or_empty "$deps"); do
        case "$dep" in
            requires-stage0-symbol:*) continue ;;
        esac
        copy_dep "$dep" "$source_dir" "$case_dir"
    done

    asm="$case_dir/$name.s"
    obj="$case_dir/$name.o"
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
        # emit Windows asm then assemble (clang) + link (lld-link), mirroring the
        # Linux compile->as->ld path below.
        build_with_retry "$COMPILER" compile "$work_src" --target windows-x86_64 --cfg windows -o "$asm" \
            > "$build_stdout" 2> "$build_stderr"
        if [ "$build_rc" -ne 0 ]; then
            if should_skip_staged "$requires_symbol" "$build_stderr"; then
                echo "[integration] SKIP $name (awaiting stage0 compiler support for '$requires_symbol')"
                skipped=$((skipped + 1))
                ran=$((ran + 1))
                continue
            fi
            if should_skip_staged_diagnostic "$requires_diagnostic" "$build_stderr"; then
                echo "[integration] SKIP $name (awaiting stage0 compiler support for diagnostic '$requires_diagnostic')"
                skipped=$((skipped + 1))
                ran=$((ran + 1))
                continue
            fi
            echo "FAIL: $name compile failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if ! clang --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" \
            >> "$build_stdout" 2>> "$build_stderr"; then
            echo "FAIL: $name assemble failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if ! native_objs=$(compile_windows_c_deps "$deps" "$case_dir" "$build_stdout" "$build_stderr"); then
            echo "FAIL: $name C dependency compile failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        # shellcheck disable=SC2086
        if ! lld-link -NOLOGO "$(cygpath -aw "$obj")" $native_objs "-OUT:$(cygpath -aw "$bin.exe")" \
            -SUBSYSTEM:CONSOLE -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib \
            >> "$build_stdout" 2>> "$build_stderr"; then
            if should_skip_staged "$requires_symbol" "$build_stderr"; then
                echo "[integration] SKIP $name (awaiting stage0 compiler support for '$requires_symbol')"
                skipped=$((skipped + 1))
                ran=$((ran + 1))
                continue
            fi
            echo "FAIL: $name link failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        set +e
        # shellcheck disable=SC2086
        run_windows_program "$bin.exe" "$stdout" "$stderr" "$code_file" "$want" $(deps_or_empty "$runtime_args")
        run_status=$?
        set -e
        if [ "$run_status" -ne 0 ]; then
            echo "FAIL: $name run wrapper failed" >&2
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
    else
        build_with_retry "$COMPILER" compile "$work_src" -o "$asm" > "$build_stdout" 2> "$build_stderr"
        if [ "$build_rc" -ne 0 ]; then
            if should_skip_staged "$requires_symbol" "$build_stderr"; then
                echo "[integration] SKIP $name (awaiting stage0 compiler support for '$requires_symbol')"
                skipped=$((skipped + 1))
                ran=$((ran + 1))
                continue
            fi
            if should_skip_staged_diagnostic "$requires_diagnostic" "$build_stderr"; then
                echo "[integration] SKIP $name (awaiting stage0 compiler support for diagnostic '$requires_diagnostic')"
                skipped=$((skipped + 1))
                ran=$((ran + 1))
                continue
            fi
            echo "FAIL: $name compile failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if ! as "$asm" -o "$obj" >> "$build_stdout" 2>> "$build_stderr"; then
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
        if ! ld "$obj" $native_objs -o "$bin" $link_extra -e "$(linux_entry_symbol_for_asm "$asm")" \
            >> "$build_stdout" 2>> "$build_stderr"; then
            if should_skip_staged "$requires_symbol" "$build_stderr"; then
                echo "[integration] SKIP $name (awaiting stage0 compiler support for '$requires_symbol')"
                skipped=$((skipped + 1))
                ran=$((ran + 1))
                continue
            fi
            echo "FAIL: $name link failed" >&2
            show_build_streams "$build_stdout" "$build_stderr"
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi

        set +e
        (
            # Keep parent-shell crash notices (for example dash's
            # "Segmentation fault (core dumped)") out of the program stderr
            # comparison; the manifest still checks the actual signal exit code.
            # shellcheck disable=SC2086
            "$bin" $(deps_or_empty "$runtime_args") > "$stdout" 2> "$stderr"
        ) 2> "$run_shell_stderr"
        got=$?
        set -e
    fi

    if [ "$name" = u64_float_casts ]; then
        check_u64_float_cast_asm "$asm"
    fi
    case "$name" in
        stdlib_string | string_eq) check_stdlib_string_helpers_asm "$asm" "$name" ;;
    esac

    if [ -n "$requires_symbol" ]; then
        echo "[integration] NOTE: $name built with the current compiler; once the stage0 compiler path provides '$requires_symbol', drop the requires-stage0-symbol marker" >&2
    fi
    if [ -n "$requires_diagnostic" ]; then
        echo "[integration] NOTE: $name built with the current compiler; once the stage0 compiler path accepts this source, drop the requires-stage0-diagnostic marker" >&2
    fi

    write_expected_stream "$stdout_spec" "$expected_stdout"
    write_expected_stream "$expected_stderr_spec" "$expected_stderr"
    normalized_stream "$expected_stdout" "$expected_stdout_cmp"
    normalized_stream "$expected_stderr" "$expected_stderr_cmp"
    normalized_stream "$stdout" "$stdout_cmp"
    normalized_stream "$stderr" "$stderr_cmp"

    case_failed=0
    if [ "$got" -ne "$want" ]; then
        echo "FAIL: $name expected exit $want, got $got" >&2
        case_failed=1
    fi
    if ! cmp -s "$expected_stdout_cmp" "$stdout_cmp"; then
        echo "FAIL: $name stdout mismatch" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$expected_stdout_cmp" "$stdout_cmp" >&2 || true
        fi
        case_failed=1
    fi
    if ! cmp -s "$expected_stderr_cmp" "$stderr_cmp"; then
        echo "FAIL: $name stderr mismatch" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$expected_stderr_cmp" "$stderr_cmp" >&2 || true
        fi
        case_failed=1
    fi
    if [ "$case_failed" -ne 0 ] && [ -s "$run_shell_stderr" ]; then
        echo "NOTE: $name shell run diagnostics:" >&2
        sed 's/^/  /' "$run_shell_stderr" >&2
    fi

    if [ "$case_failed" -eq 0 ]; then
        echo "PASS: $name"
    else
        failed=$((failed + 1))
    fi
    ran=$((ran + 1))
done < "$NORMALIZED_MANIFEST"

if [ "$failed" -gt 0 ]; then
    echo "$failed integration case(s) failed out of $ran" >&2
    exit 1
fi

if [ "$HOST_OS" = linux ]; then
    run_linux_backend_fixtures
else
    run_windows_backend_fixtures
fi

echo "All $ran integration case(s) passed for $HOST_OS ($skipped staged case(s) skipped)."
