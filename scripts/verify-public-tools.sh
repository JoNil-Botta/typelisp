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
# Default 6 (not 3): this gate runs many CLI invocations, so the #1204 Windows
# segfault can exhaust 3 attempts on one of them (observed on PR #1249:
# inline-test-fail crashed 134/134/segfault); more headroom keeps the
# crash-only retry effective.
PUBLIC_TOOLS_ATTEMPTS="${VERIFY_PUBLIC_TOOLS_ATTEMPTS:-6}"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "public tool verification is unsupported on this host" >&2
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

WORKDIR="$ROOT/target/public-tool-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
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
        "$@" > "$out" 2> "$err"
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
        (cd "$cwd" && "$@") > "$out" 2> "$err"
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
        "$@" < "$input_file" > "$out" 2> "$err"
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

assert_contains() {
    file=$1
    text=$2
    if ! grep -F -- "$text" "$file" > /dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$case_name missing expected text: $text"
    fi
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

build_linux_cli_tool() {
    _case=$1
    _source=$2
    _output=$3
    _asm="$_output.s"
    _obj="$_output.o"

    run_cmd "$_case-compile" "$COMPILER" compile "$_source" --stdlib-root "$ROOT/stdlib" -o "$_asm"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Generated:"
    run_cmd "$_case-assemble" as "$_asm" -o "$_obj"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    run_cmd "$_case-link" ld "$_obj" -o "$_output" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc
    assert_success
    assert_stdout_empty
    assert_stderr_empty
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
assert_contains "$err" "typelisp repl"
assert_contains "$err" "typelisp lsp"
assert_contains "$err" "typelisp fmt"
if grep -q "typelisp lint" "$err"; then
    HAS_LINT_COMMAND=1
else
    HAS_LINT_COMMAND=0
fi
assert_contains "$err" "typelisp doc"

run_cmd missing-command "$COMPILER"
assert_failure
assert_stdout_empty
assert_contains "$err" "Usage:"

run_cmd tokenize-alias "$COMPILER" tokenize examples/hello.tl
assert_success
assert_stderr_empty
cp "$out" "$WORKDIR/tokenize-alias.expected"

run_cmd tokenize-debug "$COMPILER" debug tokenize examples/hello.tl
assert_success
assert_stderr_empty
cmp -s "$out" "$WORKDIR/tokenize-alias.expected" || fail "debug tokenize differs from public alias"
assert_contains "$out" "("
assert_contains "$out" "define"

run_cmd parse-alias "$COMPILER" parse examples/hello.tl
assert_success
assert_stderr_empty
cp "$out" "$WORKDIR/parse-alias.expected"

run_cmd parse-debug "$COMPILER" debug parse examples/hello.tl
assert_success
assert_stderr_empty
cmp -s "$out" "$WORKDIR/parse-alias.expected" || fail "debug parse differs from public alias"
assert_contains "$out" "Program"

run_cmd check-hello "$COMPILER" check examples/hello.tl
assert_success
assert_stderr_empty
assert_contains "$out" "Type checking passed!"

run_cmd compile-hello "$COMPILER" compile examples/hello.tl -o "$WORKDIR/hello.s"
assert_success
assert_stderr_empty
assert_contains "$out" "Generated:"
assert_contains "$WORKDIR/hello.s" "main:"

run_cmd bad-target "$COMPILER" compile examples/hello.tl --target definitely-not-a-target -o "$WORKDIR/bad-target.s"
assert_failure
assert_stdout_empty
assert_contains "$err" "unknown target"

run_cmd debug-missing "$COMPILER" debug
assert_failure
assert_stdout_empty
assert_contains "$err" "Error: missing debug subcommand"
assert_contains "$err" "typelisp debug tokenize <file.tl>"

run_cmd debug-unknown "$COMPILER" debug wat
assert_failure
assert_stdout_empty
assert_contains "$err" "Unknown debug command: wat"
assert_contains "$err" "typelisp debug check <file.tl>"

DEBUG_CHECK="$WORKDIR/debug-check"
mkdir -p "$DEBUG_CHECK/app" "$DEBUG_CHECK/repo-stdlib"
cat > "$DEBUG_CHECK/repo-stdlib/helper.tl" <<'EOF'
(define (helper) : i64 42)
EOF
cat > "$DEBUG_CHECK/app/main.tl" <<'EOF'
(import "stdlib/helper.tl")
(define (main) : i64 (helper))
EOF
run_cmd check-stdlib-root "$COMPILER" check "$DEBUG_CHECK/app/main.tl" --stdlib-root "$DEBUG_CHECK/repo-stdlib"
assert_success
assert_stderr_empty
cp "$out" "$WORKDIR/check-stdlib-root.expected"
run_cmd debug-check-stdlib-root "$COMPILER" debug check "$DEBUG_CHECK/app/main.tl" --stdlib-root "$DEBUG_CHECK/repo-stdlib"
assert_success
assert_stderr_empty
cmp -s "$out" "$WORKDIR/check-stdlib-root.expected" || fail "debug check differs from public check"
assert_contains "$out" "Type checking passed!"

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
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Generated:"
    assert_contains "$mode_dir/main.s" "main:"
    if [ "$mode" = avx2 ]; then
        assert_contains "$mode_dir/main.s" "vzeroupper"
    fi
done <<EOF
$(compile_backend_modes)
EOF

for target_alias in windows-x86_64 windows_x86_64; do
    target_dir="$CLI_MATRIX/target-$target_alias"
    mkdir -p "$target_dir"
    cat > "$target_dir/main.tl" <<'EOF'
(define (main) : i64
  (begin
    (print-string "hi")
    42))
EOF
    run_cmd "compile-target-$target_alias" "$COMPILER" compile "$target_dir/main.tl" --target "$target_alias" -o "$target_dir/main.s"
    assert_success
    assert_stderr_empty
    assert_contains "$target_dir/main.s" "    .globl main"
    assert_not_contains "$target_dir/main.s" "    .globl _start"
    assert_contains "$target_dir/main.s" "    .extern _write"
    assert_contains "$target_dir/main.s" '    sub $32, %rsp'
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
assert_contains "$err" "build: unknown target plan9-x86_64"

run_cmd run-unknown-target "$COMPILER" run "$CLI_MATRIX/main.tl" --target plan9-x86_64
assert_failure
assert_stdout_empty
assert_contains "$err" "run: unknown target plan9-x86_64"

run_cmd compile-unknown-backend-mode "$COMPILER" compile "$CLI_MATRIX/main.tl" --backend-mode neon
assert_failure
assert_stdout_empty
assert_contains "$err" "Error: unknown backend mode 'neon'. Expected scalar, avx2, or avx512"

run_cmd build-unknown-backend-mode "$COMPILER" build "$CLI_MATRIX/main.tl" --backend-mode neon
assert_failure
assert_stdout_empty
assert_contains "$err" "build: unknown backend mode neon"

run_cmd run-unknown-backend-mode "$COMPILER" run "$CLI_MATRIX/main.tl" --backend-mode neon
assert_failure
assert_stdout_empty
assert_contains "$err" "run: unknown backend mode neon"

cat > "$CLI_MATRIX/unsupported-type-kind.tl" <<'EOF'
(define (f [T : type]) : i64 0)
EOF
run_cmd check-unsupported-type-kind "$COMPILER" check "$CLI_MATRIX/unsupported-type-kind.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "unsupported type kind 'type'"
assert_contains "$err" "comptime type values are not implemented yet"
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
(define (main) : String
  (with-arena r (int->string 41)))
EOF
run_cmd check-region-builtin-escape "$COMPILER" check "$CLI_MATRIX/region-builtin-escape.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "region-tagged value"
assert_contains "$err" "cannot escape with-arena"
assert_contains "$err" "error[E0200]"

cat > "$CLI_MATRIX/stdlib-region-escape.tl" <<'EOF'
(import "stdlib/string.tl")

(define (main) : String
  (with-arena outer
    (with-arena inner
      (string-trim "  scoped  "))))
EOF
run_cmd check-stdlib-region-escape "$COMPILER" check "$CLI_MATRIX/stdlib-region-escape.tl" --stdlib-root "$ROOT/stdlib"
assert_failure
assert_stdout_empty
assert_contains "$err" "region-tagged value"
assert_contains "$err" "cannot escape with-arena 'inner'"
assert_contains "$err" "error[E0200]"

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
assert_contains "$err" "error[E0200]"

cat > "$CLI_MATRIX/unsupported-float-cast.tl" <<'EOF'
(define (main) : i64 (cast 3.5 : i64))
EOF
run_cmd check-unsupported-float-cast "$COMPILER" check "$CLI_MATRIX/unsupported-float-cast.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "floating-point casts are not supported yet"
assert_contains "$err" "casts currently support integer/char and f64<->f32 conversions only"
assert_contains "$err" "got f64 -> i64"
assert_contains "$err" "error[E0200]"

cat > "$CLI_MATRIX/inexact-f32-literal.tl" <<'EOF'
(define (main) : f32 0.1)
EOF
run_cmd check-inexact-f32-literal "$COMPILER" check "$CLI_MATRIX/inexact-f32-literal.tl"
assert_success
assert_contains "$out" "Type checking passed!"
assert_contains "$err" "warning[W0200]"
assert_contains "$err" "not exactly representable as f32"

RUN_MATRIX="$WORKDIR/run-matrix"
mkdir -p "$RUN_MATRIX"
cat > "$RUN_MATRIX/output_status.tl" <<'EOF'
(define (main) : i64
  (begin
    (print-string "hello")
    7))
EOF
run_cmd run-output-status "$COMPILER" run "$RUN_MATRIX/output_status.tl"
assert_code 7
assert_stderr_empty
assert_contains "$out" "hello"

cat > "$RUN_MATRIX/stdin.tl" <<'EOF'
(define (main) : unit
  (print-string (read-stdin-line)))
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
# Linux public `run`/`build` route through the selfhost source tools, so
# non-scalar modes stay rejected until those tools can delegate to the Rust SIMD
# driver or implement selfhost SIMD support (#1014). Windows still uses the
# Rust-backed public path and keeps CPU-gated execution coverage.
SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh" 2>/dev/null || true)
run_backend_mode_exec() {
    # $1 = backend mode (avx2|avx512); $2 = required ISA token (avx2|avx512f)
    if [ "$HOST_OS" = linux ]; then
        run_cmd "run-backend-$1-rejected" "$COMPILER" run "$CLI_MATRIX/main.tl" --backend-mode "$1" -- arg
        assert_failure
        assert_stdout_empty
        assert_contains "$err" "run: --backend-mode $1 requires the Rust run driver until selfhost SIMD support (#1014)"
        return
    fi
    if printf '%s\n' "$SIMD_ISAS" | grep -qx "$2"; then
        run_cmd "run-backend-$1" "$COMPILER" run "$CLI_MATRIX/main.tl" --backend-mode "$1" -- arg
        assert_code 42
        assert_stdout_empty
        assert_stderr_empty
    else
        echo "[public-tools] skipping run --backend-mode $1 ($2 not available on this $HOST_OS host)"
    fi
}
run_backend_mode_exec avx2 avx2
run_backend_mode_exec avx512 avx512f

# The scalar SPMD source remains an always-run reference. On Linux, non-scalar
# `run` modes are rejected at the source-tool boundary for now. On Windows, keep
# CPU-gated SIMD execution coverage for the Rust-backed path.
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
    if [ "$2" != "-" ] && [ "$HOST_OS" != linux ] && ! printf '%s\n' "$SIMD_ISAS" | grep -qx "$2"; then
        echo "[public-tools] skipping spmd-exec --backend-mode $1 ($2 not available on this $HOST_OS host)"
        return
    fi
    run_cmd "spmd-exec-$1" "$COMPILER" run "$SPMD_EXEC/spmd.tl" --backend-mode "$1" -- arg
    if [ "$1" = scalar ]; then
        assert_code 190
        assert_stdout_empty
        assert_stderr_empty
    elif [ "$HOST_OS" = linux ]; then
        assert_failure
        assert_stdout_empty
        assert_contains "$err" "run: --backend-mode $1 requires the Rust run driver until selfhost SIMD support (#1014)"
    else
        assert_code 190
        assert_stdout_empty
        assert_stderr_empty
    fi
}
run_spmd_exec_mode scalar -
run_spmd_exec_mode avx2 avx2
run_spmd_exec_mode avx512 avx512f

BUILD_MATRIX="$WORKDIR/build-matrix"
mkdir -p "$BUILD_MATRIX/src"
cat > "$BUILD_MATRIX/typelisp.pkg" <<'EOF'
(package
  (name "backend_mode_build")
  (version "0.1.0")
  (entry "src/main.tl"))
EOF
cat > "$BUILD_MATRIX/src/main.tl" <<'EOF'
(define (main) : i64 42)
EOF
run_cmd build-package-avx512 "$COMPILER" build --manifest-path "$BUILD_MATRIX/typelisp.pkg" --backend-mode avx512
assert_success
assert_stderr_empty
assert_contains "$out" "Generated:"

run_cmd build-source-missing-output-value "$COMPILER" build "$CLI_MATRIX/main.tl" -o
assert_failure
assert_stdout_empty
assert_contains "$err" "build: -o requires a value"

run_cmd build-output-without-source "$COMPILER" build -o "$BUILD_MATRIX/app"
assert_failure
assert_stdout_empty
assert_contains "$err" "Error: build -o requires a source file argument"

run_cmd build-source-missing-file "$COMPILER" build "$BUILD_MATRIX/missing.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "cannot read module"

echo "[public-tools] host-action boundary"
printf 'not a plan\n' > "$WORKDIR/host-action-invalid.in"
run_stdin host-action-invalid "$WORKDIR/host-action-invalid.in" "$COMPILER" debug host-action
assert_code 1
assert_stdout_empty
assert_contains "$err" "invalid host-action plan"

HOST_ACTION_DIR="$WORKDIR/host action"
mkdir -p "$HOST_ACTION_DIR"
cat > "$HOST_ACTION_DIR/main.tl" <<'EOF'
(define (main) : i64 11)
EOF
if [ "$HOST_OS" = windows ]; then
    HOST_ACTION_TARGET=windows-x86_64
    HOST_ACTION_EXE="$HOST_ACTION_DIR/the program.exe"
else
    HOST_ACTION_TARGET=linux-x86_64
    HOST_ACTION_EXE="$HOST_ACTION_DIR/the program"
fi
HOST_ACTION_SOURCE_PLAN=$(host_plan_path "$HOST_ACTION_DIR/main.tl")
HOST_ACTION_EXE_PLAN=$(host_plan_path "$HOST_ACTION_EXE")
{
    printf 'typelisp-host-plan v1\n'
    printf 'action build-source\n'
    printf 'source %s\n' "$(host_netstring "$HOST_ACTION_SOURCE_PLAN")"
    printf 'output %s\n' "$(host_netstring "$HOST_ACTION_EXE_PLAN")"
    printf 'target %s\n' "$HOST_ACTION_TARGET"
    printf 'backend-mode scalar\n'
    printf 'end\n'
} > "$WORKDIR/host-action-build.in"
run_stdin host-action-build "$WORKDIR/host-action-build.in" "$COMPILER" debug host-action
assert_success
assert_contains "$out" "Generated: $HOST_ACTION_EXE_PLAN"
[ -f "$HOST_ACTION_EXE" ] || fail "host-action build did not write executable with spaced path"

cat > "$HOST_ACTION_DIR/run.tl" <<'EOF'
(define (main) : i64
  (begin
    (print-string "from-plan")
    13))
EOF
HOST_ACTION_RUN_SOURCE_PLAN=$(host_plan_path "$HOST_ACTION_DIR/run.tl")
{
    printf 'typelisp-host-plan v1\n'
    printf 'action run-source\n'
    printf 'source %s\n' "$(host_netstring "$HOST_ACTION_RUN_SOURCE_PLAN")"
    printf 'target %s\n' "$HOST_ACTION_TARGET"
    printf 'backend-mode scalar\n'
    printf 'runtime-arg %s\n' "$(host_netstring "arg with spaces")"
    printf 'end\n'
} > "$WORKDIR/host-action-run.in"
run_stdin host-action-run "$WORKDIR/host-action-run.in" "$COMPILER" debug host-action
assert_code 13
assert_stderr_empty
assert_contains "$out" "from-plan"

if [ "$HOST_OS" = linux ]; then
    SELFHOST_PLANNER_DIR="$WORKDIR/selfhost-planners"
    mkdir -p "$SELFHOST_PLANNER_DIR/with space" "$SELFHOST_PLANNER_DIR/stdlib one"
    command -v as >/dev/null 2>&1 || fail "missing assembler: as"
    command -v ld >/dev/null 2>&1 || fail "missing linker: ld"
    build_linux_cli_tool selfhost-build-tool selfhost/build.tl "$SELFHOST_PLANNER_DIR/build-tool"
    build_linux_cli_tool selfhost-run-tool selfhost/run.tl "$SELFHOST_PLANNER_DIR/run-tool"

    PLANNER_SOURCE="$SELFHOST_PLANNER_DIR/with space/main file.tl"
    PLANNER_OUTPUT="$SELFHOST_PLANNER_DIR/with space/the program"
    cat > "$PLANNER_SOURCE" <<'EOF'
(define (main) : i64 23)
EOF
    run_cmd selfhost-build-tool "$SELFHOST_PLANNER_DIR/build-tool" --direct "$PLANNER_SOURCE" -o "$PLANNER_OUTPUT" --target linux-x86_64 --backend-mode scalar
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Generated: $PLANNER_OUTPUT"
    [ -f "$PLANNER_OUTPUT" ] || fail "selfhost build tool did not write executable"
    run_cmd selfhost-build-tool-output "$PLANNER_OUTPUT"
    assert_code 23
    assert_stderr_empty

    run_cmd selfhost-build-tool-avx2-rejected "$SELFHOST_PLANNER_DIR/build-tool" --direct "$PLANNER_SOURCE" -o "$SELFHOST_PLANNER_DIR/with space/avx2 program" --target linux-x86_64 --backend-mode avx2
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: --backend-mode avx2 requires the Rust build driver until selfhost SIMD support (#1014)"

    PLANNER_RUN_SOURCE="$SELFHOST_PLANNER_DIR/with space/run file.tl"
    cat > "$PLANNER_RUN_SOURCE" <<'EOF'
(define (main) : i64
  (begin
    (print-string (arg 1))
    (if (string-eq (arg 2) "colon:arg") 13 2)))
EOF
    run_cmd selfhost-run-tool "$SELFHOST_PLANNER_DIR/run-tool" --direct "$PLANNER_RUN_SOURCE" --target linux-x86_64 --backend-mode scalar --stdlib-root "$ROOT/stdlib" -- "arg with spaces" "colon:arg"
    assert_code 13
    assert_stderr_empty
    assert_contains "$out" "arg with spaces"

    run_cmd selfhost-run-tool-avx512-rejected "$SELFHOST_PLANNER_DIR/run-tool" --direct "$PLANNER_RUN_SOURCE" --target linux-x86_64 --backend-mode avx512 --stdlib-root "$ROOT/stdlib" -- "arg with spaces" "colon:arg"
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "run: --backend-mode avx512 requires the Rust run driver until selfhost SIMD support (#1014)"

    SELFHOST_PKG="$SELFHOST_PLANNER_DIR/pkg"
    mkdir -p "$SELFHOST_PKG/src/nested/deeper" "$SELFHOST_PKG/vendor/math/src"
    cat > "$SELFHOST_PKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_pkg")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
    cat > "$SELFHOST_PKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 (add-one 41))
EOF
    cat > "$SELFHOST_PKG/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
    run_cmd selfhost-build-package "$SELFHOST_PLANNER_DIR/build-tool" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --opt-level 0
    assert_success
    assert_stderr_empty
    SELFHOST_PKG_ASM="$SELFHOST_PKG/target/typelisp/selfhost_pkg/selfhost_pkg.s"
    [ -f "$SELFHOST_PKG_ASM" ] || fail "selfhost package build did not write assembly"
    assert_contains "$out" "Generated: $SELFHOST_PKG_ASM"
    assert_contains "$SELFHOST_PKG_ASM" "main:"
    assert_contains "$SELFHOST_PKG_ASM" "add_one"

    rm -rf "$SELFHOST_PKG/target"
    run_cmd_cwd selfhost-build-package-discover "$SELFHOST_PKG/src/nested/deeper" "$SELFHOST_PLANNER_DIR/build-tool"
    assert_success
    assert_stderr_empty
    [ -f "$SELFHOST_PKG_ASM" ] || fail "selfhost package discovery did not write assembly"
    assert_contains "$out" "Generated:"

    SELFHOST_BADPKG="$SELFHOST_PLANNER_DIR/badpkg"
    mkdir -p "$SELFHOST_BADPKG/src" "$SELFHOST_BADPKG/vendor/math"
    cat > "$SELFHOST_BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_parse_error")
  (version "0.1.0")
  (entry "src/main.tl")
  (deps "not-yet"))
EOF
    run_cmd selfhost-build-package-parse-error "$SELFHOST_PLANNER_DIR/build-tool" --direct --manifest-path "$SELFHOST_BADPKG/typelisp.pkg"
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "invalid package manifest"
    assert_contains "$err" 'unknown manifest field `deps`'

    cat > "$SELFHOST_BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_bad_pkg")
  (version "0.1.0")
  (entry "src/main.tl"))
EOF
    cat > "$SELFHOST_BADPKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 0)
EOF
    run_cmd selfhost-build-package-missing-alias "$SELFHOST_PLANNER_DIR/build-tool" --direct --manifest-path "$SELFHOST_BADPKG/typelisp.pkg"
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "compiler-load: unknown package alias 'math'"
    assert_contains "$err" "pkg:math/src/lib.tl"

    cat > "$SELFHOST_BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_missing_dep")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
    cat > "$SELFHOST_BADPKG/src/main.tl" <<'EOF'
(import "pkg:math/src/missing.tl")
(define (main) : i64 0)
EOF
    run_cmd selfhost-build-package-missing-dep "$SELFHOST_PLANNER_DIR/build-tool" --direct --manifest-path "$SELFHOST_BADPKG/typelisp.pkg"
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "compiler-load: cannot read import"
    assert_contains "$err" "vendor/math/src/missing.tl"

    run_cmd selfhost-build-package-opt-duplicate "$SELFHOST_PLANNER_DIR/build-tool" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --opt-level 1 --opt-level 2
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: --opt-level was provided more than once"

    run_cmd selfhost-build-package-opt-invalid "$SELFHOST_PLANNER_DIR/build-tool" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --opt-level 9
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: unknown opt level '9'; expected 0, 1, 2, or 3"

    run_cmd selfhost-build-package-mode-staged "$SELFHOST_PLANNER_DIR/build-tool" --direct --manifest-path "$SELFHOST_PKG/typelisp.pkg" --backend-mode avx2
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "build: --backend-mode avx2 requires the Rust build driver"

    run_cmd selfhost-run-tool-missing-target "$SELFHOST_PLANNER_DIR/run-tool" --direct "$PLANNER_SOURCE" --target
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "run: --target requires a value"
else
    echo "[public-tools] skipping selfhost build/run tool executables on $HOST_OS"
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

    run_cmd lint-missing "$COMPILER" lint
    assert_failure
    assert_stdout_empty
    assert_contains "$err" "Error: missing file argument"
    assert_contains "$err" "typelisp lint <file.tl>"
else
    echo "[public-tools] SKIP lint command (compiler predates public lint CLI)"
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
;;;; Module docs.
;;;; ```typelisp
;;;; (define (main) : i64 42)
;;;; ```

;;; Item docs.
;;; ```tl
;;; (define answer : i64 42)
;;; ```
(define documented : i64 1)
EOF
run_cmd doc-test-pass "$COMPILER" doc --test "$WORKDIR/docs.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 2 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs.tl"

cat > "$WORKDIR/docs_expected_error.tl" <<'EOF'
;;;; Expected error.
;;;; ```typelisp expect-error
;;;; (define (bad) : i64 true)
;;;; ```
EOF
run_cmd doc-test-expected-error "$COMPILER" doc --test "$WORKDIR/docs_expected_error.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 1 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs_expected_error.tl"

cat > "$WORKDIR/docs_malformed.tl" <<'EOF'
;;;; Bad fence.
;;;; ```typelisp maybe
;;;; (define (main) : i64 0)
;;;; ```
EOF
run_cmd doc-test-malformed "$COMPILER" doc --test "$WORKDIR/docs_malformed.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" 'unsupported TypeLisp doctest option `maybe`'
assert_doctest_temp_cleaned "$WORKDIR/docs_malformed.tl"

cat > "$WORKDIR/docs_empty.tl" <<'EOF'
;;;; Docs without fenced examples.
;;; Item docs without fenced examples.
(define documented : i64 1)
EOF
run_cmd doc-test-empty "$COMPILER" doc --test "$WORKDIR/docs_empty.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 0 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs_empty.tl"

DOC_STDLIB_ROOT="$WORKDIR/doc-test-stdlib-root/repo-stdlib"
mkdir -p "$DOC_STDLIB_ROOT"
cat > "$DOC_STDLIB_ROOT/docfixture.tl" <<'EOF'
(define stdlib-answer : i64 42)
EOF
cat > "$WORKDIR/docs_stdlib_root.tl" <<'EOF'
;;;; Stdlib import example.
;;;; ```typelisp
;;;; (import "stdlib/docfixture.tl")
;;;; (define (main) : i64 stdlib-answer)
;;;; ```
EOF
run_cmd doc-test-stdlib-root "$COMPILER" doc --test "$WORKDIR/docs_stdlib_root.tl" --stdlib-root "$DOC_STDLIB_ROOT"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 1 example(s)"
assert_doctest_temp_cleaned "$WORKDIR/docs_stdlib_root.tl"

cat > "$WORKDIR/docs_bad.tl" <<'EOF'
;;;; Unexpected error.
;;;; ```typelisp
;;;; (define (bad) : i64 true)
;;;; ```
EOF
run_cmd doc-test-unexpected-error "$COMPILER" doc --test "$WORKDIR/docs_bad.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "doc tests failed"
assert_contains "$err" "was expected to pass"
assert_contains "$err" "error[E0200]"
assert_doctest_temp_cleaned "$WORKDIR/docs_bad.tl"

run_cmd doc-usage-missing "$COMPILER" doc
assert_failure
assert_stdout_empty
assert_contains "$err" "Usage:"
assert_contains "$err" "typelisp doc <file.tl>"
assert_contains "$err" "typelisp doc --test <file.tl>"

run_cmd doc-test-usage-missing "$COMPILER" doc --test
assert_failure
assert_stdout_empty
assert_contains "$err" "Usage:"
assert_contains "$err" "typelisp doc --test <file.tl>"

if [ "$HOST_OS" = linux ]; then
    cat > "$WORKDIR/doc_source.tl" <<'EOF'
;;;; Module docs.

;;; Item docs.
(define answer : i64 42)
EOF
    run_cmd doc-generate "$COMPILER" doc "$WORKDIR/doc_source.tl" -o "$WORKDIR/doc_source.md"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Generated:"
    assert_contains "$WORKDIR/doc_source.md" "Module docs."
    assert_contains "$WORKDIR/doc_source.md" "answer"

    DOC_CUSTOM_DIR="$WORKDIR/custom-doc-output"
    mkdir -p "$DOC_CUSTOM_DIR"
    cat > "$WORKDIR/doc_custom_input.tl" <<'EOF'
;;; Single item.
(define x : i64 1)
EOF
    run_cmd doc-generate-custom "$COMPILER" doc "$WORKDIR/doc_custom_input.tl" -o "$DOC_CUSTOM_DIR/custom.md"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Generated: $DOC_CUSTOM_DIR/custom.md"
    assert_contains "$DOC_CUSTOM_DIR/custom.md" "x"

    DOC_GRAPH_DIR="$WORKDIR/doc-module-graph"
    DOC_GRAPH_STDLIB="$DOC_GRAPH_DIR/repo-stdlib"
    DOC_GRAPH_LOCAL="$DOC_GRAPH_DIR/local.tl"
    DOC_GRAPH_STDLIB_SOURCE="$DOC_GRAPH_STDLIB/docfixture.tl"
    DOC_GRAPH_ENTRY="$DOC_GRAPH_DIR/entry.tl"
    DOC_GRAPH_OUT="$DOC_GRAPH_DIR/graph.md"
    mkdir -p "$DOC_GRAPH_STDLIB"
    cat > "$DOC_GRAPH_LOCAL" <<'EOF'
;;;; Local module docs.

;;; Local answer docs.
(define local-answer : i64 7)
EOF
    cat > "$DOC_GRAPH_STDLIB_SOURCE" <<'EOF'
;;;; Stdlib module docs.

;;; Stdlib answer docs.
(define stdlib-answer : i64 35)
EOF
    cat > "$DOC_GRAPH_ENTRY" <<'EOF'
;;;; Entry module docs.

(import "local.tl")
(import "local.tl")
(import "stdlib/docfixture.tl")

;;; Entry docs.
(define (main) : i64 (+ local-answer stdlib-answer))
EOF
    run_cmd doc-generate-module-graph "$COMPILER" doc "$DOC_GRAPH_ENTRY" -o "$DOC_GRAPH_OUT" --stdlib-root "$DOC_GRAPH_STDLIB"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Generated: $DOC_GRAPH_OUT"

    DOC_GRAPH_ENTRY_PATH=$(CDPATH= cd -- "$(dirname -- "$DOC_GRAPH_ENTRY")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$DOC_GRAPH_ENTRY")")
    DOC_GRAPH_LOCAL_PATH=$(CDPATH= cd -- "$(dirname -- "$DOC_GRAPH_LOCAL")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$DOC_GRAPH_LOCAL")")
    DOC_GRAPH_STDLIB_PATH=$(CDPATH= cd -- "$(dirname -- "$DOC_GRAPH_STDLIB_SOURCE")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$DOC_GRAPH_STDLIB_SOURCE")")
    assert_contains "$DOC_GRAPH_OUT" "## Modules"
    assert_contains "$DOC_GRAPH_OUT" "- [$DOC_GRAPH_ENTRY_PATH](#"
    assert_contains "$DOC_GRAPH_OUT" "Source: \`$DOC_GRAPH_LOCAL_PATH\`"
    assert_contains "$DOC_GRAPH_OUT" "Source: \`$DOC_GRAPH_STDLIB_PATH\`"
    assert_contains "$DOC_GRAPH_OUT" "Entry module docs."
    assert_contains "$DOC_GRAPH_OUT" "Local module docs."
    assert_contains "$DOC_GRAPH_OUT" "Stdlib module docs."
    DOC_GRAPH_LOCAL_DOCS=$(grep -F "Local module docs." "$DOC_GRAPH_OUT" | wc -l | tr -d ' ')
    [ "$DOC_GRAPH_LOCAL_DOCS" -eq 1 ] || fail "doc module graph duplicated local docs"
    DOC_GRAPH_ENTRY_LINE=$(grep -nF "## $DOC_GRAPH_ENTRY_PATH" "$DOC_GRAPH_OUT" | head -n 1 | cut -d: -f1)
    DOC_GRAPH_LOCAL_LINE=$(grep -nF "## $DOC_GRAPH_LOCAL_PATH" "$DOC_GRAPH_OUT" | head -n 1 | cut -d: -f1)
    DOC_GRAPH_STDLIB_LINE=$(grep -nF "## $DOC_GRAPH_STDLIB_PATH" "$DOC_GRAPH_OUT" | head -n 1 | cut -d: -f1)
    [ "$DOC_GRAPH_ENTRY_LINE" -lt "$DOC_GRAPH_LOCAL_LINE" ] &&
        [ "$DOC_GRAPH_LOCAL_LINE" -lt "$DOC_GRAPH_STDLIB_LINE" ] ||
        fail "doc module graph did not preserve loader source order"

    DOC_TOOL="$WORKDIR/selfhost-doc-tool"
    build_linux_cli_tool selfhost-doc-tool selfhost/doc.tl "$DOC_TOOL"
    run_cmd doc-generate-html "$DOC_TOOL" --html "$WORKDIR/doc_source.tl" "$WORKDIR/doc_source.html"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    assert_contains "$WORKDIR/doc_source.html" "<!doctype html>"
    assert_contains "$WORKDIR/doc_source.html" "typelisp-docs.css"
    assert_contains "$WORKDIR/doc_source.html" "id=\"tl-answer\""
    assert_contains "$WORKDIR/doc_source.html" "<code class=\"language-typelisp\">(define answer : i64 42)</code>"
else
    echo "[public-tools] skipping doc generation on $HOST_OS"
fi

echo "[public-tools] inline test command"
cat > "$WORKDIR/inline_test_pass.tl" <<'EOF'
(import "stdlib/test.tl")

(define (inc [x : i64]) : i64 (+ x 1))

(define (main) : i64 0)

(test inc-basic
  (assert-i64-eq (inc 41) 42 "inc result"))
EOF

run_cmd inline-test-check "$COMPILER" test --check "$WORKDIR/inline_test_pass.tl" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "TypeLisp test typecheck passed: 1 test(s)"

run_cmd inline-test-pass "$COMPILER" test "$WORKDIR/inline_test_pass.tl" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stdout_empty
assert_contains "$err" "test inc-basic"
assert_contains "$err" "ok inc-basic"
assert_contains "$err" "TypeLisp tests passed: 1 test(s)"
[ ! -f "$WORKDIR/inline_test_pass.tl.test.s" ] || fail "typelisp test left scratch assembly behind"

run_cmd inline-test-normal-compile "$COMPILER" compile "$WORKDIR/inline_test_pass.tl" -o "$WORKDIR/inline_test_pass.s" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "Generated:"
assert_not_contains "$WORKDIR/inline_test_pass.s" "__tl_inline_test"

cat > "$WORKDIR/inline_test_fail.tl" <<'EOF'
(import "stdlib/test.tl")

(test failing-case
  (assert-i64-eq 1 2 "inline failure message"))
EOF

run_cmd inline-test-fail "$COMPILER" test "$WORKDIR/inline_test_fail.tl" --stdlib-root "$ROOT/stdlib"
assert_failure
assert_stdout_empty
assert_contains "$err" "test failing-case"
assert_contains "$err" "inline failure message"
assert_contains "$err" "typelisp test: test executable exited"
[ ! -f "$WORKDIR/inline_test_fail.tl.test.s" ] || fail "failing typelisp test left scratch assembly behind"

run_cmd inline-test-no-tests-check "$COMPILER" test --check "$ROOT/stdlib/windows_setup.tl" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stderr_empty
assert_contains "$out" "TypeLisp test typecheck passed: 0 test(s)"

rm -f "$ROOT/stdlib/windows_setup.tl.test.s"
run_cmd inline-test-no-tests-run "$COMPILER" test "$ROOT/stdlib/windows_setup.tl" --stdlib-root "$ROOT/stdlib"
assert_success
assert_stdout_empty
assert_contains "$err" "TypeLisp tests passed: 0 test(s)"
[ ! -f "$ROOT/stdlib/windows_setup.tl.test.s" ] || fail "no-test typelisp test left scratch assembly behind"

echo "[public-tools] package build"
PKG="$WORKDIR/pkg"
mkdir -p "$PKG/src" "$PKG/vendor/math/src"
cat > "$PKG/typelisp.pkg" <<'EOF'
(package
  (name "public_tool_pkg")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
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
run_cmd package-build "$COMPILER" build --manifest-path "$PKG/typelisp.pkg"
assert_success
assert_stderr_empty
PKG_ASM="$PKG/target/typelisp/public_tool_pkg/public_tool_pkg.s"
[ -f "$PKG_ASM" ] || fail "package build did not write deterministic assembly"
assert_contains "$out" "Generated:"
assert_contains "$PKG_ASM" "main:"
assert_contains "$PKG_ASM" "_tl_inc:"
assert_contains "$PKG_ASM" "_tl_add_one:"

BADPKG="$WORKDIR/badpkg"
mkdir -p "$BADPKG/src"
cat > "$BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "bad_pkg")
  (version "0.1.0")
  (entry "src/main.tl")
  (deps "not-yet"))
EOF
run_cmd package-parse-error "$COMPILER" build --manifest-path "$BADPKG/typelisp.pkg"
assert_failure
assert_stdout_empty
assert_contains "$err" 'unknown manifest field `deps`'

cat > "$BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "missing_alias")
  (version "0.1.0")
  (entry "src/main.tl"))
EOF
cat > "$BADPKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 0)
EOF
run_cmd package-missing-alias "$COMPILER" build --manifest-path "$BADPKG/typelisp.pkg"
assert_failure
assert_stdout_empty
assert_contains "$err" "pkg:math/src/lib.tl"
assert_contains "$err" 'alias `math`'

WALK_PKG="$WORKDIR/walk_pkg"
mkdir -p "$WALK_PKG/src" "$WALK_PKG/src/nested/deeper"
cat > "$WALK_PKG/typelisp.pkg" <<'EOF'
(package
  (name "walk_pkg")
  (version "0.1.0")
  (entry "src/main.tl"))
EOF
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
WALK_ASM="$WALK_PKG/target/typelisp/walk_pkg/walk_pkg.s"
[ -f "$WALK_ASM" ] || fail "package discover-upward did not write assembly"
assert_contains "$out" "Generated:"
assert_contains "$WALK_ASM" "main:"
assert_contains "$WALK_ASM" "_tl_inc:"

MISSING_DEP="$WORKDIR/missing_dep"
mkdir -p "$MISSING_DEP/src" "$MISSING_DEP/vendor/math"
cat > "$MISSING_DEP/typelisp.pkg" <<'EOF'
(package
  (name "missing_dep_file")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
cat > "$MISSING_DEP/src/main.tl" <<'EOF'
(import "pkg:math/src/missing.tl")
(define (main) : i64 0)
EOF
run_cmd package-missing-dep-file "$COMPILER" build --manifest-path "$MISSING_DEP/typelisp.pkg"
assert_failure
assert_stdout_empty
assert_contains "$err" "pkg:math/src/missing.tl"
assert_contains "$err" 'alias `math`'

# Normalize backslashes for Windows path comparison in diagnostic output.
ERR_NORMALIZED="$WORKDIR/missing_dep_err_normalized.tmp"
tr '\\' '/' < "$err" > "$ERR_NORMALIZED"
assert_contains "$ERR_NORMALIZED" "vendor/math/src/missing.tl"

echo "[public-tools] REPL/LSP corpus via run-corpus.sh"
TYPELISP_BIN="$COMPILER" sh "$ROOT/tests/public-tools/run-corpus.sh"

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
            if [ "$HOST_OS" != linux ]; then
                echo "[public-tools] skipping SPEC run example $spec_name on $HOST_OS"
                continue
            fi
            run_cmd "spec-$spec_name" "$COMPILER" run "$SPEC_WORK/$spec_name.tl"
            assert_code "$spec_value"
            check_file_exact "$out" "$SPEC_WORK/$spec_name.stdout"
            assert_stderr_empty
            ;;
        *)
            fail "unknown SPEC manifest mode for $spec_name: $spec_mode"
            ;;
    esac
done < "$SPEC_MANIFEST"

echo "public tool verification passed"
