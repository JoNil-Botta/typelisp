#!/usr/bin/env sh
set -eu

# verify-integration.sh - manifest-driven native integration runner.
#
# The runner builds each listed TypeLisp program to a native executable, runs it
# outside the Rust test harness, and checks exit code, stdout, and stderr. Linux
# uses the explicit compile -> as -> ld flow; Windows Git Bash/MSYS/Cygwin uses
# typelisp build --target windows-x86_64 and PowerShell only to preserve native
# Windows process exit codes larger than 255.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

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
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
    [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

# Retry transient Windows crashes (#1204): the typelisp build and the
# native/selfhost programs run on Windows intermittently SEGFAULT with no useful
# output. `is_crash_code` (132/134/139) lets us retry ONLY those transient
# crashes, never a genuine non-zero exit (so an expected failure still fails).
. "$ROOT/scripts/lib-retry.sh"
# Default 6 (not 3): large corpus binaries like compiler_lower_smoke hit the
# #1204 Windows segfault at a high enough rate that 3 attempts can all crash
# (observed 3/3 on PR #1225), so the crash-only retry needs more headroom.
INTEGRATION_ATTEMPTS="${VERIFY_INTEGRATION_ATTEMPTS:-6}"

# Run a `typelisp build`/`compile` invocation, retrying a transient #1204 crash.
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
            echo "  retry ($_bwr_attempt/$INTEGRATION_ATTEMPTS): build crash exit $build_rc — likely transient (#1204)" >&2
        else
            break
        fi
    done
}

# Run a `$COMPILER run <fixture.tl> …` emit step, retrying ONLY a transient
# #1204 crash (these fixtures emit assembly deterministically, so a retry safely
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

dep_source_path() {
    _dep=$1
    _source_dir=$2

    case "$_dep" in
        stdlib/*)
            printf '%s\n' "$ROOT/$_dep"
            return
            ;;
        sym_i64_env_core.tl)
            printf '%s\n' "$ROOT/selfhost/sym_i64_env.tl"
            return
            ;;
        text_buf_core.tl)
            printf '%s\n' "$ROOT/selfhost/text_buf.tl"
            return
            ;;
    esac

    if [ -f "$_source_dir/$_dep" ]; then
        printf '%s\n' "$_source_dir/$_dep"
    elif [ -f "$ROOT/selfhost/$_dep" ]; then
        printf '%s\n' "$ROOT/selfhost/$_dep"
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
    _dst="$_case_dir/$_dep"
    mkdir -p "$(dirname -- "$_dst")"
    cp "$_src" "$_dst"
}

windows_integration_skips() {
    cat <<'EOF'
with_arena_builtin_alloc
with_arena_loop
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
        if [ "$_fields" -ne 6 ]; then
            echo "manifest line $_line_no must have 6 fields: $_line" >&2
            exit 1
        fi

        IFS='|' read -r _name _source _want _stdout_spec _runtime_args _deps <<EOF
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
        windows_integration_skips >> "$_known"
    fi

    find tests/integration -maxdepth 1 -type f -name '*.tl' |
        sed 's#^tests/integration/##; s#\.tl$##' | sort > "$_actual"
    sort -u "$_known" > "$_known_sorted"
    if ! cmp -s "$_actual" "$_known_sorted"; then
        echo "integration manifest is out of date for $HOST_OS" >&2
        echo "every tests/integration/*.tl file must be a manifest case, dependency, or documented host skip" >&2
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
    shift 4

    # Retry only a transient #1204 crash exit (132/134/139); a genuine
    # crash-expecting case re-runs harmlessly and still returns the same code.
    _rwp_attempt=0
    while :; do
        _rwp_attempt=$((_rwp_attempt + 1))
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS_RUNNER_WIN" \
            "$_exe" "$_stdout" "$_stderr" "$_code" "$@"
        got=$(tr -d '\r\n' < "$_code_posix")
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

run_linux_backend_fixtures() {
    _runtime_dir="$WORKDIR/backend-runtime"
    mkdir -p "$_runtime_dir"
    _runtime_asm="$_runtime_dir/runtime_helpers.s"
    _runtime_obj="$_runtime_dir/runtime_helpers.o"
    _runtime_bin="$_runtime_dir/runtime_helpers"

    echo "[backend-runtime] emit -> assemble -> link -> run"
    run_fixture_with_retry "$COMPILER" run selfhost/compiler_backend_runtime_fixture.tl -- "$_runtime_asm"
    for _snippet in \
        ".globl tl_alloc" \
        "tl_alloc:" \
        ".globl tl_oob_abort" \
        "tl_oob_abort:" \
        ".globl tl_substring" \
        "tl_substring:" \
        ".globl tl_string_concat" \
        "tl_string_concat:" \
        ".L_tl_read_stdin_line:" \
        ".L_tl_read_stdin_bytes:" \
        ".L_tl_stdin_eof:" \
        ".L_tl_flush_stdout:" \
        "tl: stdin failed" \
        ".L_tl_substring_copy_loop:" \
        ".L_tl_string_concat_copy_b:" \
        "tl_current_arena:" \
        ".L_tl_alloc_new_arena:" \
        "call tl_alloc"
    do
        assert_contains "$_runtime_asm" "$_snippet" backend-runtime
    done
    for _snippet in \
        ".extern tl_alloc" \
        ".extern tl_oob_abort" \
        ".extern tl_substring" \
        ".extern tl_string_concat" \
        ".extern .L_tl_read_stdin_line" \
        ".extern .L_tl_read_stdin_bytes" \
        ".extern .L_tl_stdin_eof" \
        ".extern .L_tl_flush_stdout"
    do
        assert_not_contains "$_runtime_asm" "$_snippet" backend-runtime
    done
    as "$_runtime_asm" -o "$_runtime_obj"
    ld "$_runtime_obj" -o "$_runtime_bin"
    set +e
    "$_runtime_bin" > "$_runtime_dir/runtime.stdout" 2> "$_runtime_dir/runtime.stderr"
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

    echo "[backend-stack-args] emit -> assemble -> link -> run"
    run_fixture_with_retry "$COMPILER" run selfhost/compiler_backend_stack_args_fixture.tl -- "$_stack_asm" linux-x86_64
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
    ld "$_stack_obj" -o "$_stack_bin"
    set +e
    "$_stack_bin" > "$_stack_dir/stack.stdout" 2> "$_stack_dir/stack.stderr"
    _got=$?
    set -e
    if [ "$_got" -ne 96 ] || [ -s "$_stack_dir/stack.stdout" ] || [ -s "$_stack_dir/stack.stderr" ]; then
        echo "FAIL: backend stack-args fixture expected exit 96 with no output, got $_got" >&2
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
        msvcrt.lib legacy_stdio_definitions.lib || {
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
    run_fixture_with_retry "$COMPILER" run selfhost/compiler_backend_runtime_fixture.tl \
        --target windows-x86_64 -- "$_runtime_asm" windows-x86_64
    for _snippet in \
        ".globl main" \
        ".globl tl_alloc" \
        "tl_alloc:" \
        ".globl tl_oob_abort" \
        "tl_oob_abort:" \
        ".globl tl_substring" \
        "tl_substring:" \
        ".globl tl_string_concat" \
        "tl_string_concat:" \
        ".globl tl_string_eq" \
        "tl_string_eq:" \
        ".globl tl_string_to_int" \
        "tl_string_to_int:" \
        ".globl tl_int_to_string" \
        "tl_int_to_string:" \
        ".globl tl_print_err" \
        "tl_print_err:" \
        ".L_tl_arg_count:" \
        ".L_tl_arg:" \
        ".L_tl_read_file:" \
        ".L_tl_write_file:" \
        ".L_tl_file_exists:" \
        ".L_tl_abort:" \
        ".L_tl_read_stdin_line:" \
        ".L_tl_read_stdin_bytes:" \
        ".L_tl_stdin_eof:" \
        ".L_tl_flush_stdout:" \
        ".L_tl_argc:" \
        ".L_tl_argv:" \
        "movq %rcx, .L_tl_argc(%rip)" \
        "movq %rdx, .L_tl_argv(%rip)" \
        ".extern malloc" \
        ".extern _write" \
        ".extern exit" \
        ".extern _read" \
        ".extern fflush" \
        ".extern _open" \
        ".extern _lseeki64" \
        ".extern _close" \
        ".extern _access" \
        "call malloc" \
        "call _write" \
        "call _read" \
        "call fflush" \
        "call _open" \
        "call _lseeki64" \
        "call _close" \
        "call _access" \
        "call .L_tl_abort" \
        "movq \$0x8000, %rdx" \
        "movq \$0x8301, %rdx" \
        "movq \$0x180, %r8" \
        "movq %rcx, %rbx" \
        "movq %r12, %rcx" \
        "movq %rcx, %r10"
    do
        assert_contains "$_runtime_asm" "$_snippet" windows-backend-runtime
    done
    for _snippet in \
        "syscall" \
        "_start:" \
        "tl_current_arena:" \
        ".extern tl_alloc" \
        ".extern tl_oob_abort" \
        ".extern tl_substring" \
        ".extern tl_string_concat" \
        ".extern tl_string_eq" \
        ".extern tl_string_to_int" \
        ".extern tl_int_to_string" \
        ".extern tl_print_err" \
        ".extern .L_tl_arg_count" \
        ".extern .L_tl_arg" \
        ".extern .L_tl_read_file" \
        ".extern .L_tl_write_file" \
        ".extern .L_tl_file_exists" \
        ".extern .L_tl_abort" \
        ".extern .L_tl_read_stdin_line" \
        ".extern .L_tl_read_stdin_bytes" \
        ".extern .L_tl_stdin_eof" \
        ".extern .L_tl_flush_stdout"
    do
        assert_not_contains "$_runtime_asm" "$_snippet" windows-backend-runtime
    done
    assemble_link_windows "$_runtime_asm" "$_runtime_obj" "$_runtime_bin" windows-backend-runtime
    run_windows_program "$_runtime_bin" "$_runtime_stdout" "$_runtime_stderr" "$_runtime_code"
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
    build_with_retry "$COMPILER" build selfhost/compile.tl -o "$_driver_bin" --target windows-x86_64
    if [ "$build_rc" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver build failed (exit $build_rc)" >&2
        exit 1
    fi
    printf '%s\n' '(define (main) : i64 42)' > "$_driver_source"
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" \
        "$(cygpath -aw "$_driver_source")" -o "$(cygpath -aw "$_driver_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver default target got exit $got" >&2
        exit 1
    fi
    assert_empty_file "$_driver_stdout" windows-selfhost-compile-driver-stdout
    assert_empty_file "$_driver_stderr" windows-selfhost-compile-driver-stderr
    assert_contains "$_driver_asm" ".globl main" windows-selfhost-compile-driver
    assert_contains "$_driver_asm" "main:" windows-selfhost-compile-driver
    assert_contains "$_driver_asm" ".globl _start" windows-selfhost-compile-driver

    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" \
        "$(cygpath -aw "$_driver_source")" --target linux-x86_64 -o "$(cygpath -aw "$_driver_linux_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver explicit Linux target got exit $got" >&2
        exit 1
    fi
    assert_empty_file "$_driver_stdout" windows-selfhost-compile-driver-linux-stdout
    assert_empty_file "$_driver_stderr" windows-selfhost-compile-driver-linux-stderr
    if ! cmp -s "$_driver_asm" "$_driver_linux_asm"; then
        echo "FAIL: explicit Linux target should match default selfhost compile output" >&2
        exit 1
    fi

    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" \
        "$(cygpath -aw "$_driver_source")" --target windows-x86_64 -o "$(cygpath -aw "$_driver_windows_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver Windows target got exit $got" >&2
        exit 1
    fi
    assert_empty_file "$_driver_stdout" windows-selfhost-compile-driver-windows-stdout
    assert_empty_file "$_driver_stderr" windows-selfhost-compile-driver-windows-stderr
    assert_contains "$_driver_windows_asm" ".globl main" windows-selfhost-compile-driver-windows
    assert_not_contains "$_driver_windows_asm" ".globl _start" windows-selfhost-compile-driver-windows

    _bad_target_asm="$_driver_dir/bad-target.s"
    rm -f "$_bad_target_asm"
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" \
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
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" \
        "$(cygpath -aw "$_comptime_source")" -o "$(cygpath -aw "$_comptime_asm")"
    if [ "$got" -ne 0 ]; then
        echo "FAIL: windows-selfhost-compile-driver comptime type source got exit $got" >&2
        exit 1
    fi
    assert_contains "$_comptime_asm" "__tl_specialized_alloc_type_i64_none" \
        windows-selfhost-compile-driver-comptime

    _bad_source="$_driver_dir/bad.tl"
    _bad_asm="$_driver_dir/bad.s"
    printf '%s\n' '(define (main) : i64 true)' > "$_bad_source"
    rm -f "$_bad_asm"
    run_windows_program "$_driver_bin" "$_driver_stdout" "$_driver_stderr" "$_driver_code" \
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

    _primitive_dir="$WORKDIR/windows-driver-primitives"
    mkdir -p "$_primitive_dir"
    _primitive_asm="$_primitive_dir/driver_primitives.s"
    _primitive_obj="$_primitive_dir/driver_primitives.obj"
    _primitive_bin="$_primitive_dir/driver_primitives.exe"
    _primitive_input="$_primitive_dir/input.txt"
    _primitive_output="$_primitive_dir/output.txt"
    _primitive_stdout="$_primitive_dir/driver.stdout"
    _primitive_stderr="$_primitive_dir/driver.stderr"
    _primitive_code="$_primitive_dir/driver.exit"
    printf '%s' 41 > "$_primitive_input"
    rm -f "$_primitive_output"

    echo "[windows-driver-primitives] emit -> assemble -> link -> run"
    run_fixture_with_retry "$COMPILER" run selfhost/compiler_backend_runtime_fixture.tl \
        --target windows-x86_64 -- "$_primitive_asm" windows-driver-primitives
    for _snippet in \
        ".globl main" \
        ".L_tl_arg_count:" \
        ".L_tl_arg:" \
        ".L_tl_read_file:" \
        ".L_tl_write_file:" \
        ".L_tl_file_exists:" \
        "tl_print_err:" \
        "tl_string_eq:" \
        "tl_string_to_int:" \
        "tl_int_to_string:" \
        "movq %rcx, .L_tl_argc(%rip)" \
        "movq %rdx, .L_tl_argv(%rip)" \
        ".extern _open" \
        ".extern _lseeki64" \
        ".extern _close" \
        ".extern _access" \
        "call _open" \
        "call _lseeki64" \
        "call _read" \
        "call _write" \
        "call _close" \
        "call _access"
    do
        assert_contains "$_primitive_asm" "$_snippet" windows-driver-primitives
    done
    for _snippet in \
        "syscall" \
        "_start:" \
        ".extern .L_tl_arg_count" \
        ".extern .L_tl_arg" \
        ".extern .L_tl_read_file" \
        ".extern .L_tl_write_file" \
        ".extern .L_tl_file_exists" \
        ".extern tl_print_err" \
        ".extern tl_string_eq" \
        ".extern tl_string_to_int" \
        ".extern tl_int_to_string"
    do
        assert_not_contains "$_primitive_asm" "$_snippet" windows-driver-primitives
    done
    assemble_link_windows "$_primitive_asm" "$_primitive_obj" "$_primitive_bin" windows-driver-primitives
    run_windows_program "$_primitive_bin" "$_primitive_stdout" "$_primitive_stderr" "$_primitive_code" \
        "$(cygpath -aw "$_primitive_input")" "$(cygpath -aw "$_primitive_output")"
    if [ "$got" -ne 42 ]; then
        echo "FAIL: windows-driver-primitives expected exit 42, got $got" >&2
        exit 1
    fi
    assert_empty_file "$_primitive_stdout" windows-driver-primitives-stdout
    assert_file_text "$_primitive_stderr" ok windows-driver-primitives-stderr
    assert_file_text "$_primitive_output" 42 windows-driver-primitives-output

    echo "Windows backend fixture checks passed."
}

validate_manifest

failed=0
ran=0

while IFS='|' read -r name source want stdout_spec runtime_args deps || [ -n "$name" ]; do
    case "$name" in
        "" | \#*) continue ;;
    esac

    source_path="$ROOT/$source"
    source_dir=$(dirname -- "$source_path")
    case_dir="$WORKDIR/$name"
    mkdir -p "$case_dir"
    work_src="$case_dir/$name.tl"
    cp "$source_path" "$work_src"

    for dep in $(deps_or_empty "$deps"); do
        copy_dep "$dep" "$source_dir" "$case_dir"
    done

    asm="$case_dir/$name.s"
    obj="$case_dir/$name.o"
    bin="$case_dir/$name"
    stdout="$case_dir/$name.stdout"
    stderr="$case_dir/$name.stderr"
    expected_stdout_cmp="$case_dir/$name.expected.stdout.cmp"
    stdout_cmp="$case_dir/$name.stdout.cmp"
    stderr_cmp="$case_dir/$name.stderr.cmp"
    expected_stdout="$case_dir/$name.expected.stdout"
    code_file="$case_dir/$name.exit"

    echo "[$name] build -> run ($HOST_OS)"
    if [ "$HOST_OS" = windows ]; then
        build_with_retry "$COMPILER" build "$work_src" -o "$bin.exe" --target windows-x86_64
        if [ "$build_rc" -ne 0 ]; then
            echo "FAIL: $name build failed" >&2
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        set +e
        # shellcheck disable=SC2086
        run_windows_program "$bin.exe" "$stdout" "$stderr" "$code_file" $(deps_or_empty "$runtime_args")
        run_status=$?
        set -e
        if [ "$run_status" -ne 0 ]; then
            echo "FAIL: $name run wrapper failed" >&2
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
    else
        if ! "$COMPILER" compile "$work_src" -o "$asm"; then
            echo "FAIL: $name compile failed" >&2
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if ! as "$asm" -o "$obj"; then
            echo "FAIL: $name assemble failed" >&2
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi
        if ! ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc; then
            echo "FAIL: $name link failed" >&2
            failed=$((failed + 1))
            ran=$((ran + 1))
            continue
        fi

        set +e
        # shellcheck disable=SC2086
        "$bin" $(deps_or_empty "$runtime_args") > "$stdout" 2> "$stderr"
        got=$?
        set -e
    fi

    write_expected_stream "$stdout_spec" "$expected_stdout"
    normalized_stream "$expected_stdout" "$expected_stdout_cmp"
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
    if [ -s "$stderr_cmp" ]; then
        echo "FAIL: $name wrote stderr" >&2
        sed 's/^/  /' "$stderr_cmp" >&2
        case_failed=1
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

echo "All $ran integration case(s) passed for $HOST_OS."
