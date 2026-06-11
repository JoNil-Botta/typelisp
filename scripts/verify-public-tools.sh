#!/usr/bin/env sh
set -eu

# verify-public-tools.sh - exercise public CLI/tool behavior without Rust tests.
# This is intentionally driven by a built TypeLisp executable via TYPELISP_BIN.
# refs #845

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Retry transient Windows crashes (#1204): `is_crash_code` lets the run_* helpers
# retry only a segfault-class exit (132/134/139), since public-tool cases may
# legitimately exit non-zero (so retry-on-any-non-zero would be wrong here).
. "$ROOT/scripts/lib-retry.sh"
. "$ROOT/scripts/lib-linux-entry.sh"
# Default 6 (not 3): this gate runs many CLI invocations, so the #1204 Windows
# segfault can exhaust 3 attempts on one of them (observed on PR #1249:
# inline-test-fail crashed 134/134/segfault); more headroom keeps the
# crash-only retry effective.
PUBLIC_TOOLS_ATTEMPTS="${VERIFY_PUBLIC_TOOLS_ATTEMPTS:-6}"

HOST_OS=linux
HOST_TARGET=linux-x86_64
case "$(uname -s)" in
    Linux*)
        HOST_OS=linux
        HOST_TARGET=linux-x86_64
        ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        HOST_TARGET=windows-x86_64
        ;;
    *)
        echo "public tool verification is unsupported on this host" >&2
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

# A relative TYPELISP_BIN (e.g. CI's `target/debug/typelisp`) breaks cases that
# change directory before invoking the compiler (run_cmd_cwd), so resolve it to
# an absolute path up front.
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

HOST_ACTION_ENABLED=1
HOST_EXE_SUFFIX=
HOST_STATIC_LIB_PREFIX=lib
HOST_STATIC_LIB_SUFFIX=.a
if [ "$HOST_OS" = windows ]; then
    HOST_EXE_SUFFIX=.exe
    HOST_STATIC_LIB_PREFIX=
    HOST_STATIC_LIB_SUFFIX=.lib
fi

WORKDIR="$ROOT/target/public-tool-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

maybe_strip_manifest_kind() {
    manifest=$1
    if [ "${TYPELISP_LEGACY_PACKAGE_MANIFEST:-}" = "1" ]; then
        sed -i.bak '/^[[:space:]]*(kind "bin")[[:space:]]*$/d' "$manifest"
        sed -i.bak '/^[[:space:]]*(kind "lib")[[:space:]]*$/d' "$manifest"
        rm -f "$manifest.bak"
    fi
}

run_cmd() {
    case_name=$1
    shift
    out="$WORKDIR/$case_name.out"
    err="$WORKDIR/$case_name.err"
    _rc_attempt=0
    while :; do
        _rc_attempt=$((_rc_attempt + 1))
        set +e
        TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@" 3>&2 > "$out" 2> "$err"
        code=$?
        set -e
        if is_crash_code "$code" && [ "$_rc_attempt" -lt "$PUBLIC_TOOLS_ATTEMPTS" ]; then
            echo "  retry ($_rc_attempt): '$case_name' crash exit $code — likely transient (#1204)" >&2
        else
            break
        fi
    done
}

run_cmd_cwd() {
    case_name=$1
    cwd=$2
    shift 2
    out="$WORKDIR/$case_name.out"
    err="$WORKDIR/$case_name.err"
    _rc_attempt=0
    while :; do
        _rc_attempt=$((_rc_attempt + 1))
        set +e
        (cd "$cwd" && TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@") 3>&2 > "$out" 2> "$err"
        code=$?
        set -e
        if is_crash_code "$code" && [ "$_rc_attempt" -lt "$PUBLIC_TOOLS_ATTEMPTS" ]; then
            echo "  retry ($_rc_attempt): '$case_name' crash exit $code — likely transient (#1204)" >&2
        else
            break
        fi
    done
}

run_stdin() {
    case_name=$1
    input_file=$2
    shift 2
    out="$WORKDIR/$case_name.out"
    err="$WORKDIR/$case_name.err"
    _rc_attempt=0
    while :; do
        _rc_attempt=$((_rc_attempt + 1))
        set +e
        TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@" 3>&2 < "$input_file" > "$out" 2> "$err"
        code=$?
        set -e
        if is_crash_code "$code" && [ "$_rc_attempt" -lt "$PUBLIC_TOOLS_ATTEMPTS" ]; then
            echo "  retry ($_rc_attempt): '$case_name' crash exit $code — likely transient (#1204)" >&2
        else
            break
        fi
    done
}

assert_code() {
    expected=$1
    if [ "$code" -ne "$expected" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$err" >&2 || true
        fail "$case_name expected exit $expected, got $code"
    fi
}

assert_success() {
    assert_code 0
}

assert_failure() {
    if [ "$code" -eq 0 ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$err" >&2 || true
        fail "$case_name unexpectedly succeeded"
    fi
}

assert_stdout_empty() {
    [ ! -s "$out" ] || fail "$case_name wrote unexpected stdout: $(cat "$out")"
}

assert_stderr_empty() {
    [ ! -s "$err" ] || fail "$case_name wrote unexpected stderr: $(cat "$err")"
}

assert_stderr_nonempty() {
    [ -s "$err" ] || fail "$case_name did not write stderr"
}

assert_contains() {
    file=$1
    text=$2
    if ! grep -F -- "$text" "$file" > /dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$case_name missing expected text: $text"
    fi
}

assert_contains_any() {
    file=$1
    shift
    for text in "$@"; do
        if grep -F -- "$text" "$file" > /dev/null; then
            return
        fi
    done
    echo "file contents:" >&2
    sed 's/^/  /' "$file" >&2 || true
    fail "$case_name missing any expected text: $*"
}

assert_not_contains() {
    file=$1
    text=$2
    if grep -F -- "$text" "$file" > /dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$case_name contained unexpected text: $text"
    fi
}

native_arg_path() {
    path=$1
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        printf '%s\n' "$path"
    fi
}

build_linux_cli_tool() {
    _case=$1
    _source=$2
    _output=$3
    _asm="$_output.s"
    _obj="$_output.o"

    run_cmd "$_case-compile" "$COMPILER" compile "$_source" --stdlib-root "$ROOT/stdlib" -o "$_asm"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Wrote "
    run_cmd "$_case-assemble" as "$_asm" -o "$_obj"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    run_cmd "$_case-link" ld "$_obj" -o "$_output" -static -e "$(linux_entry_symbol_for_asm "$_asm")"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
}

build_host_cli_tool() {
    _case=$1
    _source=$2
    _output=$3

    run_cmd "$_case-build" "$COMPILER" build "$_source" -o "$_output" --target "$HOST_TARGET"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Built $(native_arg_path "$_output")"
    [ -x "$_output" ] || fail "$_case did not write executable $_output"
}

strip_expected_trailing_lf() {
    src=$1
    dst=$2
    normalized="$WORKDIR/expected-normalized.tmp"
    tr -d '\r' < "$src" > "$normalized"
    size=$(wc -c < "$normalized" | tr -d ' ')
    if [ "$size" -gt 0 ]; then
        last=$(tail -c 1 "$normalized" | od -An -tx1 | tr -d ' \n')
        if [ "$last" = "0a" ]; then
            dd if="$normalized" of="$dst" bs=1 count=$((size - 1)) 2> /dev/null
            return
        fi
    fi
    cp "$normalized" "$dst"
}

check_file_exact() {
    actual=$1
    expected=$2
    if ! cmp -s "$actual" "$expected"; then
        echo "expected:" >&2
        sed 's/^/  /' "$expected" >&2 || true
        echo "actual:" >&2
        sed 's/^/  /' "$actual" >&2 || true
        fail "$case_name produced unexpected file content"
    fi
}

check_text_file_exact() {
    actual=$1
    expected=$2
    if [ "$HOST_OS" = windows ]; then
        actual_normalized="$WORKDIR/text-actual-normalized.tmp"
        expected_normalized="$WORKDIR/text-expected-normalized.tmp"
        tr -d '\r' < "$actual" > "$actual_normalized"
        tr -d '\r' < "$expected" > "$expected_normalized"
        check_file_exact "$actual_normalized" "$expected_normalized"
        rm -f "$actual_normalized" "$expected_normalized"
    else
        check_file_exact "$actual" "$expected"
    fi
}

assert_doctest_temp_cleaned() {
    source_path=$1
    temp_dir=$(dirname -- "$source_path")/.typelisp-doctest
    [ ! -d "$temp_dir" ] || fail "$case_name left temp directory behind: $temp_dir"
}

host_netstring() {
    value=$1
    bytes=$(printf '%s' "$value" | wc -c | tr -d ' ')
    printf '%s:%s' "$bytes" "$value"
}

host_plan_path() {
    path=$1
    if [ "$HOST_OS" = windows ] && command -v cygpath > /dev/null 2>&1; then
        cygpath -w "$path"
    else
        printf '%s' "$path"
    fi
}

echo "[public-tools] CLI usage and frontend aliases"
run_cmd usage "$COMPILER" --help
assert_success
assert_stdout_empty
if grep -q "stage1 wrapper commands" "$err"; then
    IS_STAGE1_WRAPPER=1
else
    IS_STAGE1_WRAPPER=0
fi
# The single-binary cli.tl stage0 shares the selfhost frontend with the stage1
# wrapper, so its typecheck diagnostics use the selfhost wording (no legacy
# `error[E0200]`/`got <a> -> <b>` annotations). Treat cli.tl (host-action
# disabled) like the wrapper for those diagnostic-text branches, while keeping
# legacy diagnostic expectations isolated to compatibility branches (#1327).
SELFHOST_FRONTEND_DIAGNOSTICS=1
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$err" "repl"
    assert_contains "$err" "fmt"
    assert_contains "$err" "doc"
else
    assert_contains "$err" "Synopsis:"
    assert_contains "$err" "Commands:"
    assert_contains "$err" "typelisp repl"
    assert_contains "$err" "typelisp lsp"
    assert_contains "$err" "typelisp fmt"
    assert_contains "$err" "typelisp doc"
    assert_contains "$err" "typelisp clean"
    assert_contains "$err" "Global Options:"
    assert_contains "$err" "Common Command Options:"
    assert_contains "$err" "Environment:"
    assert_contains "$err" "typelisp compile        Generate assembly or IR"
    assert_contains "$err" "--opt-level <0|1|2>            Select optimizer level"
    assert_contains "$err" 'Run `typelisp <command> --help` for command-specific usage.'
fi
USAGE_ERR=$err
if grep -q "Common Command Options:" "$USAGE_ERR"; then
    EXPECT_NORMALIZED_HELP=1
else
    EXPECT_NORMALIZED_HELP=0
fi
if grep -q "typelisp clean" "$USAGE_ERR"; then
    HAS_CLEAN_COMMAND=1
else
    HAS_CLEAN_COMMAND=0
fi
if grep -q "typelisp lsp" "$USAGE_ERR"; then
    HAS_LSP_COMMAND=1
else
    HAS_LSP_COMMAND=0
fi
if grep -q "typelisp lint" "$USAGE_ERR"; then
    HAS_LINT_COMMAND=1
else
    HAS_LINT_COMMAND=0
fi
if [ "$HAS_LSP_COMMAND" -eq 1 ]; then
    LSP_COMMAND_PROBE="$WORKDIR/lsp-command-probe.in"
    printf 'X-Test: 1\r\n\r\n' > "$LSP_COMMAND_PROBE"
    run_stdin lsp-command-probe "$LSP_COMMAND_PROBE" "$COMPILER" lsp
    if grep -F "not yet available" "$err" >/dev/null; then
        HAS_LSP_COMMAND=0
    fi
fi

assert_subcommand_help() {
    _case=$1
    _command=$2
    _flag=$3
    _usage=$4
    run_cmd "$_case" "$COMPILER" "$_command" "$_flag"
    assert_success
    assert_stdout_empty
    assert_contains "$err" "Usage:"
    assert_contains "$err" "$_usage"
    if [ "$EXPECT_NORMALIZED_HELP" -eq 1 ]; then
        assert_contains "$err" "Summary:"
    fi
}

assert_subcommand_help_pair() {
    _command=$1
    _usage=$2
    assert_subcommand_help "$_command-help" "$_command" --help "$_usage"
    assert_subcommand_help "$_command-short-help" "$_command" -h "$_usage"
}

assert_subcommand_help_pair build "typelisp build"
if [ "$EXPECT_NORMALIZED_HELP" -eq 1 ]; then
    assert_contains "$err" "--opt-level <0|1|2>            Package-build optimizer level"
    assert_contains "$err" "--locked"
    assert_contains "$err" "--update-lock"
fi
assert_subcommand_help_pair run "typelisp run"
assert_subcommand_help_pair check "typelisp check"
assert_subcommand_help_pair fmt "typelisp fmt"
if [ "$HAS_LINT_COMMAND" -eq 1 ]; then
    assert_subcommand_help_pair lint "typelisp lint"
fi
assert_subcommand_help_pair test "typelisp test"
assert_subcommand_help_pair doc "typelisp doc"
assert_subcommand_help_pair compile "typelisp compile"
if [ "$EXPECT_NORMALIZED_HELP" -eq 1 ]; then
    assert_contains "$err" "--emit-ir                      Emit intermediate representation"
fi
assert_subcommand_help_pair repl "typelisp repl"
if [ "$EXPECT_NORMALIZED_HELP" -eq 1 ]; then
    assert_contains "$err" "REPL Commands:"
fi
assert_subcommand_help_pair new "typelisp new"
assert_subcommand_help_pair init "typelisp init"
if [ "$HAS_CLEAN_COMMAND" -eq 1 ]; then
    assert_subcommand_help_pair clean "typelisp clean"
fi
if [ "$HAS_LSP_COMMAND" -eq 1 ]; then
    assert_subcommand_help_pair lsp "typelisp lsp"
fi

run_cmd missing-command "$COMPILER"
assert_failure
assert_stdout_empty
assert_contains_any "$err" "Usage:" "usage:"

run_cmd check-hello "$COMPILER" check examples/hello.tl
assert_success
assert_stderr_empty
assert_contains "$out" "Type checking passed!"

run_cmd compile-hello "$COMPILER" compile examples/hello.tl -o "$WORKDIR/hello.s"
assert_success
assert_stderr_empty
if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
    assert_contains "$out" "Wrote "
fi
assert_contains "$WORKDIR/hello.s" "main:"

if [ "$HAS_CLEAN_COMMAND" -eq 1 ]; then
echo "[public-tools] clean source artifacts"
CLEAN_SRC_DIR="$WORKDIR/clean-source"
mkdir -p "$CLEAN_SRC_DIR"
CLEAN_SRC="$CLEAN_SRC_DIR/main.tl"
CLEAN_BASE="$CLEAN_SRC_DIR/main"
cat > "$CLEAN_SRC" <<'EOF'
(define (main) : i64 0)
EOF
: > "$CLEAN_BASE.s"
: > "$CLEAN_BASE.ir"
: > "$CLEAN_BASE.o"
: > "$CLEAN_BASE.obj"
: > "$CLEAN_BASE"
: > "$CLEAN_BASE.exe"
run_cmd clean-source-dry-run "$COMPILER" clean --dry-run "$CLEAN_SRC"
assert_success
assert_stderr_empty
assert_contains "$out" "Would remove:"
assert_contains "$out" "main.s"
[ -f "$CLEAN_SRC" ] || fail "clean dry-run removed source file"
[ -f "$CLEAN_BASE.s" ] || fail "clean dry-run removed assembly"
[ -f "$CLEAN_BASE" ] || fail "clean dry-run removed executable"
run_cmd clean-source "$COMPILER" clean "$CLEAN_SRC"
assert_success
assert_stderr_empty
assert_contains "$out" "Removed:"
[ -f "$CLEAN_SRC" ] || fail "clean removed source file"
[ ! -e "$CLEAN_BASE.s" ] || fail "clean did not remove $CLEAN_BASE.s"
[ ! -e "$CLEAN_BASE.ir" ] || fail "clean did not remove $CLEAN_BASE.ir"
[ ! -e "$CLEAN_BASE.o" ] || fail "clean did not remove $CLEAN_BASE.o"
[ ! -e "$CLEAN_BASE.obj" ] || fail "clean did not remove $CLEAN_BASE.obj"
[ ! -e "$CLEAN_BASE" ] || fail "clean did not remove $CLEAN_BASE"
[ ! -e "$CLEAN_BASE.exe" ] || fail "clean did not remove $CLEAN_BASE.exe"
run_cmd clean-source-idempotent "$COMPILER" clean "$CLEAN_SRC"
assert_success
assert_stdout_empty
assert_stderr_empty
fi

run_cmd bad-target "$COMPILER" compile examples/hello.tl --target definitely-not-a-target -o "$WORKDIR/bad-target.s"
assert_failure
assert_stdout_empty
assert_contains "$err" "unknown target"

CHECK_ROOT="$WORKDIR/check-root"
mkdir -p "$CHECK_ROOT/app" "$CHECK_ROOT/repo-stdlib"
cat > "$CHECK_ROOT/repo-stdlib/helper.tl" <<'EOF'
(define (helper) : i64 42)
EOF
cat > "$CHECK_ROOT/app/main.tl" <<'EOF'
(import "stdlib/helper.tl")
(define (main) : i64 (helper))
EOF
run_cmd check-stdlib-root "$COMPILER" check "$CHECK_ROOT/app/main.tl" --stdlib-root "$CHECK_ROOT/repo-stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "Type checking passed!"

UNSAFE_REACH="$WORKDIR/unsafe-import-reach"
mkdir -p "$UNSAFE_REACH"
cat > "$UNSAFE_REACH/lib.tl" <<'EOF'
(define (unsafe-helper [x : i64]) : i64 (+ x 1))
(unsafe
  (define (unsafe-entry [x : i64]) : i64 (unsafe-helper x)))
EOF
cat > "$UNSAFE_REACH/main.tl" <<'EOF'
(import "lib.tl")
(define (main) : i64 (unsafe (unsafe-entry 41)))
EOF
UNSAFE_REACH_TARGET=windows-x86_64
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    UNSAFE_REACH_TARGET=$HOST_TARGET
fi
run_cmd unsafe-import-reach-compile "$COMPILER" compile "$UNSAFE_REACH/main.tl" --target "$UNSAFE_REACH_TARGET" -o "$UNSAFE_REACH/main.s" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
    assert_contains "$out" "Wrote "
fi
assert_contains "$UNSAFE_REACH/main.s" "main:"

echo "[public-tools] CLI command matrix and diagnostics"
CLI_MATRIX="$WORKDIR/cli-matrix"
mkdir -p "$CLI_MATRIX"

compile_backend_modes() {
    cat <<'EOF'
scalar
avx2
avx512
EOF
}

while IFS= read -r mode || [ -n "$mode" ]; do
    [ -n "$mode" ] || continue
    mode_dir="$CLI_MATRIX/backend-$mode"
    mkdir -p "$mode_dir"
    cat > "$mode_dir/main.tl" <<'EOF'
(define (main) : i64 42)
EOF
    run_cmd "compile-backend-$mode" "$COMPILER" compile "$mode_dir/main.tl" --backend-mode "$mode" -o "$mode_dir/main.s"
    if [ "$IS_STAGE1_WRAPPER" -eq 1 ] && [ "$mode" != scalar ]; then
        assert_failure
        assert_stdout_empty
        assert_contains "$err" "compile: --backend-mode $mode requires the Rust compile driver until selfhost SIMD support (#1014)"
        continue
    fi
    if [ "$HOST_ACTION_ENABLED" -eq 0 ] && [ "$mode" != scalar ]; then
        if grep -F -- "compile: --backend-mode $mode requires the Rust compile driver until selfhost SIMD support (#1014)" "$err" > /dev/null; then
            assert_failure
            assert_stdout_empty
            continue
        fi
    fi
    assert_success
    assert_stderr_empty
    if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
        assert_contains "$out" "Wrote "
    fi
    assert_contains "$mode_dir/main.s" "main:"
    if [ "$mode" = avx2 ]; then
        assert_contains "$mode_dir/main.s" "vzeroupper"
    fi
done <<EOF
$(compile_backend_modes)
EOF

simd_shape_dir="$CLI_MATRIX/backend-avx512-shape"
mkdir -p "$simd_shape_dir"
cat > "$simd_shape_dir/main.tl" <<'EOF'
(define (fill [a : (Array i64)] [b : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))
(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 17)]
    [b : (Array i64) (make-array i64 17)]
    [out : (Array i64) (make-array i64 17)]
    (begin
      (fill a b out 17)
      42)))
EOF
run_cmd compile-backend-avx512-shape "$COMPILER" compile "$simd_shape_dir/main.tl" --backend-mode avx512 -o "$simd_shape_dir/main.s"
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "compile: --backend-mode avx512 requires the Rust compile driver until selfhost SIMD support (#1014)"
elif [ "$HOST_ACTION_ENABLED" -eq 0 ] &&
    grep -F -- "compile: --backend-mode avx512 requires the Rust compile driver until selfhost SIMD support (#1014)" "$err" > /dev/null; then
    assert_failure
    assert_stdout_empty
else
    assert_success
    assert_stderr_empty
    assert_contains "$simd_shape_dir/main.s" "%zmm"
    assert_contains "$simd_shape_dir/main.s" "%k"
    assert_contains "$simd_shape_dir/main.s" "vmovdqu64"
    assert_not_contains "$simd_shape_dir/main.s" "vector/mask IR emission is not implemented"
fi

for target_alias in windows-x86_64 windows_x86_64; do
    target_dir="$CLI_MATRIX/target-$target_alias"
    mkdir -p "$target_dir"
    cat > "$target_dir/main.tl" <<'EOF'
(import "stdlib/io.tl")

(define (main) : i64
  (begin
    (print 3)
    42))
EOF
    run_cmd "compile-target-$target_alias" "$COMPILER" compile "$target_dir/main.tl" --target "$target_alias" -o "$target_dir/main.s"
    assert_success
    assert_stderr_empty
    assert_contains_any "$target_dir/main.s" "    .globl main" ".globl main"
    assert_not_contains "$target_dir/main.s" "    .globl _start"
    assert_contains_any "$target_dir/main.s" "    .extern WriteFile" ".extern WriteFile"
    assert_contains "$target_dir/main.s" '    sub $32, %rsp'
    runtime_write_body="$(awk -v label="_tl_stdlib_runtime_runtime_os_write:" '$0 == label { found = 1; next } found && /^_tl_/ && /:$/ { exit } found { print }' "$target_dir/main.s")"
    [ -n "$runtime_write_body" ] || fail "$target_alias runtime-os-write body missing"
    printf '%s\n' "$runtime_write_body" | grep -q "    call tl_alloc" && fail "$target_alias runtime-os-write still calls tl_alloc"
    printf '%s\n' "$runtime_write_body" | grep -q "    leaq -" || fail "$target_alias runtime-os-write missing stack address for WriteFile out-param"
done

cat > "$CLI_MATRIX/main.tl" <<'EOF'
(define (main) : i64 42)
EOF

run_cmd compile-unknown-target "$COMPILER" compile "$CLI_MATRIX/main.tl" --target plan9-x86_64
assert_failure
assert_stdout_empty
assert_contains "$err" "Error: unknown target 'plan9-x86_64'. Expected linux-x86_64 or windows-x86_64"

run_cmd build-unknown-target "$COMPILER" build "$CLI_MATRIX/main.tl" --target plan9-x86_64
assert_failure
assert_stdout_empty
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$err" "Error: stage1 host-action wrapper supports linux-x86_64 only, got plan9-x86_64"
else
    assert_contains "$err" "build: unknown target plan9-x86_64"
fi

run_cmd run-unknown-target "$COMPILER" run "$CLI_MATRIX/main.tl" --target plan9-x86_64
assert_failure
assert_stdout_empty
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$err" "Error: stage1 host-action wrapper supports linux-x86_64 only, got plan9-x86_64"
else
    assert_contains "$err" "run: unknown target plan9-x86_64"
fi

run_cmd compile-unknown-backend-mode "$COMPILER" compile "$CLI_MATRIX/main.tl" --backend-mode neon
assert_failure
assert_stdout_empty
assert_contains "$err" "Error: unknown backend mode 'neon'. Expected scalar, avx2, or avx512"

run_cmd build-unknown-backend-mode "$COMPILER" build "$CLI_MATRIX/main.tl" --backend-mode neon
assert_failure
assert_stdout_empty
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$err" "Error: stage1 host-action wrapper supports scalar backend mode only, got neon"
else
    assert_contains "$err" "build: unknown backend mode neon"
fi

run_cmd run-unknown-backend-mode "$COMPILER" run "$CLI_MATRIX/main.tl" --backend-mode neon
assert_failure
assert_stdout_empty
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$err" "Error: stage1 host-action wrapper supports scalar backend mode only, got neon"
else
    assert_contains "$err" "run: unknown backend mode neon"
fi

cat > "$CLI_MATRIX/unsupported-type-kind.tl" <<'EOF'
(define (f [T : type]) : i64 0)
EOF
run_cmd check-unsupported-type-kind "$COMPILER" check "$CLI_MATRIX/unsupported-type-kind.tl"
assert_failure
assert_stdout_empty
if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 1 ]; then
    assert_contains "$err" "unknown type type"
    assert_contains "$err" "TypeLisp has no source-level type parameters"
else
    assert_contains "$err" "unsupported type kind 'type'"
    assert_contains "$err" "comptime type values are not implemented yet"
fi
assert_not_contains "$err" "backend:"

cat > "$CLI_MATRIX/runtime-type-literal.tl" <<'EOF'
(define (main) : i64 (comptime (type i64)))
EOF
run_cmd check-runtime-type-literal "$COMPILER" check "$CLI_MATRIX/runtime-type-literal.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "type value i64 is compile-time only"
assert_not_contains "$err" "backend:"

cat > "$CLI_MATRIX/region-builtin-escape.tl" <<'EOF'
(import "stdlib/string.tl")

(define (main) : String
  (with-arena r (int->string 41)))
EOF
run_cmd check-region-builtin-escape "$COMPILER" check "$CLI_MATRIX/region-builtin-escape.tl" --stdlib-root "$ROOT/stdlib"
assert_failure
assert_stdout_empty
assert_contains "$err" "region-tagged value"
assert_contains "$err" "cannot escape with-arena"
if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 0 ]; then
    assert_contains "$err" "error[E0200]"
fi

cat > "$CLI_MATRIX/stdlib-region-escape.tl" <<'EOF'
(import "stdlib/string.tl")

(define (main) : String
  (with-arena outer
    (with-arena inner
      (let
        [s : String "  scoped  "]
        (string-trim (& s))))))
EOF
run_cmd check-stdlib-region-escape "$COMPILER" check "$CLI_MATRIX/stdlib-region-escape.tl" --stdlib-root "$ROOT/stdlib"
assert_failure
assert_stdout_empty
assert_contains "$err" "region-tagged value"
assert_contains "$err" "cannot escape with-arena 'inner'"
if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 0 ]; then
    assert_contains "$err" "error[E0200]"
fi

cat > "$CLI_MATRIX/text-buf-region-scalar.tl" <<'EOF'
(import "stdlib/text_buf.tl")

(define (main) : i64
  (let ([buf : TextBuf (text-buf-append (text-buf-empty) "scoped")])
    (with-arena inner
      (string-length (text-buf-render buf)))))
EOF
run_cmd check-text-buf-region-scalar "$COMPILER" check "$CLI_MATRIX/text-buf-region-scalar.tl" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "Type checking passed!"

cat > "$CLI_MATRIX/text-buf-region-escape.tl" <<'EOF'
(import "stdlib/text_buf.tl")

(define (main) : String
  (let ([buf : TextBuf (text-buf-append (text-buf-empty) "scoped")])
    (with-arena outer
      (with-arena inner
        (text-buf-render buf)))))
EOF
run_cmd check-text-buf-region-escape "$COMPILER" check "$CLI_MATRIX/text-buf-region-escape.tl" --stdlib-root "$ROOT/stdlib"
assert_failure
assert_stdout_empty
assert_contains "$err" "region-tagged value"
assert_contains "$err" "cannot escape with-arena 'inner'"
if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 0 ]; then
    assert_contains "$err" "error[E0200]"
fi

cat > "$CLI_MATRIX/numeric-cast-matrix.tl" <<'EOF'
(define (main) : i64 (cast (cast 42 : f64) : i64))
EOF
run_cmd check-numeric-cast-matrix "$COMPILER" check "$CLI_MATRIX/numeric-cast-matrix.tl"
if [ "$code" -eq 0 ]; then
    assert_contains "$out" "Type checking passed!"
else
    assert_contains_any "$err" \
        "floating-point casts are not supported yet" \
        "cast requires integer/char source and target"
fi

cat > "$CLI_MATRIX/unsupported-cast.tl" <<'EOF'
(define (main) : i64 (cast true : i64))
EOF
run_cmd check-unsupported-cast "$COMPILER" check "$CLI_MATRIX/unsupported-cast.tl"
assert_failure
assert_stdout_empty
assert_contains_any "$err" \
    "cast requires scalar numeric (integer/char/float) source and target" \
    "cast requires integer/char source and target"
if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 0 ]; then
    assert_contains "$err" "got bool -> i64"
    assert_contains "$err" "error[E0200]"
fi

cat > "$CLI_MATRIX/inexact-f32-literal.tl" <<'EOF'
(define (main) : f32 0.1)
EOF
run_cmd check-inexact-f32-literal "$COMPILER" check "$CLI_MATRIX/inexact-f32-literal.tl"
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "return type mismatch"
elif [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 1 ]; then
    # The single-binary cli.tl stage0 accepts the inexact f32 literal silently
    # (it does not yet emit the legacy W0200 "not exactly representable"
    # warning). Assert only the typecheck success until that warning is
    # implemented in the selfhost frontend (#1327).
    assert_success
    assert_contains "$out" "Type checking passed!"
else
    assert_success
    assert_contains "$out" "Type checking passed!"
    assert_contains "$err" "warning[W0200]"
    assert_contains "$err" "not exactly representable as f32"
fi

# Extended `run` execution coverage retained for lanes that support the legacy
# SIMD expectations. Current selfhost direct build/run coverage lives in
# scripts/verify-selfhost-cli-build-run.sh, which runs against a fresh cli.tl.
if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
RUN_MATRIX="$WORKDIR/run-matrix"
mkdir -p "$RUN_MATRIX"
cat > "$RUN_MATRIX/output_status.tl" <<'EOF'
(import "stdlib/io.tl")

(define (fixture-stdout-write [text : String]) : unit
  (stdout-write (& text)))
(define (main) : i64
  (begin
    (fixture-stdout-write "hello")
    7))
EOF
run_cmd run-output-status "$COMPILER" run "$RUN_MATRIX/output_status.tl"
assert_code 7
assert_stderr_empty
assert_contains "$out" "hello"

cat > "$RUN_MATRIX/stdin.tl" <<'EOF'
(import "stdlib/io.tl")

(define (fixture-stdout-write [text : String]) : unit
  (stdout-write (& text)))
(define (fixture-read-stdin) : String
  (let
    [read : StdinRead (stdin-read-bytes 256)]
    (stdin-read-text read)))
(define (main) : unit
  (fixture-stdout-write (fixture-read-stdin)))
EOF
printf 'hello from stdin\n' > "$RUN_MATRIX/stdin.in"
run_stdin run-stdin "$RUN_MATRIX/stdin.in" "$COMPILER" run "$RUN_MATRIX/stdin.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "hello from stdin"

PATH_SEP=:
[ "$HOST_OS" = windows ] && PATH_SEP=';'
run_cmd run-env-fixture env -u TYPELISP_STDLIB_TEST_MISSING_854 TYPELISP_STDLIB_TEST_EMPTY= TYPELISP_STDLIB_TEST_VALUE=env-value-854 TYPELISP_STDLIB_TEST_PATH="one${PATH_SEP}two${PATH_SEP}three" "$COMPILER" run stdlib/tests/env_api.tl --stdlib-root "$ROOT/stdlib"
assert_code 42
assert_stdout_empty
assert_stderr_empty

# Public `compile --backend-mode ...` still emits SIMD-targeted assembly above.
# Public `run`/`build` now route non-scalar modes through the selfhost source
# tools when that lane is active, so execution is gated only by host ISA support.
SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh" 2>/dev/null || true)
run_backend_mode_exec() {
    # $1 = backend mode (avx2|avx512); $2 = required ISA token (avx2|avx512f)
    if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
        run_cmd "run-backend-$1-rejected" "$COMPILER" run "$CLI_MATRIX/main.tl" --backend-mode "$1" -- arg
        assert_failure
        assert_stdout_empty
        assert_contains "$err" "Error: stage1 host-action wrapper supports scalar backend mode only, got $1"
        return
    fi
    if printf '%s\n' "$SIMD_ISAS" | grep -qx "$2"; then
        run_cmd "run-backend-$1" "$COMPILER" run "$CLI_MATRIX/main.tl" --backend-mode "$1" -- arg
        assert_code 42
        assert_stdout_empty
        assert_stderr_empty
    else
        echo "[public-tools] not applicable: run --backend-mode $1 requires $2 on this $HOST_OS host"
    fi
}
run_backend_mode_exec avx2 avx2
run_backend_mode_exec avx512 avx512f

# The scalar SPMD source remains an always-run reference. Non-scalar modes now
# execute through public `run` when the host CPU advertises the required ISA.
SPMD_EXEC="$WORKDIR/spmd-exec"
mkdir -p "$SPMD_EXEC"
cat > "$SPMD_EXEC/spmd.tl" <<'TLEOF'
(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 64)]
    [b : (Array i64) (make-array i64 64)]
    [out : (Array i64) (make-array i64 64)]
    [i : i64 0]
    (begin
      (while (< i 64)
        (begin
          (array-set! a i (+ i 1))
          (array-set! b i (* i 2))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 64])
        (array-set! out j (+ (array-ref a j) (array-ref b j))))
      (bit-and (array-ref out 63) 255))))
TLEOF
run_spmd_exec_mode() {
    # $1 = backend mode; $2 = required ISA token, or "-" to always run
    if [ "$IS_STAGE1_WRAPPER" -eq 1 ] && [ "$1" != scalar ]; then
        run_cmd "spmd-exec-$1-rejected" "$COMPILER" run "$SPMD_EXEC/spmd.tl" --backend-mode "$1" -- arg
        assert_failure
        assert_stdout_empty
        assert_contains "$err" "Error: stage1 host-action wrapper supports scalar backend mode only, got $1"
        return
    fi
    if [ "$2" != "-" ] && ! printf '%s\n' "$SIMD_ISAS" | grep -qx "$2"; then
        echo "[public-tools] not applicable: spmd-exec --backend-mode $1 requires $2 on this $HOST_OS host"
        return
    fi
    run_cmd "spmd-exec-$1" "$COMPILER" run "$SPMD_EXEC/spmd.tl" --backend-mode "$1" -- arg
    assert_code 190
    assert_stdout_empty
    assert_stderr_empty
}
run_spmd_exec_mode scalar -
run_spmd_exec_mode avx2 avx2
run_spmd_exec_mode avx512 avx512f
else
    fail "extended run-execution coverage requires host-action drivers"
fi

BUILD_MATRIX="$WORKDIR/build-matrix"
mkdir -p "$BUILD_MATRIX/src"
cat > "$BUILD_MATRIX/typelisp.pkg" <<'EOF'
(package
  (name "backend_mode_build")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
maybe_strip_manifest_kind "$BUILD_MATRIX/typelisp.pkg"
cat > "$BUILD_MATRIX/src/main.tl" <<'EOF'
(define (fill [a : (Array i64)] [b : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))
(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 17)]
    [b : (Array i64) (make-array i64 17)]
    [out : (Array i64) (make-array i64 17)]
    (begin
      (fill a b out 17)
      42)))
EOF
run_cmd build-package-avx512 "$COMPILER" build --manifest-path "$BUILD_MATRIX/typelisp.pkg" --backend-mode avx512
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "Error: stage1 host-action wrapper supports scalar backend mode only, got avx512"
elif [ "$HOST_ACTION_ENABLED" -eq 0 ] &&
    grep -F -- "build: --backend-mode avx512 requires the Rust build driver until selfhost SIMD support (#1014)" "$err" > /dev/null; then
    assert_failure
    assert_stdout_empty
else
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Built "
    BUILD_MATRIX_ASM="$BUILD_MATRIX/target/release/backend_mode_build.s"
    if [ "$HOST_OS" = linux ]; then
        [ -f "$BUILD_MATRIX_ASM" ] || fail "package --backend-mode avx512 did not keep assembly"
        assert_contains "$BUILD_MATRIX_ASM" "%zmm"
        assert_contains "$BUILD_MATRIX_ASM" "%k"
        assert_contains "$BUILD_MATRIX_ASM" "vmovdqu64"
    fi
fi

run_cmd build-source-missing-output-value "$COMPILER" build "$CLI_MATRIX/main.tl" -o
assert_failure
assert_stdout_empty
assert_contains "$err" "build: -o requires a value"

run_cmd build-output-without-source "$COMPILER" build -o "$BUILD_MATRIX/app"
assert_failure
assert_stdout_empty
assert_contains_any "$err" "Error: build -o requires a source file argument" "build: -o requires a source file argument"

if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
    run_cmd build-source-missing-file "$COMPILER" build "$BUILD_MATRIX/missing.tl"
    assert_failure
    assert_stdout_empty
    assert_contains_any "$err" "cannot read module" "cannot read import"
fi

# Retained selfhost build/run compatibility executables. The public cli.tl path
# above is the primary surface; these checks keep the shared build/run cores
# covered as separate compiled tools on every supported host. These gates must
# run on every supported host because omitted build/run tools can hide
# target-specific compiler bugs.
if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
    SELFHOST_PLANNER_DIR="$WORKDIR/selfhost-planners"
    mkdir -p "$SELFHOST_PLANNER_DIR/with space" "$SELFHOST_PLANNER_DIR/stdlib one"
    SELFHOST_TOOL_TARGET=$HOST_TARGET
    if [ "$HOST_OS" = linux ]; then
        command -v as >/dev/null 2>&1 || fail "missing assembler: as"
        command -v ld >/dev/null 2>&1 || fail "missing linker: ld"
        command -v cc >/dev/null 2>&1 || fail "missing C compiler: cc"
        command -v ar >/dev/null 2>&1 || fail "missing archiver: ar"
        build_linux_cli_tool selfhost-build-tool selfhost/build.tl "$SELFHOST_PLANNER_DIR/build-tool"
        build_linux_cli_tool selfhost-run-tool selfhost/run.tl "$SELFHOST_PLANNER_DIR/run-tool"
    else
        build_host_cli_tool selfhost-build-tool selfhost/build.tl "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX"
        build_host_cli_tool selfhost-run-tool selfhost/run.tl "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX"
    fi

    PLANNER_SOURCE="$SELFHOST_PLANNER_DIR/with space/main file.tl"
    PLANNER_OUTPUT="$SELFHOST_PLANNER_DIR/with space/the program$HOST_EXE_SUFFIX"
    cat > "$PLANNER_SOURCE" <<'EOF'
(define (main) : i64 23)
EOF
    run_cmd selfhost-build-tool "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_SOURCE" -o "$PLANNER_OUTPUT" --target "$SELFHOST_TOOL_TARGET" --backend-mode scalar
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Built $(native_arg_path "$PLANNER_OUTPUT")"
    [ -f "$PLANNER_OUTPUT" ] || fail "selfhost build tool did not write executable"
    run_cmd selfhost-build-tool-output "$PLANNER_OUTPUT"
    assert_code 23
    assert_stderr_empty

    run_cmd selfhost-build-source-locked "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_SOURCE" --locked
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: --locked is only valid for package builds"

    run_cmd selfhost-build-source-update-lock "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_SOURCE" --update-lock
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: --update-lock is only valid for package builds"

    if [ "$HOST_OS" = linux ]; then
    LINK_LIB_DIR="$SELFHOST_PLANNER_DIR/native-lib"
    mkdir -p "$LINK_LIB_DIR"
    cat > "$LINK_LIB_DIR/ffi_add7.s" <<'EOF'
    .globl ffi_add7
ffi_add7:
    movq %rdi, %rax
    addq $7, %rax
    ret
    .section .note.GNU-stack,"",@progbits
EOF
    run_cmd link-lib-assemble as "$LINK_LIB_DIR/ffi_add7.s" -o "$LINK_LIB_DIR/ffi_add7.o"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    run_cmd link-lib-archive ar rcs "$LINK_LIB_DIR/libffi_add7.a" "$LINK_LIB_DIR/ffi_add7.o"
    assert_success
    assert_stdout_empty
    assert_stderr_empty

    LINK_SOURCE="$SELFHOST_PLANNER_DIR/with space/link file.tl"
    LINK_OUTPUT="$SELFHOST_PLANNER_DIR/with space/link program"
    cat > "$LINK_SOURCE" <<'EOF'
(extern (ffi_add7 [x : i64]) : i64)
(define (main) : i64 (ffi_add7 35))
EOF
    run_cmd selfhost-build-tool-link-lib "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct "$LINK_SOURCE" -o "$LINK_OUTPUT" --target linux-x86_64 --backend-mode scalar --link-search "$LINK_LIB_DIR" --link-lib ffi_add7
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Built $LINK_OUTPUT"
    run_cmd selfhost-build-tool-link-output "$LINK_OUTPUT"
    assert_code 42
    assert_stderr_empty
    run_cmd selfhost-run-tool-link-lib "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX" --direct "$LINK_SOURCE" --target linux-x86_64 --backend-mode scalar --link-search "$LINK_LIB_DIR" --link-lib ffi_add7
    assert_code 42
    assert_stdout_empty
    assert_stderr_empty

    PUBLIC_LINK_OUTPUT="$SELFHOST_PLANNER_DIR/with space/public link program"
    run_cmd public-build-link-lib "$COMPILER" build "$LINK_SOURCE" -o "$PUBLIC_LINK_OUTPUT" --target linux-x86_64 --link-search "$LINK_LIB_DIR" --link-lib ffi_add7
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Built $PUBLIC_LINK_OUTPUT"
    run_cmd public-build-link-output "$PUBLIC_LINK_OUTPUT"
    assert_code 42
    assert_stderr_empty
    run_cmd public-run-link-lib "$COMPILER" run "$LINK_SOURCE" --target linux-x86_64 --link-search "$LINK_LIB_DIR" --link-lib ffi_add7
    assert_code 42
    assert_stdout_empty
    assert_stderr_empty

    cat > "$LINK_LIB_DIR/ffi_ctor.c" <<'EOF'
static long ffi_ctor_value_state = 0;

__attribute__((constructor)) static void ffi_ctor_init(void) {
    ffi_ctor_value_state = 42;
}

long ffi_ctor_value(void) {
    return ffi_ctor_value_state;
}
EOF
    run_cmd link-lib-ctor-compile cc -c "$LINK_LIB_DIR/ffi_ctor.c" -o "$LINK_LIB_DIR/ffi_ctor.o"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    run_cmd link-lib-ctor-archive ar rcs "$LINK_LIB_DIR/libffi_ctor.a" "$LINK_LIB_DIR/ffi_ctor.o"
    assert_success
    assert_stdout_empty
    assert_stderr_empty

    CTOR_SOURCE="$SELFHOST_PLANNER_DIR/with space/ctor file.tl"
    cat > "$CTOR_SOURCE" <<'EOF'
(import "stdlib/string.tl")

(extern (ffi_ctor_value) : i64)
(define (main) : i64
  (if (string-eq (int->string (ffi_ctor_value)) "42")
    (ffi_ctor_value)
    1))
EOF
    run_cmd selfhost-run-tool-link-ctor "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX" --direct "$CTOR_SOURCE" --target linux-x86_64 --backend-mode scalar --stdlib-root "$ROOT/stdlib" --link-search "$LINK_LIB_DIR" --link-lib ffi_ctor
    assert_code 42
    assert_stdout_empty
    assert_stderr_empty
    run_cmd public-run-link-ctor "$COMPILER" run "$CTOR_SOURCE" --target linux-x86_64 --stdlib-root "$ROOT/stdlib" --link-search "$LINK_LIB_DIR" --link-lib ffi_ctor
    assert_code 42
    assert_stdout_empty
    assert_stderr_empty
    fi

    PLANNER_AVX2_OUTPUT="$SELFHOST_PLANNER_DIR/with space/avx2 program$HOST_EXE_SUFFIX"
    run_cmd selfhost-build-tool-avx2 "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_SOURCE" -o "$PLANNER_AVX2_OUTPUT" --target "$SELFHOST_TOOL_TARGET" --backend-mode avx2
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Built $(native_arg_path "$PLANNER_AVX2_OUTPUT")"
    [ -f "$PLANNER_AVX2_OUTPUT" ] || fail "selfhost build tool did not write avx2 executable"

    PLANNER_RUN_SOURCE="$SELFHOST_PLANNER_DIR/with space/run file.tl"
    if [ "$HOST_OS" = windows ]; then
    cat > "$PLANNER_RUN_SOURCE" <<'EOF'
(import "stdlib/io.tl")

(define (fixture-stdout-write [text : String]) : unit
  (stdout-write (& text)))
(define (main) : i64
  (begin
    (fixture-stdout-write "hello")
    7))
EOF
    else
    cat > "$PLANNER_RUN_SOURCE" <<'EOF'
(import "stdlib/io.tl")

(define (fixture-cstr-len [p : (Ptr u8)]) : i64
  (let
    [n : i64 0]
    (begin
      (while (not (= (unsafe (ptr-read (ptr-offset p n))) (cast 0 : u8)))
        (set! n (+ n 1)))
      n)))
(define (fixture-stdout-write [text : String]) : unit
  (stdout-write (& text)))
(define (fixture-arg [index : i64]) : String
  (let
    [argv : (Ptr (Ptr u8)) (unsafe (program-argv))]
    [raw : (Ptr u8) (unsafe (ptr-read (ptr-offset argv index)))]
    (unsafe (string-from-bytes raw (fixture-cstr-len raw)))))
(define (main) : i64
  (begin
    (fixture-stdout-write (fixture-arg 1))
    (if (string-eq (fixture-arg 2) "colon:arg") 13 2)))
EOF
    fi
    if [ "$HOST_OS" = windows ]; then
        run_cmd selfhost-run-tool "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_RUN_SOURCE" --target "$SELFHOST_TOOL_TARGET" --backend-mode scalar --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/selfhost"
        assert_code 7
        assert_stderr_empty
        assert_contains "$out" "hello"
    else
    run_cmd selfhost-run-tool "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_RUN_SOURCE" --target "$SELFHOST_TOOL_TARGET" --backend-mode scalar --stdlib-root "$ROOT/stdlib" -- "arg with spaces" "colon:arg"
    assert_code 13
    assert_stderr_empty
    assert_contains "$out" "arg with spaces"
    fi

    if [ "$HOST_OS" = linux ]; then
        run_cmd selfhost-run-tool-avx512 "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_RUN_SOURCE" --target "$SELFHOST_TOOL_TARGET" --backend-mode avx512 --stdlib-root "$ROOT/stdlib" -- "arg with spaces" "colon:arg"
        assert_code 13
        assert_stderr_empty
        assert_contains "$out" "arg with spaces"
    elif printf '%s\n' "$SIMD_ISAS" | grep -qx avx2; then
        run_cmd selfhost-run-tool-avx2 "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_RUN_SOURCE" --target "$SELFHOST_TOOL_TARGET" --backend-mode avx2 --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/selfhost"
        assert_code 7
        assert_stderr_empty
        assert_contains "$out" "hello"
    else
        echo "[public-tools] not applicable: retained selfhost run --backend-mode avx2 requires avx2 on this $HOST_OS host"
    fi

    SELFHOST_PKG="$SELFHOST_PLANNER_DIR/pkg"
    mkdir -p "$SELFHOST_PKG/src/nested/deeper" "$SELFHOST_PKG/vendor/math/src"
    cat > "$SELFHOST_PKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
    maybe_strip_manifest_kind "$SELFHOST_PKG/typelisp.pkg"
    cat > "$SELFHOST_PKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 (add-one 41))
EOF
    cat > "$SELFHOST_PKG/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
    cat > "$SELFHOST_PKG/vendor/math/typelisp.pkg" <<'EOF'
(package
  (name "math")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    maybe_strip_manifest_kind "$SELFHOST_PKG/vendor/math/typelisp.pkg"
    run_cmd selfhost-build-package "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --opt-level 0
    assert_success
    assert_stderr_empty
    SELFHOST_PKG_OUT_DIR="$SELFHOST_PKG/target/release"
    SELFHOST_PKG_BIN="$SELFHOST_PKG_OUT_DIR/selfhost_pkg$HOST_EXE_SUFFIX"
    SELFHOST_PKG_ASM="$SELFHOST_PKG_OUT_DIR/selfhost_pkg.s"
    [ -x "$SELFHOST_PKG_BIN" ] || fail "selfhost package build did not write executable"
    [ -f "$SELFHOST_PKG_ASM" ] || fail "selfhost package build did not keep assembly"
    assert_contains "$out" "Built $(native_arg_path "$SELFHOST_PKG_BIN")"
    assert_contains "$SELFHOST_PKG_ASM" "main:"
    assert_contains "$SELFHOST_PKG_ASM" "add_one"
    set +e
    "$SELFHOST_PKG_BIN" > "$WORKDIR/selfhost-package-bin.stdout" 2> "$WORKDIR/selfhost-package-bin.stderr"
    selfhost_pkg_status=$?
    set -e
    [ "$selfhost_pkg_status" -eq 42 ] || fail "selfhost package executable expected exit 42, got $selfhost_pkg_status"

    rm -rf "$SELFHOST_PKG/target"
    run_cmd_cwd selfhost-build-package-discover "$SELFHOST_PKG/src/nested/deeper" "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX"
    assert_success
    assert_stderr_empty
    [ -x "$SELFHOST_PKG_BIN" ] || fail "selfhost package discovery did not write executable"
    [ -f "$SELFHOST_PKG_ASM" ] || fail "selfhost package discovery did not keep assembly"
    assert_contains "$out" "Built "

    SELFHOST_LIBPKG="$SELFHOST_PLANNER_DIR/libpkg"
    mkdir -p "$SELFHOST_LIBPKG/src"
    cat > "$SELFHOST_LIBPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_lib")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    maybe_strip_manifest_kind "$SELFHOST_LIBPKG/typelisp.pkg"
    cat > "$SELFHOST_LIBPKG/src/lib.tl" <<'EOF'
(define (add-two [x : i64]) : i64 (+ x 2))
EOF
    run_cmd selfhost-build-package-lib "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_LIBPKG/typelisp.pkg"
    assert_success
    assert_stderr_empty
    SELFHOST_LIB_ARCHIVE="$SELFHOST_LIBPKG/target/release/${HOST_STATIC_LIB_PREFIX}selfhost_lib$HOST_STATIC_LIB_SUFFIX"
    [ -s "$SELFHOST_LIB_ARCHIVE" ] || fail "selfhost package lib build did not write archive"
    assert_contains "$out" "Built $(native_arg_path "$SELFHOST_LIB_ARCHIVE")"

    SELFHOST_BADPKG="$SELFHOST_PLANNER_DIR/badpkg"
    mkdir -p "$SELFHOST_BADPKG/src" "$SELFHOST_BADPKG/vendor/math/src"
    cat > "$SELFHOST_BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_parse_error")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (deps "not-yet"))
EOF
    maybe_strip_manifest_kind "$SELFHOST_BADPKG/typelisp.pkg"
    run_cmd selfhost-build-package-parse-error "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_BADPKG/typelisp.pkg"
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "invalid package manifest"
    assert_contains "$err" 'unknown manifest field `deps`'

    cat > "$SELFHOST_BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_bad_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
    maybe_strip_manifest_kind "$SELFHOST_BADPKG/typelisp.pkg"
    cat > "$SELFHOST_BADPKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 0)
EOF
    run_cmd selfhost-build-package-missing-alias "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_BADPKG/typelisp.pkg"
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "compiler-load: unknown package alias 'math'"
    assert_contains "$err" "pkg:math/src/lib.tl"

    cat > "$SELFHOST_BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_missing_dep")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
    maybe_strip_manifest_kind "$SELFHOST_BADPKG/typelisp.pkg"
    cat > "$SELFHOST_BADPKG/vendor/math/typelisp.pkg" <<'EOF'
(package
  (name "math")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    maybe_strip_manifest_kind "$SELFHOST_BADPKG/vendor/math/typelisp.pkg"
    cat > "$SELFHOST_BADPKG/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
    cat > "$SELFHOST_BADPKG/src/main.tl" <<'EOF'
(import "pkg:math/src/missing.tl")
(define (main) : i64 0)
EOF
    run_cmd selfhost-build-package-missing-dep "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_BADPKG/typelisp.pkg"
    assert_failure
    # The selfhost --direct planner builds the path dependency's archive first
    # (emitting its `Built` line) before resolving the entry package's
    # imports, so stdout carries the dependency build, not nothing. The failure
    # is the missing import below.
    assert_contains "$err" "compiler-load: cannot read import"
    assert_contains "$err" "vendor/math/src/missing.tl"

    run_cmd selfhost-build-package-opt-duplicate "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --opt-level 1 --opt-level 2
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: --opt-level was provided more than once"

    run_cmd selfhost-build-package-opt-invalid "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --opt-level 9
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: unknown opt level '9'; expected 0, 1, 2, or 3"

    # Profile and opt-level forwarding are observable in the emitted package
    # assembly: release defaults to optimized code, dev defaults to opt level 0,
    # and an explicit --opt-level overrides the profile default.
    SELFHOST_OPTPKG="$SELFHOST_PLANNER_DIR/optpkg"
    mkdir -p "$SELFHOST_OPTPKG/src"
    cat > "$SELFHOST_OPTPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_opt_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
    maybe_strip_manifest_kind "$SELFHOST_OPTPKG/typelisp.pkg"
    cat > "$SELFHOST_OPTPKG/src/main.tl" <<'EOF'
(define (main) : i64 (* 6 7))
EOF
    SELFHOST_OPT_RELEASE_ASM="$SELFHOST_OPTPKG/target/release/selfhost_opt_pkg.s"
    SELFHOST_OPT_DEV_ASM="$SELFHOST_OPTPKG/target/dev/selfhost_opt_pkg.s"
    SELFHOST_OPT_FOLDED_MUL='    movq $42, %rax'
    SELFHOST_OPT_UNFOLDED_MUL="    imulq %r8, %rax"

    rm -rf "$SELFHOST_OPTPKG/target"
    run_cmd selfhost-build-package-opt-default "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg"
    assert_success
    assert_stderr_empty
    [ -f "$SELFHOST_OPT_RELEASE_ASM" ] || fail "selfhost opt package default build did not keep release assembly"
    assert_contains "$SELFHOST_OPT_RELEASE_ASM" "$SELFHOST_OPT_FOLDED_MUL"
    assert_not_contains "$SELFHOST_OPT_RELEASE_ASM" "$SELFHOST_OPT_UNFOLDED_MUL"

    rm -rf "$SELFHOST_OPTPKG/target"
    run_cmd selfhost-build-package-profile-dev "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg" --profile dev
    assert_success
    assert_stderr_empty
    [ -f "$SELFHOST_OPT_DEV_ASM" ] || fail "selfhost opt package dev profile build did not keep dev assembly"
    assert_contains "$SELFHOST_OPT_DEV_ASM" "$SELFHOST_OPT_UNFOLDED_MUL"

    rm -rf "$SELFHOST_OPTPKG/target"
    run_cmd selfhost-build-package-opt-zero "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg" --opt-level 0
    assert_success
    assert_stderr_empty
    [ -f "$SELFHOST_OPT_RELEASE_ASM" ] || fail "selfhost opt package --opt-level 0 build did not keep release assembly"
    assert_contains "$SELFHOST_OPT_RELEASE_ASM" "$SELFHOST_OPT_UNFOLDED_MUL"

    rm -rf "$SELFHOST_OPTPKG/target"
    run_cmd selfhost-build-package-opt-two "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg" --opt-level 2
    assert_success
    assert_stderr_empty
    [ -f "$SELFHOST_OPT_RELEASE_ASM" ] || fail "selfhost opt package --opt-level 2 build did not keep release assembly"
    assert_contains "$SELFHOST_OPT_RELEASE_ASM" "$SELFHOST_OPT_FOLDED_MUL"
    assert_not_contains "$SELFHOST_OPT_RELEASE_ASM" "$SELFHOST_OPT_UNFOLDED_MUL"

    rm -rf "$SELFHOST_OPTPKG/target"
    run_cmd selfhost-build-package-profile-release-opt-zero "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg" --profile release --opt-level 0
    assert_success
    assert_stderr_empty
    [ -f "$SELFHOST_OPT_RELEASE_ASM" ] || fail "selfhost opt package release profile --opt-level 0 build did not keep release assembly"
    assert_contains "$SELFHOST_OPT_RELEASE_ASM" "$SELFHOST_OPT_UNFOLDED_MUL"

    rm -rf "$SELFHOST_OPTPKG/target"
    run_cmd selfhost-build-package-profile-invalid "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg" --profile fast
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: unknown profile 'fast'; expected dev or release"

    run_cmd selfhost-build-package-profile-duplicate "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg" --profile dev --release
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: profile was provided more than once"

    run_cmd selfhost-build-package-opt-missing "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_OPTPKG/typelisp.pkg" --opt-level
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: --opt-level requires a value"

    rm -rf "$SELFHOST_PKG/target"
    run_cmd selfhost-build-package-mode-staged "$SELFHOST_PLANNER_DIR/build-tool$HOST_EXE_SUFFIX" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --backend-mode avx2
    assert_success
    assert_stderr_empty
    [ -f "$SELFHOST_PKG_ASM" ] || fail "selfhost package --backend-mode avx2 did not keep assembly"
    assert_contains "$out" "Built $(native_arg_path "$SELFHOST_PKG_BIN")"
    assert_contains "$SELFHOST_PKG_ASM" "vzeroupper"

    run_cmd selfhost-run-tool-missing-target "$SELFHOST_PLANNER_DIR/run-tool$HOST_EXE_SUFFIX" --direct "$PLANNER_SOURCE" --target
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "run: --target requires a value"
else
    fail "selfhost build/run tool executable coverage requires native build/run support"
fi

echo "[public-tools] backend diagnostics"
BACKEND_DIAG_DIR="$ROOT/tests/diagnostics/backend"
BACKEND_DIAG_WORK="$WORKDIR/backend-diagnostics"
BACKEND_DIAG_MANIFEST="$BACKEND_DIAG_DIR/manifest.txt"
mkdir -p "$BACKEND_DIAG_WORK"

while IFS='|' read -r diag_name diag_command diag_expect || [ -n "$diag_name" ]; do
    diag_name=$(printf '%s' "$diag_name" | tr -d '\r')
    diag_command=$(printf '%s' "$diag_command" | tr -d '\r')
    diag_expect=$(printf '%s' "$diag_expect" | tr -d '\r')
    case "$diag_name" in
        "" | \#*) continue ;;
    esac
    case "$diag_name" in
        *[!A-Za-z0-9_]*)
            fail "backend diagnostic manifest has invalid case name: $diag_name"
            ;;
    esac
    source="$BACKEND_DIAG_DIR/$diag_name.tl"
    contains="$BACKEND_DIAG_DIR/$diag_name.stderr.contains"
    work_source="$BACKEND_DIAG_WORK/$diag_name.tl"

    [ -f "$source" ] || fail "backend diagnostic source missing: $source"
    [ -f "$contains" ] || fail "backend diagnostic expectations missing: $contains"
    cp "$source" "$work_source"

    case "$diag_command" in
        compile)
            run_cmd "backend-$diag_name" "$COMPILER" compile "$work_source"
            ;;
        *)
            fail "unknown backend diagnostic command for $diag_name: $diag_command"
            ;;
    esac

    case "$diag_expect" in
        failure) assert_failure ;;
        *)
            fail "unknown backend diagnostic expectation for $diag_name: $diag_expect"
            ;;
    esac
    assert_stdout_empty

    while IFS= read -r expected || [ -n "$expected" ]; do
        expected=$(printf '%s' "$expected" | tr -d '\r')
        [ -n "$expected" ] || continue
        assert_contains "$err" "$expected"
    done < "$contains"
done < "$BACKEND_DIAG_MANIFEST"

if [ "$HAS_LINT_COMMAND" = 1 ]; then
    echo "[public-tools] lint command"
    cat > "$WORKDIR/lint_ladder.tl" <<'EOF'
(define (classify [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))
EOF
    run_cmd lint-nested-if "$COMPILER" lint "$WORKDIR/lint_ladder.tl"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "lint_ladder.tl:"
    assert_contains "$out" "nested if-ladder"
    assert_contains "$out" "prefer cond"
    assert_contains "$out" "match"
    assert_contains "$out" "lint: 1 finding(s)"

    run_cmd lint-nested-if-check "$COMPILER" lint "$WORKDIR/lint_ladder.tl" --check
    assert_failure
    assert_stderr_empty
    assert_contains "$out" "lint_ladder.tl:"
    assert_contains "$out" "nested if-ladder"
    assert_contains "$out" "lint: 1 finding(s)"

    cat > "$WORKDIR/lint_clean.tl" <<'EOF'
(define (classify [x : i64]) : i64
  (if (= x 0)
    10
    0))
EOF
    run_cmd lint-clean "$COMPILER" lint "$WORKDIR/lint_clean.tl"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "lint: 0 finding(s)"

    run_cmd lint-clean-check "$COMPILER" lint "$WORKDIR/lint_clean.tl" --check
    assert_success
    assert_stderr_empty
    assert_contains "$out" "lint: 0 finding(s)"

    run_cmd lint-multi "$COMPILER" lint "$WORKDIR/lint_clean.tl" "$WORKDIR/lint_ladder.tl"
    assert_success
    assert_stderr_empty
    lint_clean_display=$(native_arg_path "$WORKDIR/lint_clean.tl")
    lint_ladder_display=$(native_arg_path "$WORKDIR/lint_ladder.tl")
    assert_contains "$out" "--- $lint_clean_display"
    assert_contains "$out" "--- $lint_ladder_display"
    assert_contains "$out" "lint_ladder.tl:"
    assert_contains "$out" "lint: 0 finding(s)"
    assert_contains "$out" "lint: 1 finding(s)"
    lint_multi_clean_line=$(grep -nF -- "--- $lint_clean_display" "$out" | head -n 1 | cut -d: -f1)
    lint_multi_ladder_line=$(grep -nF -- "--- $lint_ladder_display" "$out" | head -n 1 | cut -d: -f1)
    if [ "$lint_multi_clean_line" -ge "$lint_multi_ladder_line" ]; then
        fail "lint multi-file output did not preserve input path order"
    fi

    run_cmd lint-files-manifest "$COMPILER" lint "$WORKDIR/lint_clean.tl" "$WORKDIR/lint_ladder.tl" --manifest-path typelisp.pkg
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "cannot combine input paths with --manifest-path"

    LINT_NOPKG=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-public-lint-nopkg.XXXXXX")
    run_cmd_cwd lint-missing "$LINT_NOPKG" "$COMPILER" lint
    assert_failure
    assert_stdout_empty
    if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 1 ]; then
        assert_contains "$err" "could not find typelisp.pkg"
    else
        assert_contains "$err" "Error: missing file argument"
        assert_contains "$err" "typelisp lint"
    fi
    rm -rf "$LINT_NOPKG"

    printf '(define (' > "$WORKDIR/lint_parse_error.tl"
    run_cmd lint-parse-error-check "$COMPILER" lint "$WORKDIR/lint_parse_error.tl" --check
    assert_failure
    assert_stdout_empty
    assert_stderr_nonempty
else
    fail "public lint CLI is required"
fi

echo "[public-tools] formatter golden corpus"
format_manifest() {
    cat <<'EOF'
char_literal
comments
decls
flow
let_bindings
negative_int
quote
tail_comment
EOF
}

format_manifest | sort > "$WORKDIR/format-expected.txt"
find tests/format_golden -maxdepth 1 -type f -name '*.tl' |
    sed 's#^tests/format_golden/##; s#\.tl$##' | sort > "$WORKDIR/format-actual.txt"
if ! cmp -s "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual.txt"; then
    diff -u "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual.txt" >&2 || true
    fail "format golden source manifest is out of date"
fi

find tests/format_golden -maxdepth 1 -type f -name '*.expected' |
    sed 's#^tests/format_golden/##; s#\.expected$##' | sort > "$WORKDIR/format-actual-expected.txt"
if ! cmp -s "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual-expected.txt"; then
    diff -u "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual-expected.txt" >&2 || true
    fail "format golden expected-output manifest is out of date"
fi

while IFS= read -r fmt_name; do
    [ -n "$fmt_name" ] || continue
    case_name="fmt-$fmt_name"
    cp "tests/format_golden/$fmt_name.tl" "$WORKDIR/$fmt_name.tl"
    strip_expected_trailing_lf "tests/format_golden/$fmt_name.expected" "$WORKDIR/$fmt_name.expected"

    run_cmd "$case_name" "$COMPILER" fmt "$WORKDIR/$fmt_name.tl"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    check_file_exact "$WORKDIR/$fmt_name.tl" "$WORKDIR/$fmt_name.expected"

    run_cmd "$case_name-check" "$COMPILER" fmt --check "$WORKDIR/$fmt_name.tl"
    assert_success
    assert_stdout_empty
    assert_stderr_empty

    run_cmd "$case_name-idempotent" "$COMPILER" fmt "$WORKDIR/$fmt_name.tl"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    check_file_exact "$WORKDIR/$fmt_name.tl" "$WORKDIR/$fmt_name.expected"
done < "$WORKDIR/format-expected.txt"

echo "[public-tools] doc and doctest commands"
cat > "$WORKDIR/docs.tl" <<'EOF'
;# Module docs.
;# ```typelisp
;# (define (main) : i64 42)
;# ```

;: Item docs.
;: ```tl
;: (define answer : i64 42)
;: ```
(define documented : i64 1)
EOF
run_cmd doc-test-pass "$COMPILER" doc --test "$WORKDIR/docs.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 2 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs.tl"

cat > "$WORKDIR/docs_expected_error.tl" <<'EOF'
;# Expected error.
;# ```typelisp expect-error
;# (define (bad) : i64 true)
;# ```
EOF
run_cmd doc-test-expected-error "$COMPILER" doc --test "$WORKDIR/docs_expected_error.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 1 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs_expected_error.tl"

cat > "$WORKDIR/docs_malformed.tl" <<'EOF'
;# Bad fence.
;# ```typelisp maybe
;# (define (main) : i64 0)
;# ```
EOF
run_cmd doc-test-malformed "$COMPILER" doc --test "$WORKDIR/docs_malformed.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" 'unsupported TypeLisp doctest option `maybe`'
assert_doctest_temp_cleaned "$WORKDIR/docs_malformed.tl"

cat > "$WORKDIR/docs_empty.tl" <<'EOF'
;# Docs without fenced examples.
;: Item docs without fenced examples.
(define documented : i64 1)
EOF
run_cmd doc-test-empty "$COMPILER" doc --test "$WORKDIR/docs_empty.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 0 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs_empty.tl"

cat > "$WORKDIR/docs_second.tl" <<'EOF'
;# Second docs file.
;# ```typelisp
;# (define (main) : i64 42)
;# ```
EOF
run_cmd doc-test-multiple "$COMPILER" doc --test "$WORKDIR/docs.tl" "$WORKDIR/docs_second.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "--- $(native_arg_path "$WORKDIR/docs.tl")"
assert_contains "$out" "--- $(native_arg_path "$WORKDIR/docs_second.tl")"
assert_contains "$out" "Doc tests passed: 2 example(s)"
assert_contains "$out" "Doc tests passed: 1 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs.tl"
assert_doctest_temp_cleaned "$WORKDIR/docs_second.tl"

DOC_STDLIB_ROOT="$WORKDIR/doc-test-stdlib-root/repo-stdlib"
mkdir -p "$DOC_STDLIB_ROOT"
cat > "$DOC_STDLIB_ROOT/docfixture.tl" <<'EOF'
(define stdlib-answer : i64 42)
EOF
cat > "$WORKDIR/docs_stdlib_root.tl" <<'EOF'
;# Stdlib import example.
;# ```typelisp
;# (import "stdlib/docfixture.tl")
;# (define (main) : i64 stdlib-answer)
;# ```
EOF
run_cmd doc-test-stdlib-root "$COMPILER" doc --test "$WORKDIR/docs_stdlib_root.tl" --stdlib-root "$DOC_STDLIB_ROOT"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 1 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs_stdlib_root.tl"

cat > "$WORKDIR/docs_bad.tl" <<'EOF'
;# Unexpected error.
;# ```typelisp
;# (define (bad) : i64 true)
;# ```
EOF
run_cmd doc-test-unexpected-error "$COMPILER" doc --test "$WORKDIR/docs_bad.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "doc tests failed"
assert_contains "$err" "was expected to pass"
if [ "$IS_STAGE1_WRAPPER" -eq 0 ]; then
    assert_contains "$err" "error[E0200]"
fi
assert_doctest_temp_cleaned "$WORKDIR/docs_bad.tl"

run_cmd doc-test-manifest-input-error "$COMPILER" doc --test "$WORKDIR/docs.tl" --manifest-path typelisp.pkg
assert_failure
assert_stdout_empty
assert_contains "$err" "doc: cannot combine input paths with --manifest-path"

run_cmd doc-usage-missing "$COMPILER" doc
assert_failure
assert_stdout_empty
if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 1 ]; then
    # cli.tl's selfhost doc driver reports missing paths with its own wording
    # instead of the Rust CLI `Usage:` block. Assert the selfhost diagnostic until
    # the wording is unified (#1327).
    assert_contains "$err" "doc: expected input and output paths"
else
    assert_contains "$err" "Usage:"
    assert_contains "$err" "typelisp doc <file.tl>"
    assert_contains "$err" "typelisp doc --test <file.tl>"
fi

if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 1 ]; then
    DOC_NO_PACKAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-public-doc-nopkg.XXXXXX")
    run_cmd_cwd doc-test-usage-missing "$DOC_NO_PACKAGE_DIR" "$COMPILER" doc --test
else
    run_cmd doc-test-usage-missing "$COMPILER" doc --test
fi
assert_failure
assert_stdout_empty
if [ "$SELFHOST_FRONTEND_DIAGNOSTICS" -eq 1 ]; then
    assert_contains "$err" "doc: could not find typelisp.pkg"
else
    assert_contains "$err" "Usage:"
    assert_contains "$err" "typelisp doc --test <file.tl>"
fi

# Doc *generation* (`doc <src> -o <out>` markdown/HTML) is part of the public
# tool gate and must run wherever the public doc command is available.
if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
    echo "[public-tools] doc generation"
    cat > "$WORKDIR/doc_source.tl" <<'EOF'
;# Module docs.

;: Item docs.
(define answer : i64 42)
EOF
    run_cmd doc-generate "$COMPILER" doc "$WORKDIR/doc_source.tl" -o "$WORKDIR/doc_source.md"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Wrote "
    assert_contains "$WORKDIR/doc_source.md" "Module docs."
    assert_contains "$WORKDIR/doc_source.md" "answer"

    run_cmd doc-generate-positional "$COMPILER" doc "$WORKDIR/doc_source.tl" "$WORKDIR/doc_source_positional.md"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Wrote $(native_arg_path "$WORKDIR/doc_source_positional.md")"
    assert_contains "$WORKDIR/doc_source_positional.md" "Module docs."
    assert_contains "$WORKDIR/doc_source_positional.md" "answer"

    DOC_CUSTOM_DIR="$WORKDIR/custom-doc-output"
    DOC_CUSTOM_OUT="$DOC_CUSTOM_DIR/custom.md"
    mkdir -p "$DOC_CUSTOM_DIR"
    cat > "$WORKDIR/doc_custom_input.tl" <<'EOF'
;: Single item.
(define x : i64 1)
EOF
    run_cmd doc-generate-custom "$COMPILER" doc "$WORKDIR/doc_custom_input.tl" -o "$DOC_CUSTOM_OUT"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Wrote $(native_arg_path "$DOC_CUSTOM_OUT")"
    assert_contains "$DOC_CUSTOM_OUT" "x"

    DOC_GRAPH_DIR="$WORKDIR/doc-module-graph"
    DOC_GRAPH_STDLIB="$DOC_GRAPH_DIR/repo-stdlib"
    DOC_GRAPH_LOCAL="$DOC_GRAPH_DIR/local.tl"
    DOC_GRAPH_STDLIB_SOURCE="$DOC_GRAPH_STDLIB/docfixture.tl"
    DOC_GRAPH_ENTRY="$DOC_GRAPH_DIR/entry.tl"
    DOC_GRAPH_OUT="$DOC_GRAPH_DIR/graph.md"
    mkdir -p "$DOC_GRAPH_STDLIB"
    cat > "$DOC_GRAPH_LOCAL" <<'EOF'
;# Local module docs.

;: Local answer docs.
(define local-answer : i64 7)
EOF
    cat > "$DOC_GRAPH_STDLIB_SOURCE" <<'EOF'
;# Stdlib module docs.

;: Stdlib answer docs.
(define stdlib-answer : i64 35)
EOF
    cat > "$DOC_GRAPH_ENTRY" <<'EOF'
;# Entry module docs.

(import "local.tl")
(import "local.tl")
(import "stdlib/docfixture.tl")

;: Entry docs.
(define (main) : i64 (+ local-answer stdlib-answer))
EOF
    run_cmd doc-generate-module-graph "$COMPILER" doc "$DOC_GRAPH_ENTRY" -o "$DOC_GRAPH_OUT" --stdlib-root "$DOC_GRAPH_STDLIB"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Wrote $(native_arg_path "$DOC_GRAPH_OUT")"

    DOC_GRAPH_ENTRY_PATH=$(CDPATH= cd -- "$(dirname -- "$DOC_GRAPH_ENTRY")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$DOC_GRAPH_ENTRY")")
    DOC_GRAPH_LOCAL_PATH=$(CDPATH= cd -- "$(dirname -- "$DOC_GRAPH_LOCAL")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$DOC_GRAPH_LOCAL")")
    DOC_GRAPH_STDLIB_PATH=$(CDPATH= cd -- "$(dirname -- "$DOC_GRAPH_STDLIB_SOURCE")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$DOC_GRAPH_STDLIB_SOURCE")")
    DOC_GRAPH_ENTRY_DISPLAY=$(native_arg_path "$DOC_GRAPH_ENTRY_PATH")
    DOC_GRAPH_LOCAL_DISPLAY=$(native_arg_path "$DOC_GRAPH_LOCAL_PATH")
    DOC_GRAPH_STDLIB_DISPLAY=$(native_arg_path "$DOC_GRAPH_STDLIB_PATH")
    assert_contains "$DOC_GRAPH_OUT" "## Modules"
    assert_contains "$DOC_GRAPH_OUT" "- [$DOC_GRAPH_ENTRY_DISPLAY](#"
    assert_contains "$DOC_GRAPH_OUT" "Source: \`$DOC_GRAPH_LOCAL_DISPLAY\`"
    assert_contains "$DOC_GRAPH_OUT" "Source: \`$DOC_GRAPH_STDLIB_DISPLAY\`"
    assert_contains "$DOC_GRAPH_OUT" "Entry module docs."
    assert_contains "$DOC_GRAPH_OUT" "Local module docs."
    assert_contains "$DOC_GRAPH_OUT" "Stdlib module docs."
    DOC_GRAPH_LOCAL_DOCS=$(grep -F "Local module docs." "$DOC_GRAPH_OUT" | wc -l | tr -d ' ')
    [ "$DOC_GRAPH_LOCAL_DOCS" -eq 1 ] || fail "doc module graph duplicated local docs"
    DOC_GRAPH_ENTRY_LINE=$(grep -nF "## $DOC_GRAPH_ENTRY_DISPLAY" "$DOC_GRAPH_OUT" | head -n 1 | cut -d: -f1)
    DOC_GRAPH_LOCAL_LINE=$(grep -nF "## $DOC_GRAPH_LOCAL_DISPLAY" "$DOC_GRAPH_OUT" | head -n 1 | cut -d: -f1)
    DOC_GRAPH_STDLIB_LINE=$(grep -nF "## $DOC_GRAPH_STDLIB_DISPLAY" "$DOC_GRAPH_OUT" | head -n 1 | cut -d: -f1)
    [ "$DOC_GRAPH_ENTRY_LINE" -lt "$DOC_GRAPH_LOCAL_LINE" ] &&
        [ "$DOC_GRAPH_LOCAL_LINE" -lt "$DOC_GRAPH_STDLIB_LINE" ] ||
        fail "doc module graph did not preserve loader source order"

    DOC_GRAPH_EXPLICIT_OUT="$DOC_GRAPH_DIR/explicit.md"
    run_cmd doc-generate-explicit-module-graph "$COMPILER" doc "$DOC_GRAPH_ENTRY" "$DOC_GRAPH_LOCAL" "$DOC_GRAPH_STDLIB_SOURCE" "$DOC_GRAPH_EXPLICIT_OUT"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Wrote $(native_arg_path "$DOC_GRAPH_EXPLICIT_OUT")"
    assert_contains "$DOC_GRAPH_EXPLICIT_OUT" "## Modules"
    assert_contains "$DOC_GRAPH_EXPLICIT_OUT" "Entry module docs."
    assert_contains "$DOC_GRAPH_EXPLICIT_OUT" "Local module docs."
    assert_contains "$DOC_GRAPH_EXPLICIT_OUT" "Stdlib module docs."

    DOC_TOOL="$WORKDIR/selfhost-doc-tool$HOST_EXE_SUFFIX"
    if [ "$HOST_OS" = linux ]; then
        build_linux_cli_tool selfhost-doc-tool selfhost/doc.tl "$DOC_TOOL"
    else
        build_host_cli_tool selfhost-doc-tool selfhost/doc.tl "$DOC_TOOL"
    fi
    run_cmd doc-generate-html "$DOC_TOOL" --html "$WORKDIR/doc_source.tl" "$WORKDIR/doc_source.html"
    assert_success
    assert_contains "$out" "Wrote $(native_arg_path "$WORKDIR/doc_source.html")"
    assert_stderr_empty
    assert_contains "$WORKDIR/doc_source.html" "<!doctype html>"
    assert_contains "$WORKDIR/doc_source.html" "typelisp-docs.css"
    assert_contains "$WORKDIR/doc_source.html" "id=\"tl-answer\""
    assert_contains "$WORKDIR/doc_source.html" "<code class=\"language-typelisp\">(define answer : i64 42)</code>"
else
    fail "doc generation requires host-action drivers"
fi

echo "[public-tools] inline test command"
cat > "$WORKDIR/inline_test_pass.tl" <<'EOF'
(import "stdlib/test.tl")

(define (inc [x : i64]) : i64 (+ x 1))

(define (main) : i64 0)

(test inc-basic
  (assert-i64-eq (inc 41) 42 "inc result"))
EOF

run_cmd inline-test-check "$COMPILER" test --check "$WORKDIR/inline_test_pass.tl" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "TypeLisp test typecheck passed: 1 test(s)"

run_cmd inline-test-pass "$COMPILER" test "$WORKDIR/inline_test_pass.tl" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stdout_empty
assert_contains "$err" "test inc-basic"
assert_contains "$err" "ok inc-basic"
assert_contains "$err" "TypeLisp tests passed: 1 test(s)"
[ ! -f "$WORKDIR/inline_test_pass.tl.test.s" ] || fail "typelisp test left scratch assembly behind"

run_cmd inline-test-normal-compile "$COMPILER" compile "$WORKDIR/inline_test_pass.tl" --target "$HOST_TARGET" -o "$WORKDIR/inline_test_pass.s" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
    assert_contains "$out" "Wrote "
fi
assert_not_contains "$WORKDIR/inline_test_pass.s" "__tl_inline_test"

cat > "$WORKDIR/inline_test_fail.tl" <<'EOF'
(import "stdlib/test.tl")

(test failing-case
  (assert-i64-eq 1 2 "inline failure message"))
EOF

    run_cmd inline-test-fail "$COMPILER" test "$WORKDIR/inline_test_fail.tl" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "test failing-case"
    assert_contains "$err" "inline failure message"
    assert_contains "$err" "typelisp test: test executable exited"
    [ ! -f "$WORKDIR/inline_test_fail.tl.test.s" ] || fail "failing typelisp test left scratch assembly behind"

cat > "$WORKDIR/inline_test_no_tests.tl" <<'EOF'
(define (main) : i64 0)
EOF
run_cmd inline-test-no-tests-check "$COMPILER" test --check "$WORKDIR/inline_test_no_tests.tl" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "TypeLisp test typecheck passed: 0 test(s)"

run_cmd inline-test-no-tests-run "$COMPILER" test "$WORKDIR/inline_test_no_tests.tl" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stdout_empty
assert_contains "$err" "TypeLisp tests passed: 0 test(s)"
[ ! -f "$WORKDIR/inline_test_no_tests.tl.test.s" ] || fail "no-test typelisp test left scratch assembly behind"

if [ "$HOST_ACTION_ENABLED" -eq 1 ]; then
echo "[public-tools] package test discovery"
TEST_PKG="$WORKDIR/package-test-pkg"
mkdir -p "$TEST_PKG/src" "$TEST_PKG/tests/format_golden" "$TEST_PKG/tests/nested" \
    "$TEST_PKG/tests/target/ignored" "$TEST_PKG/tests/vendor/child/src"
cat > "$TEST_PKG/typelisp.pkg" <<'EOF'
(package
  (name "package_test_pkg")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
maybe_strip_manifest_kind "$TEST_PKG/typelisp.pkg"
cat > "$TEST_PKG/src/lib.tl" <<'EOF'
(test pkg-inline
  (if (= 42 42)
    unit
    (let [_ : i64 (/ 1 0)] unit)))
EOF
cat > "$TEST_PKG/tests/basic.tl" <<'EOF'
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-i64-eq (+ 20 22) 42 "package tests dir basic")
    0))
EOF
cat > "$TEST_PKG/tests/nested/more.tl" <<'EOF'
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-i64-eq (* 6 7) 42 "package nested tests dir")
    0))
EOF
cat > "$TEST_PKG/tests/format_golden/fixture.tl" <<'EOF'
;; Package test discovery must not treat formatter fixtures as integration tests.
(define fixture-value : i64 42)
EOF
cat > "$TEST_PKG/tests/target/ignored/fail.tl" <<'EOF'
(define (main) : i64 9)
EOF
cat > "$TEST_PKG/tests/vendor/child/typelisp.pkg" <<'EOF'
(package (name "child-tests") (version "0.1.0") (kind "lib"))
EOF
maybe_strip_manifest_kind "$TEST_PKG/tests/vendor/child/typelisp.pkg"
cat > "$TEST_PKG/tests/vendor/child/src/fail.tl" <<'EOF'
(define (main) : i64 9)
EOF
run_cmd_cwd package-test-check "$TEST_PKG/src" "$COMPILER" test --check --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "TypeLisp test file:"
assert_contains "$out" "TypeLisp integration test file:"
assert_contains "$out" "TypeLisp package test typecheck passed: 3 test(s) in 3 file(s)"
run_cmd_cwd package-test-run "$TEST_PKG/src" "$COMPILER" test --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
assert_success
assert_contains "$out" "TypeLisp integration test file:"
assert_contains "$out" "TypeLisp package tests passed: 3 test(s) in 3 file(s)"
assert_contains "$err" "test pkg-inline"
assert_contains "$err" "ok pkg-inline"

TEST_EMPTY_PKG="$WORKDIR/package-test-empty-pkg"
mkdir -p "$TEST_EMPTY_PKG/src"
cat > "$TEST_EMPTY_PKG/typelisp.pkg" <<'EOF'
(package
  (name "package_test_empty_pkg")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
maybe_strip_manifest_kind "$TEST_EMPTY_PKG/typelisp.pkg"
cat > "$TEST_EMPTY_PKG/src/lib.tl" <<'EOF'
(define lib-value : i64 42)
EOF
run_cmd_cwd package-test-empty "$TEST_EMPTY_PKG" "$COMPILER" test --check --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "TypeLisp package test typecheck passed: 0 test(s) in 0 file(s)"

TEST_FAIL_PKG="$WORKDIR/package-test-fail-pkg"
mkdir -p "$TEST_FAIL_PKG/src" "$TEST_FAIL_PKG/tests"
cat > "$TEST_FAIL_PKG/typelisp.pkg" <<'EOF'
(package
  (name "package_test_fail_pkg")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
maybe_strip_manifest_kind "$TEST_FAIL_PKG/typelisp.pkg"
cat > "$TEST_FAIL_PKG/src/lib.tl" <<'EOF'
(define lib-value : i64 42)
EOF
cat > "$TEST_FAIL_PKG/tests/fail.tl" <<'EOF'
(define (main) : i64 7)
EOF
run_cmd package-test-fail "$COMPILER" test --target "$HOST_TARGET" --manifest-path "$TEST_FAIL_PKG/typelisp.pkg"
if [ "$code" -ne 1 ]; then
    fail "package integration failure exited $code, expected 1"
fi
assert_contains "$out" "TypeLisp integration test file:"
assert_contains "$err" "typelisp test: test executable exited with exit status: 7"

echo "[public-tools] package build"
PKG="$WORKDIR/pkg"
mkdir -p "$PKG/src" "$PKG/vendor/math/src"
cat > "$PKG/typelisp.pkg" <<'EOF'
(package
  (name "public_tool_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
maybe_strip_manifest_kind "$PKG/typelisp.pkg"
cat > "$PKG/src/main.tl" <<'EOF'
(import "math.tl")
(import "pkg:math/src/lib.tl")
(define (main) : i64 (add-one (inc 40)))
EOF
cat > "$PKG/src/math.tl" <<'EOF'
(define (inc [x : i64]) : i64 (+ x 1))
EOF
cat > "$PKG/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
cat > "$PKG/vendor/math/typelisp.pkg" <<'EOF'
(package
  (name "math")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
maybe_strip_manifest_kind "$PKG/vendor/math/typelisp.pkg"
run_cmd package-build "$COMPILER" build --manifest-path "$PKG/typelisp.pkg"
assert_success
assert_stderr_empty
PKG_ASM="$PKG/target/release/public_tool_pkg.s"
[ -f "$PKG_ASM" ] || fail "package build did not write deterministic assembly"
assert_contains "$out" "Built "
assert_contains "$PKG_ASM" "main:"
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$PKG_ASM" "inc:"
    assert_contains "$PKG_ASM" "add_one"
else
    assert_contains_any "$PKG_ASM" \
        "_tl_inc:" \
        "_tl_math_inc:" \
        "_tl_public_tool_pkg_src_math_inc"
    assert_contains "$PKG_ASM" "add_one"
    assert_contains "$PKG_ASM" "_tl_public_tool_pkg_src_math_inc"
    assert_contains "$PKG_ASM" "_tl_math_src_lib_add_one"
    assert_contains "$PKG_ASM" "_tl_stdlib_runtime_runtime_os_write"
    assert_not_contains "$PKG_ASM" "_tl_public_tool_pkg_vendor_math"
fi
if [ "$HAS_CLEAN_COMMAND" -eq 1 ]; then
PKG_OUT_DIR="$PKG/target/release"
run_cmd package-clean-dry-run "$COMPILER" clean --dry-run --manifest-path "$PKG/typelisp.pkg"
assert_success
assert_stderr_empty
assert_contains "$out" "Would remove:"
assert_contains "$out" "public_tool_pkg.s"
[ -f "$PKG_ASM" ] || fail "package clean dry-run removed assembly"
run_cmd package-clean "$COMPILER" clean --manifest-path "$PKG/typelisp.pkg"
assert_success
assert_stderr_empty
assert_contains "$out" "Removed:"
[ ! -e "$PKG_ASM" ] || fail "package clean did not remove $PKG_ASM"
[ ! -d "$PKG_OUT_DIR" ] || fail "package clean did not remove $PKG_OUT_DIR"
run_cmd package-clean-idempotent "$COMPILER" clean --manifest-path "$PKG/typelisp.pkg"
assert_success
assert_stdout_empty
assert_stderr_empty
fi

BADPKG="$WORKDIR/badpkg"
mkdir -p "$BADPKG/src"
cat > "$BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "bad_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (deps "not-yet"))
EOF
maybe_strip_manifest_kind "$BADPKG/typelisp.pkg"
run_cmd package-parse-error "$COMPILER" build --manifest-path "$BADPKG/typelisp.pkg"
assert_failure
assert_stdout_empty
assert_contains "$err" 'unknown manifest field `deps`'

cat > "$BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "missing_alias")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
maybe_strip_manifest_kind "$BADPKG/typelisp.pkg"
cat > "$BADPKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 0)
EOF
run_cmd package-missing-alias "$COMPILER" build --manifest-path "$BADPKG/typelisp.pkg"
assert_failure
assert_stdout_empty
assert_contains "$err" "pkg:math/src/lib.tl"
assert_contains_any "$err" 'alias `math`' "unknown package alias 'math'"

WALK_PKG="$WORKDIR/walk_pkg"
mkdir -p "$WALK_PKG/src" "$WALK_PKG/src/nested/deeper"
cat > "$WALK_PKG/typelisp.pkg" <<'EOF'
(package
  (name "walk_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
maybe_strip_manifest_kind "$WALK_PKG/typelisp.pkg"
cat > "$WALK_PKG/src/main.tl" <<'EOF'
(import "math.tl")
(define (main) : i64 (inc 41))
EOF
cat > "$WALK_PKG/src/math.tl" <<'EOF'
(define (inc [x : i64]) : i64 (+ x 1))
EOF
run_cmd_cwd package-discover-upward "$WALK_PKG/src/nested/deeper" "$COMPILER" build
assert_success
assert_stderr_empty
WALK_ASM="$WALK_PKG/target/release/walk_pkg.s"
[ -f "$WALK_ASM" ] || fail "package discover-upward did not write assembly"
assert_contains "$out" "Built "
assert_contains "$WALK_ASM" "main:"
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$WALK_ASM" "inc:"
else
    assert_contains_any "$WALK_ASM" \
        "_tl_inc:" \
        "_tl_math_inc:" \
        "_tl_walk_pkg_src_math_inc"
    assert_contains "$WALK_ASM" "_tl_walk_pkg_src_math_inc"
fi

MISSING_DEP="$WORKDIR/missing_dep"
mkdir -p "$MISSING_DEP/src" "$MISSING_DEP/vendor/math/src"
cat > "$MISSING_DEP/typelisp.pkg" <<'EOF'
(package
  (name "missing_dep_file")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
maybe_strip_manifest_kind "$MISSING_DEP/typelisp.pkg"
cat > "$MISSING_DEP/vendor/math/typelisp.pkg" <<'EOF'
(package
  (name "math")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
maybe_strip_manifest_kind "$MISSING_DEP/vendor/math/typelisp.pkg"
cat > "$MISSING_DEP/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
cat > "$MISSING_DEP/src/main.tl" <<'EOF'
(import "pkg:math/src/missing.tl")
(define (main) : i64 0)
EOF
run_cmd package-missing-dep-file "$COMPILER" build --manifest-path "$MISSING_DEP/typelisp.pkg"
assert_failure
if [ "$IS_STAGE1_WRAPPER" -eq 1 ]; then
    assert_contains "$err" "compiler-load: cannot read import"
else
    assert_contains "$err" "compiler-load: cannot read import"
fi

# Normalize backslashes for Windows path comparison in diagnostic output.
ERR_NORMALIZED="$WORKDIR/missing_dep_err_normalized.tmp"
tr '\\' '/' < "$err" > "$ERR_NORMALIZED"
assert_contains "$ERR_NORMALIZED" "vendor/math/src/missing.tl"
else
    fail "package build coverage requires host-action drivers"
fi

echo "[public-tools] LSP corpus via run-corpus.sh"
if [ "$HAS_LSP_COMMAND" -eq 1 ]; then
    TYPELISP_BIN="$COMPILER" sh "$ROOT/tests/public-tools/run-corpus.sh" lsp
else
    fail "LSP corpus requires the public lsp command"
fi

echo "[public-tools] REPL corpus via run-corpus.sh"
TYPELISP_BIN="$COMPILER" sh "$ROOT/tests/public-tools/run-corpus.sh" repl
if [ "$HOST_OS" = linux ]; then
    :
else
    echo "[public-tools] selfhost REPL scratch smoke on $HOST_OS"
    SELFHOST_REPL_SMOKE="$WORKDIR/selfhost-repl-smoke.in"
    cat > "$SELFHOST_REPL_SMOKE" <<'EOF'
(+ 1 2) ; trailing comment must not swallow generated wrapper delimiters
.exit
EOF
    run_stdin selfhost-repl-scratch-smoke "$SELFHOST_REPL_SMOKE" "$COMPILER" run "$ROOT/selfhost/repl.tl" --stdlib-root "$ROOT/stdlib"
    assert_success
    assert_contains "$out" "3"
    assert_stderr_empty
fi

if [ "$HAS_LSP_COMMAND" -eq 1 ]; then
    echo "[public-tools] LSP (legacy inline checks)"
    frame_append() {
        frame_file=$1
        frame_body=$2
        frame_len=$(printf '%s' "$frame_body" | wc -c | tr -d ' ')
        {
            printf 'Content-Length: %s\r\n\r\n' "$frame_len"
            printf '%s' "$frame_body"
        } >> "$frame_file"
    }

    LSP_IN="$WORKDIR/lsp.in"
    : > "$LSP_IN"
    frame_append "$LSP_IN" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
    frame_append "$LSP_IN" '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
    run_stdin lsp-init-shutdown "$LSP_IN" "$COMPILER" lsp
    assert_success
    assert_stderr_empty
    assert_contains "$out" '"id":1'
    assert_contains "$out" '"capabilities"'
    assert_contains "$out" '"id":2'
else
    fail "legacy LSP inline checks require the public lsp command"
fi

echo "[public-tools] SPEC metadata examples"
SPEC_WORK="$WORKDIR/spec"
mkdir -p "$SPEC_WORK"
SPEC_MANIFEST="$SPEC_WORK/manifest.txt"
awk -v out="$SPEC_WORK" '
function die(msg) {
    print msg > "/dev/stderr"
    exit 1
}
function is_key_char(ch) {
    return ch ~ /^[A-Za-z0-9_-]$/
}
function clear_meta(    key) {
    for (key in meta) {
        delete meta[key]
    }
}
function parse_meta(text, line,    i, n, ch, key, value, closed, esc) {
    clear_meta()
    i = 1
    n = length(text)
    while (i <= n) {
        ch = substr(text, i, 1)
        while (i <= n && ch ~ /^[ \t]$/) {
            i++
            ch = substr(text, i, 1)
        }
        if (i > n) {
            break
        }

        key = ""
        while (i <= n && is_key_char(substr(text, i, 1))) {
            key = key substr(text, i, 1)
            i++
        }
        if (key == "") {
            die("SPEC.md:" line " has malformed metadata near `" substr(text, i) "`")
        }
        if (substr(text, i, 1) != "=") {
            die("SPEC.md:" line " metadata key `" key "` must be followed by `=`")
        }
        i++

        if (substr(text, i, 1) == "\"") {
            i++
            value = ""
            closed = 0
            while (i <= n) {
                ch = substr(text, i, 1)
                if (ch == "\"") {
                    i++
                    closed = 1
                    break
                }
                if (ch == "\\") {
                    i++
                    if (i > n) {
                        die("SPEC.md:" line " has a trailing escape in metadata")
                    }
                    esc = substr(text, i, 1)
                    if (esc == "n") {
                        value = value "\n"
                    } else if (esc == "r") {
                        value = value "\r"
                    } else if (esc == "t") {
                        value = value "\t"
                    } else if (esc == "\"") {
                        value = value "\""
                    } else if (esc == "\\") {
                        value = value "\\"
                    } else {
                        die("SPEC.md:" line " has unsupported metadata escape `\\" esc "`")
                    }
                    i++
                    continue
                }
                value = value ch
                i++
            }
            if (!closed) {
                die("SPEC.md:" line " has an unterminated quoted metadata value")
            }
        } else {
            value = ""
            while (i <= n && substr(text, i, 1) !~ /^[ \t]$/) {
                value = value substr(text, i, 1)
                i++
            }
            if (value == "") {
                die("SPEC.md:" line " metadata key `" key "` has no value")
            }
        }

        if (key in meta) {
            die("SPEC.md:" line " has duplicate metadata key `" key "`")
        }
        meta[key] = value
    }
}
function required(line, example, key,    value) {
    if (!(key in meta)) {
        if (example == "") {
            die("SPEC.md:" line " lisp fence is missing metadata `" key "`")
        }
        die("SPEC.md:" line " example `" example "` is missing required metadata `" key "`")
    }
    value = meta[key]
    delete meta[key]
    return value
}
function reject_remaining(line, name,    key) {
    for (key in meta) {
        die("SPEC.md:" line " example `" name "` has unsupported metadata key `" key "`")
    }
}
function validate_name(line, name) {
    if (name == "" || name !~ /^[A-Za-z0-9_-]+$/) {
        die("SPEC.md:" line " example `" name "` must use only ASCII letters, digits, `-`, or `_`")
    }
}
function finish_example(    mode, name, reason, exit_code, stdout_file, source_file) {
    mode = required(opening_line, "", "test")
    name = required(opening_line, mode, "name")
    validate_name(opening_line, name)
    if (name in seen) {
        die("SPEC.md:" opening_line " example `" name "` duplicates a previous name")
    }
    seen[name] = 1

    if (mode == "ignore") {
        reason = required(opening_line, name, "reason")
        if (reason ~ /^[ \t]*$/) {
            die("SPEC.md:" opening_line " example `" name "` has an empty ignore reason")
        }
        reject_remaining(opening_line, name)
        print name "|ignore|"
        return
    }

    source_file = out "/" name ".tl"
    printf "%s", source > source_file
    close(source_file)

    if (mode == "check" || mode == "compile") {
        reject_remaining(opening_line, name)
        print name "|" mode "|"
        return
    }

    if (mode == "run") {
        exit_code = required(opening_line, name, "exit")
        if (exit_code !~ /^-?[0-9]+$/) {
            die("SPEC.md:" opening_line " example `" name "` has invalid exit code `" exit_code "`")
        }
        stdout_file = out "/" name ".stdout"
        printf "%s", required(opening_line, name, "stdout") > stdout_file
        close(stdout_file)
        reject_remaining(opening_line, name)
        print name "|run|" exit_code
        return
    }

    die("SPEC.md:" opening_line " example `" name "` has unknown test mode `" mode "`")
}
BEGIN {
    in_fence = 0
    in_other_fence = 0
    count = 0
}
{
    trimmed = $0
    sub(/^[ \t]*/, "", trimmed)

    if (in_fence) {
        if (trimmed ~ /^```/) {
            finish_example()
            in_fence = 0
            source = ""
            next
        }
        source = source $0 "\n"
        next
    }

    if (in_other_fence) {
        if (trimmed ~ /^```/) {
            in_other_fence = 0
        }
        next
    }

    if (trimmed ~ /^```lisp([ \t].*)?$/) {
        info = trimmed
        sub(/^```lisp[ \t]*/, "", info)
        if (info == "") {
            die("SPEC.md:" NR " lisp fence is missing test= metadata")
        }
        parse_meta(info, NR)
        opening_line = NR
        source = ""
        in_fence = 1
        count++
        next
    }

    if (trimmed ~ /^```/) {
        in_other_fence = 1
    }
}
END {
    if (in_fence) {
        die("SPEC.md:" opening_line " has an unclosed Markdown fence")
    }
    if (count == 0) {
        die("SPEC.md should contain metadata-bearing lisp examples")
    }
}
' SPEC.md > "$SPEC_MANIFEST"

spec_uses_deferred_runtime_surface() {
    grep -E '(^|[^A-Za-z0-9_-])(print-string|print-error|panic|read-stdin|stdin-eof|arg-count|arg)([^A-Za-z0-9_-]|$)' "$1" > /dev/null
}

while IFS='|' read -r spec_name spec_mode spec_value; do
    [ -n "$spec_name" ] || continue
    case "$spec_mode" in
        ignore)
            ;;
        check)
            run_cmd "spec-$spec_name" "$COMPILER" check "$SPEC_WORK/$spec_name.tl"
            assert_success
            ;;
        compile)
            run_cmd "spec-$spec_name" "$COMPILER" compile "$SPEC_WORK/$spec_name.tl" -o "$SPEC_WORK/$spec_name.s"
            assert_success
            ;;
        run)
            if [ "$HOST_ACTION_ENABLED" -eq 0 ]; then
                fail "SPEC run example $spec_name requires host-action drivers"
            fi
            run_cmd "spec-$spec_name" "$COMPILER" run "$SPEC_WORK/$spec_name.tl"
            assert_code "$spec_value"
            check_text_file_exact "$out" "$SPEC_WORK/$spec_name.stdout"
            assert_stderr_empty
            ;;
        *)
            fail "unknown SPEC manifest mode for $spec_name: $spec_mode"
            ;;
    esac
done < "$SPEC_MANIFEST"

echo "public tool verification passed"
