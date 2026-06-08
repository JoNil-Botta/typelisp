#!/usr/bin/env sh
set -eu

# verify-native-link-linux.sh - Linux no-Rust native checks for selfhost drivers.
#
# This covers integration.rs cases where a selfhost TypeLisp driver emits
# assembly, and the emitted assembly must then assemble, link, and run.
# refs #971

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "selfhost native verification is Linux-only (requires as + ld)"
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # No-Rust fallback for local development: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

command -v as >/dev/null 2>&1 || {
    echo "missing assembler: as" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "missing linker: ld" >&2
    exit 1
}

WORKDIR="$ROOT/target/selfhost-native-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_empty() {
    _file=$1
    _label=$2
    if [ -s "$_file" ]; then
        echo "FAIL: $_label wrote unexpected output:" >&2
        sed 's/^/  /' "$_file" >&2
        exit 1
    fi
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

assert_contains_any() {
    _file=$1
    _label=$2
    shift 2
    for _snippet in "$@"; do
        if grep -F "$_snippet" "$_file" >/dev/null 2>&1; then
            return 0
        fi
    done
    echo "FAIL: $_label missing any snippet:" >&2
    for _snippet in "$@"; do
        echo "  $_snippet" >&2
    done
    exit 1
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

assert_file_exact() {
    _actual=$1
    _expected=$2
    _label=$3
    if ! cmp -s "$_actual" "$_expected"; then
        echo "FAIL: $_label differed from expected file $_expected" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_expected" "$_actual" >&2 || true
        fi
        exit 1
    fi
}

expect_stream() {
    _spec=$1
    _actual=$2
    _label=$3
    _expected="$WORKDIR/$_label.expected"
    case "$_spec" in
        -)
            : > "$_expected"
            ;;
        printf:*)
            printf '%b' "${_spec#printf:}" > "$_expected"
            ;;
        @*)
            cp "$ROOT/${_spec#@}" "$_expected"
            ;;
        *)
            printf '%s' "$_spec" > "$_expected"
            ;;
    esac
    if ! cmp -s "$_expected" "$_actual"; then
        echo "FAIL: $_label stream mismatch" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_expected" "$_actual" >&2 || true
        fi
        exit 1
    fi
}

assemble_link() {
    _label=$1
    _asm=$2
    _obj=$3
    _bin=$4
    _link_libc=$5

    as "$_asm" -o "$_obj"
    if [ "$_link_libc" -eq 1 ]; then
        ld "$_obj" -o "$_bin" -static
    else
        ld "$_obj" -o "$_bin"
    fi
}

run_binary_expect() {
    _label=$1
    _bin=$2
    _want=$3
    _stdout_spec=$4
    _stderr_spec=$5
    _stdout="$WORKDIR/$_label.stdout"
    _stderr="$WORKDIR/$_label.stderr"

    set +e
    "$_bin" > "$_stdout" 2> "$_stderr"
    _got=$?
    set -e

    if [ "$_got" -ne "$_want" ]; then
        echo "FAIL: $_label expected exit $_want, got $_got" >&2
        if [ -s "$_stdout" ]; then sed 's/^/  stdout: /' "$_stdout" >&2; fi
        if [ -s "$_stderr" ]; then sed 's/^/  stderr: /' "$_stderr" >&2; fi
        exit 1
    fi
    expect_stream "$_stdout_spec" "$_stdout" "$_label.stdout"
    expect_stream "$_stderr_spec" "$_stderr" "$_label.stderr"
}

assemble_link_run_asm() {
    _label=$1
    _asm=$2
    _want=$3
    _stdout_spec=$4
    _stderr_spec=$5
    _link_libc=$6
    _obj="$WORKDIR/$_label.o"
    _bin="$WORKDIR/$_label"

    assemble_link "$_label" "$_asm" "$_obj" "$_bin" "$_link_libc"
    run_binary_expect "$_label" "$_bin" "$_want" "$_stdout_spec" "$_stderr_spec"
}

compile_selfhost_binary() {
    _label=$1
    _source=$2
    _bin=$3
    _dir=$(dirname -- "$_bin")
    mkdir -p "$_dir"
    _asm="$_bin.s"
    _obj="$_bin.o"
    _out="$_bin.compile.stdout"
    _err="$_bin.compile.stderr"

    echo "[selfhost-native] compile $_source"
    set +e
    "$COMPILER" compile "$_source" --stdlib-root "$ROOT/stdlib" -o "$_asm" > "$_out" 2> "$_err"
    _got=$?
    set -e
    if [ "$_got" -ne 0 ]; then
        echo "FAIL: $_source compile exited $_got" >&2
        if [ -s "$_out" ]; then sed 's/^/  stdout: /' "$_out" >&2; fi
        if [ -s "$_err" ]; then sed 's/^/  stderr: /' "$_err" >&2; fi
        exit 1
    fi
    assemble_link "$_label" "$_asm" "$_obj" "$_bin" 1
    [ -x "$_bin" ] || fail "$_source compile/link did not write executable"
}

run_compiler_driver() {
    _driver=$1
    _label=$2
    _source=$3
    _asm=$4
    _stdout="$WORKDIR/$_label.driver.stdout"
    _stderr="$WORKDIR/$_label.driver.stderr"

    set +e
    "$_driver" "$_source" "$_asm" > "$_stdout" 2> "$_stderr"
    _got=$?
    set -e
    if [ "$_got" -ne 0 ]; then
        echo "FAIL: $_label compiler driver exited $_got" >&2
        if [ -s "$_stdout" ]; then sed 's/^/  stdout: /' "$_stdout" >&2; fi
        if [ -s "$_stderr" ]; then sed 's/^/  stderr: /' "$_stderr" >&2; fi
        exit 1
    fi
    expect_stream "printf:Wrote $_asm\n" "$_stdout" "$_label.driver.stdout"
    assert_empty "$_stderr" "$_label driver stderr"
}

run_compiler_driver_expect_error() {
    _driver=$1
    _label=$2
    _source=$3
    _asm=$4
    _want=$5
    _stdout="$WORKDIR/$_label.driver.stdout"
    _stderr="$WORKDIR/$_label.driver.stderr"
    rm -f "$_asm"

    set +e
    "$_driver" "$_source" "$_asm" > "$_stdout" 2> "$_stderr"
    _got=$?
    set -e
    if [ "$_got" -eq 0 ]; then
        echo "FAIL: $_label compiler driver unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$_stdout" "$_label driver stdout"
    assert_contains "$_stderr" "$_want" "$_label driver stderr"
    if [ -e "$_asm" ]; then
        echo "FAIL: $_label emitted assembly despite a diagnostic" >&2
        exit 1
    fi
}

build_selfhost_compiler_driver() {
    _bin=$1
    compile_selfhost_binary compiler-driver selfhost/compiler_driver.tl "$_bin"
}

verify_compiler_driver_stack_args() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/stack-args"
    mkdir -p "$_dir"
    _src="$_dir/input.tl"
    _asm="$_dir/output.s"
    cat > "$_src" <<'EOF'
(extern f : (-> i64 i64 i64 i64 i64 i64 i64 i64))
(define (main) : i64 (f 1 2 3 4 5 6 7))
EOF

    echo "[selfhost-native] compiler_driver stack-arg call shape"
    run_compiler_driver "$_driver" compiler-driver-stack-args "$_src" "$_asm"
    assert_not_contains "$_asm" "backend: too many call args" compiler-driver-stack-args
    for _snippet in \
        "subq \$16, %rsp" \
        "movq %r11, 0(%rsp)" \
        "addq \$16, %rsp" \
        "call f"
    do
        assert_contains "$_asm" "$_snippet" compiler-driver-stack-args
    done
}

verify_compiler_driver_import() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/import"
    mkdir -p "$_dir"
    _src="$_dir/input.tl"
    _helper="$_dir/helper.tl"
    _shared="$_dir/shared.tl"
    _asm="$_dir/generated.s"
    _again="$_dir/generated-again.s"

    cat > "$_shared" <<'EOF'
(define shared : i64 2)
EOF
    cat > "$_helper" <<'EOF'
(import "shared.tl")
(define (helper) : i64 (+ 38 shared))
EOF
    cat > "$_src" <<'EOF'
(import "helper.tl")
(import "shared.tl")
(define (main) : i64 (+ (helper) shared))
EOF

    echo "[selfhost-native] compiler_driver deterministic multi-file import"
    run_compiler_driver "$_driver" compiler-driver-import "$_src" "$_asm"
    run_compiler_driver "$_driver" compiler-driver-import-again "$_src" "$_again"
    assert_file_exact "$_again" "$_asm" compiler-driver-import-deterministic
    assert_file_exact "$_asm" "$ROOT/tests/golden/selfhost_compiler_driver_import.s" compiler-driver-import-golden
    for _snippet in \
        "_tl_shared_shared:" \
        "_tl_helper_helper:" \
        "call _tl_helper_helper" \
        "_tl_shared_shared(%rip)" \
        "_start:"
    do
        assert_contains "$_asm" "$_snippet" compiler-driver-import
    done
    assemble_link_run_asm compiler-driver-import "$_asm" 42 - - 1
}

verify_compiler_driver_pkg_import() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/pkg-import"
    _pkg="$_dir/app"
    mkdir -p "$_pkg/src" "$_pkg/vendor/math/src" "$_pkg/bad"
    _asm="$_dir/pkg.s"
    _again="$_dir/pkg-again.s"

    cat > "$_pkg/typelisp.pkg" <<'EOF'
(package
  (name "selfhost_loader_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
    cat > "$_pkg/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
    cat > "$_pkg/vendor/math/src/dup.tl" <<'EOF'
(define (dup) : i64 1)
EOF
    cat > "$_pkg/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(import "../vendor/math/src/lib.tl")
(define (main) : i64 (add-one 41))
EOF

    echo "[selfhost-native] compiler_driver pkg import graph"
    run_compiler_driver "$_driver" compiler-driver-pkg-import "$_pkg/src/main.tl" "$_asm"
    run_compiler_driver "$_driver" compiler-driver-pkg-import-again "$_pkg/src/main.tl" "$_again"
    assert_file_exact "$_again" "$_asm" compiler-driver-pkg-import-deterministic
    assert_contains "$_asm" "math_src_lib_add_one:" compiler-driver-pkg-import
    if ! grep -E "    (call|jmp) _tl_" "$_asm" | grep -F "math_src_lib_add_one" >/dev/null 2>&1; then
        fail "compiler-driver-pkg-import missing qualified add-one call/jump"
    fi
    assemble_link_run_asm compiler-driver-pkg-import "$_asm" 42 - - 1

    cat > "$_pkg/bad/missing-alias.tl" <<'EOF'
(import "pkg:nope/src/lib.tl")
(define (main) : i64 0)
EOF
    run_compiler_driver_expect_error \
        "$_driver" \
        compiler-driver-pkg-missing-alias \
        "$_pkg/bad/missing-alias.tl" \
        "$_dir/missing-alias.s" \
        "compiler-load: unknown package alias 'nope': pkg:nope/src/lib.tl"

    cat > "$_pkg/bad/missing-dep.tl" <<'EOF'
(import "pkg:math/src/missing.tl")
(define (main) : i64 0)
EOF
    run_compiler_driver_expect_error \
        "$_driver" \
        compiler-driver-pkg-missing-dep \
        "$_pkg/bad/missing-dep.tl" \
        "$_dir/missing-dep.s" \
        "compiler-load: cannot read import"
    assert_contains \
        "$WORKDIR/compiler-driver-pkg-missing-dep.driver.stderr" \
        "vendor/math/src/missing.tl" \
        compiler-driver-pkg-missing-dep

    cat > "$_pkg/bad/escape.tl" <<'EOF'
(import "pkg:math/../escape.tl")
(define (main) : i64 0)
EOF
    run_compiler_driver_expect_error \
        "$_driver" \
        compiler-driver-pkg-parent-escape \
        "$_pkg/bad/escape.tl" \
        "$_dir/escape.s" \
        "compiler-load: pkg import escapes package root: pkg:math/../escape.tl"

    cat > "$_pkg/bad/duplicate.tl" <<'EOF'
(import "pkg:math/src/dup.tl")
(define (dup) : i64 2)
(define (dup) : i64 3)
(define (main) : i64 (dup))
EOF
    run_compiler_driver_expect_error \
        "$_driver" \
        compiler-driver-pkg-duplicate \
        "$_pkg/bad/duplicate.tl" \
        "$_dir/duplicate.s" \
        "symbols: duplicate value declaration dup"
}

verify_compiler_driver_string_runtime() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/string-runtime"
    mkdir -p "$_dir"
    _src="$_dir/input.tl"
    _asm="$_dir/output.s"
    cat > "$_src" <<'EOF'
(define (main) : i64
  (+ (string-length "0123456789") (cast (char-at " x" 0) : i64)))
EOF

    echo "[selfhost-native] compiler_driver string runtime helpers"
    run_compiler_driver "$_driver" compiler-driver-string-runtime "$_src" "$_asm"
    for _snippet in \
        "tl_oob_abort:" \
        "jb .Lf" \
        "str_bounds_ok"
    do
        assert_contains "$_asm" "$_snippet" compiler-driver-string-runtime
    done
    assert_not_contains "$_asm" "call tl_substring" compiler-driver-string-runtime
    assert_not_contains "$_asm" "call tl_string_concat" compiler-driver-string-runtime
    assemble_link_run_asm compiler-driver-string-runtime "$_asm" 42 - - 1
}

verify_compiler_driver_stdlib_string_runtime() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/stdlib-string-runtime"
    mkdir -p "$_dir/stdlib"
    cp stdlib/string.tl "$_dir/stdlib/string.tl"
    _src="$_dir/input.tl"
    _asm="$_dir/output.s"
    cat > "$_src" <<'EOF'
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [joined : String (string-append "foo" "bar")]
    [extended : String (string-concat joined "!")]
    [borrowed : String (string-append-borrowed (& extended) (& joined))]
    [digits : String (int->string -42)]
    (if (and
      (string-eq borrowed "foobar!foobar")
      (string-eq digits "-42"))
      42
      1)))
EOF

    echo "[selfhost-native] compiler_driver stdlib string append shadow"
    run_compiler_driver "$_driver" compiler-driver-stdlib-string-runtime "$_src" "$_asm"
    assert_not_contains "$_asm" "call tl_string_concat" compiler-driver-stdlib-string-runtime
    assert_not_contains "$_asm" "tl_string_concat:" compiler-driver-stdlib-string-runtime
    assert_not_contains "$_asm" "call tl_int_to_string" compiler-driver-stdlib-string-runtime
    assert_not_contains "$_asm" "tl_int_to_string:" compiler-driver-stdlib-string-runtime
    assemble_link_run_asm compiler-driver-stdlib-string-runtime "$_asm" 42 - - 1
}

verify_compiler_driver_stdlib_json() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/stdlib-json"
    mkdir -p "$_dir/stdlib"
    cp stdlib/json.tl "$_dir/stdlib/json.tl"
    cp stdlib/io.tl "$_dir/stdlib/io.tl"
    cp stdlib/str_cat.tl "$_dir/stdlib/str_cat.tl"
    cp stdlib/string.tl "$_dir/stdlib/string.tl"
    cp stdlib/text_buf.tl "$_dir/stdlib/text_buf.tl"
    _src="$_dir/input.tl"
    _asm="$_dir/output.s"
    cat > "$_src" <<'EOF'
(import "stdlib/json.tl")

(define (main) : i64
  (let
    [text : String "{\"ok\":true,\"values\":[1,2,null]}"]
    (match (json-parse (& text))
      [(OkJson value)
        (if (string-eq
          (json-stringify value)
          "{\"ok\":true,\"values\":[1,2,null]}")
          42
          2)]
      [(ErrJson _) 1])))
EOF

    echo "[selfhost-native] compiler_driver stdlib JSON import graph"
    run_compiler_driver "$_driver" compiler-driver-stdlib-json "$_src" "$_asm"
    for _snippet in \
        "_tl_stdlib_json_json_parse" \
        "_tl_stdlib_json_json_stringify" \
        "_tl_stdlib_json_json_parse_object"
    do
        assert_contains "$_asm" "$_snippet" compiler-driver-stdlib-json
    done
    assemble_link_run_asm compiler-driver-stdlib-json "$_asm" 42 - - 1
}

verify_compiler_driver_arrays_and_traps() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/arrays"
    mkdir -p "$_dir"
    _src="$_dir/array.tl"
    _asm="$_dir/array.s"
    cat > "$_src" <<'EOF'
(define (main) : i64
  (let ([a : (Array i64) (make-array i64 2)])
    (begin
      (array-set! a 0 40)
      (array-set! a 1 2)
      (+ (array-ref a 0) (array-ref a 1)))))
EOF

    echo "[selfhost-native] compiler_driver dynamic array runtime"
    run_compiler_driver "$_driver" compiler-driver-array "$_src" "$_asm"
    for _snippet in \
        "call tl_alloc" \
        "tl_oob_abort:" \
        "make_array_len_ok" \
        "bounds_ok"
    do
        assert_contains "$_asm" "$_snippet" compiler-driver-array
    done
    assemble_link_run_asm compiler-driver-array "$_asm" 42 - - 1

    _oob_src="$_dir/string-oob.tl"
    _oob_asm="$_dir/string-oob.s"
    cat > "$_oob_src" <<'EOF'
(define (main) : i64 (cast (string-ref "x" 1) : i64))
EOF

    echo "[selfhost-native] compiler_driver runtime trap output"
    run_compiler_driver "$_driver" compiler-driver-string-oob "$_oob_src" "$_oob_asm"
    assemble_link_run_asm compiler-driver-string-oob "$_oob_asm" 134 - "printf:tl: array index out of bounds\n" 1
}

verify_compiler_driver_immutable_refs() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/immutable-refs"
    mkdir -p "$_dir"

    for _case in \
        ref_return \
        ref_param_identity \
        ref_tuple_return \
        ref_fixed_array_return
    do
        _src="$ROOT/tests/integration/$_case.tl"
        _asm="$_dir/$_case.s"
        _label="compiler-driver-$_case"

        echo "[selfhost-native] compiler_driver immutable ref $_case"
        run_compiler_driver "$_driver" "$_label" "$_src" "$_asm"
        assemble_link_run_asm "$_label" "$_asm" 42 - - 1
    done
}

verify_compiler_driver_recursive_box_list() {
    _driver=$1
    _dir="$WORKDIR/compiler-driver/recursive-box-list"
    mkdir -p "$_dir"
    _src="$_dir/input.tl"
    _asm="$_dir/output.s"
    cat > "$_src" <<'EOF'
(defenum IntList
  (Nil)
  (Cons i64 (Box IntList)))

(define (sum [xs : IntList]) : i64
  (match xs
    [(Nil) 0]
    [(Cons head tail)
      (+ head (sum (box-get tail)))]))

(define (main) : i64
  (sum (Cons 10 (box (Cons 30 (box (Cons 2 (box (Nil)))))))))
EOF

    echo "[selfhost-native] compiler_driver recursive Box list"
    run_compiler_driver "$_driver" compiler-driver-recursive-box-list "$_src" "$_asm"
    assert_contains_any "$_asm" compiler-driver-recursive-box-list \
        "call tl_alloc" \
        "call .L_tl_alloc8"
    assemble_link_run_asm compiler-driver-recursive-box-list "$_asm" 42 - - 1
}

verify_emit_printed_program() {
    _dir="$WORKDIR/generated-emit"
    mkdir -p "$_dir"
    _bin="$_dir/emit"
    _asm="$_dir/printed.s"
    _stderr="$_dir/emit.stderr"

    compile_selfhost_binary emit-driver selfhost/emit.tl "$_bin"
    echo "[selfhost-native] emit.tl printed assembly"
    set +e
    "$_bin" > "$_asm" 2> "$_stderr"
    _got=$?
    set -e
    [ "$_got" -eq 0 ] || fail "emit.tl exited $_got"
    assert_empty "$_stderr" "emit.tl stderr"
    assert_file_exact "$_asm" "$ROOT/tests/golden/tl_emit_program.s" tl-emit-golden
    assemble_link_run_asm tl-emit-printed "$_asm" 7 - - 0
}

verify_parse_printed_program() {
    _dir="$WORKDIR/generated-parse"
    mkdir -p "$_dir"
    _bin="$_dir/parse"
    _asm="$_dir/printed.s"
    _stderr="$_dir/parse.stderr"

    compile_selfhost_binary parse-driver selfhost/parse.tl "$_bin"
    echo "[selfhost-native] parse.tl printed assembly"
    set +e
    "$_bin" > "$_asm" 2> "$_stderr"
    _got=$?
    set -e
    [ "$_got" -eq 0 ] || fail "parse.tl exited $_got"
    assert_empty "$_stderr" "parse.tl stderr"
    for _snippet in \
        "sub \$16, %rsp" \
        "movq %rax, -8(%rbp)" \
        "movq -8(%rbp), %rax" \
        "add \$16, %rsp" \
        "setle %al" \
        "cmpq \$0, %rax" \
        "je .Lelse_" \
        "jmp .Lend_" \
        ".Lelse_" \
        ".Lend_"
    do
        assert_contains "$_asm" "$_snippet" tl-parse-printed
    done
    assert_not_contains "$_asm" ".section .rodata" tl-parse-printed
    assemble_link_run_asm tl-parse-printed "$_asm" 1 - - 0
}

# eval.tl evaluates a source string passed as its single program argument and
# reports recoverable runtime errors (type errors, unbound variables, arity
# mismatches) with exit 1 and a diagnostic on stderr, writing nothing to stdout.
# This is the native runtime-behavior witness for the eval driver; its
# compilation/determinism is already covered by the selfhost_eval compile
# manifest case.
run_eval_driver_expect_error() {
    _driver=$1
    _label=$2
    _source=$3
    _want_stderr=$4
    _stdout="$WORKDIR/$_label.eval.stdout"
    _stderr="$WORKDIR/$_label.eval.stderr"

    set +e
    "$_driver" "$_source" > "$_stdout" 2> "$_stderr"
    _got=$?
    set -e
    if [ "$_got" -ne 1 ]; then
        echo "FAIL: $_label eval driver expected exit 1, got $_got" >&2
        if [ -s "$_stdout" ]; then sed 's/^/  stdout: /' "$_stdout" >&2; fi
        if [ -s "$_stderr" ]; then sed 's/^/  stderr: /' "$_stderr" >&2; fi
        exit 1
    fi
    assert_empty "$_stdout" "$_label eval driver stdout"
    assert_contains "$_stderr" "$_want_stderr" "$_label eval driver stderr"
}

verify_eval_driver_errors() {
    _dir="$WORKDIR/generated-eval"
    mkdir -p "$_dir"
    _bin="$_dir/eval"

    compile_selfhost_binary eval-driver selfhost/eval.tl "$_bin"
    echo "[selfhost-native] eval.tl recoverable error reporting"
    run_eval_driver_expect_error "$_bin" eval-type-mismatch \
        '(+ "a" 1)' "type error: expected int"
    run_eval_driver_expect_error "$_bin" eval-unbound-variable \
        'missing' "eval: unbound variable"
    run_eval_driver_expect_error "$_bin" eval-arity-mismatch \
        '(define (id x) x) (id)' "eval: too few arguments in call"
}

DRIVER="$WORKDIR/compiler-driver/compiler-driver"
build_selfhost_compiler_driver "$DRIVER"
verify_compiler_driver_stack_args "$DRIVER"
verify_compiler_driver_import "$DRIVER"
verify_compiler_driver_pkg_import "$DRIVER"
verify_compiler_driver_string_runtime "$DRIVER"
verify_compiler_driver_stdlib_string_runtime "$DRIVER"
verify_compiler_driver_stdlib_json "$DRIVER"
verify_compiler_driver_arrays_and_traps "$DRIVER"
verify_compiler_driver_immutable_refs "$DRIVER"
verify_compiler_driver_recursive_box_list "$DRIVER"
verify_emit_printed_program
verify_parse_printed_program
verify_eval_driver_errors

echo "selfhost native verification passed"
