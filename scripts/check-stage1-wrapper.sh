#!/usr/bin/env sh
set -eu

# Smoke-test a TYPELISP_BIN-compatible stage1 wrapper on the Linux host-action
# surface: compile, tokenize, parse, check, source/package build, run, repl,
# doc, test, fmt, and debug host-action.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "stage1 wrapper smoke is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "stage1 wrapper smoke requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/stage1-wrapper-smoke"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SRC="$WORKDIR/smoke.tl"
ASM="$WORKDIR/smoke.s"
IR="$WORKDIR/smoke.ir"
BIN="$WORKDIR/smoke-bin"
HOST_ACTION_BIN="$WORKDIR/host action/out bin"
SCRATCH_ASM="$WORKDIR/inline-test.s"

cat > "$SRC" <<'EOF'
(define (main) : i64
  7)
EOF

fail() {
    echo "$*" >&2
    exit 1
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -qF "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    fi
}

assert_empty() {
    file=$1
    [ ! -s "$file" ] || {
        echo "expected empty file: $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    }
}

assert_nonempty() {
    file=$1
    [ -s "$file" ] || fail "expected non-empty file: $file"
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
        fail "unexpected file content: $actual"
    fi
}

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

run_capture() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if ! TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@" 3>&2 > "$stdout" 2> "$stderr"; then
        echo "stage1 wrapper smoke command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

run_stdin_capture() {
    label=$1
    input=$2
    shift 2
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if ! TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@" 3>&2 < "$input" > "$stdout" 2> "$stderr"; then
        echo "stage1 wrapper smoke command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

run_capture_cwd() {
    label=$1
    cwd=$2
    shift 2
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if ! (cd "$cwd" && TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@") 3>&2 > "$stdout" 2> "$stderr"; then
        echo "stage1 wrapper smoke command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

run_expect_failure() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    set +e
    "$@" > "$stdout" 2> "$stderr"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "stage1 wrapper smoke command unexpectedly succeeded: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

echo "[stage1-wrapper] compile"
run_capture compile "$COMPILER" compile "$SRC" -o "$ASM"
[ -f "$ASM" ] || {
    echo "compile did not write $ASM" >&2
    exit 1
}
assert_contains "$WORKDIR/compile.stdout" "Generated: $ASM"

echo "[stage1-wrapper] compile --emit-ir"
run_capture compile-ir "$COMPILER" compile "$SRC" --emit-ir
[ -f "$IR" ] || {
    echo "compile --emit-ir did not write $IR" >&2
    exit 1
}
assert_contains "$WORKDIR/compile-ir.stdout" "Generated: $IR"
assert_contains "$IR" "typelisp-ir-summary v1"

run_expect_failure compile-missing-source "$COMPILER" compile
assert_empty "$WORKDIR/compile-missing-source.stdout"
assert_contains "$WORKDIR/compile-missing-source.stderr" "compile: expected source path"

echo "[stage1-wrapper] frontend aliases"
run_capture tokenize "$COMPILER" tokenize "$SRC"
assert_empty "$WORKDIR/tokenize.stderr"
assert_contains "$WORKDIR/tokenize.stdout" "define"
assert_contains "$WORKDIR/tokenize.stdout" "main"
cp "$WORKDIR/tokenize.stdout" "$WORKDIR/tokenize.expected"

run_capture debug-tokenize "$COMPILER" debug tokenize "$SRC"
assert_empty "$WORKDIR/debug-tokenize.stderr"
cmp -s "$WORKDIR/debug-tokenize.stdout" "$WORKDIR/tokenize.expected" || fail "debug tokenize differs from tokenize"

run_capture parse "$COMPILER" parse "$SRC"
assert_empty "$WORKDIR/parse.stderr"
assert_contains "$WORKDIR/parse.stdout" "Program"
assert_contains "$WORKDIR/parse.stdout" "DefFn"
cp "$WORKDIR/parse.stdout" "$WORKDIR/parse.expected"

run_capture debug-parse "$COMPILER" debug parse "$SRC"
assert_empty "$WORKDIR/debug-parse.stderr"
cmp -s "$WORKDIR/debug-parse.stdout" "$WORKDIR/parse.expected" || fail "debug parse differs from parse"

run_capture check "$COMPILER" check "$SRC"
assert_empty "$WORKDIR/check.stderr"
assert_contains "$WORKDIR/check.stdout" "Type checking passed!"

CHECK_ROOT="$WORKDIR/check-root"
mkdir -p "$CHECK_ROOT/app" "$CHECK_ROOT/repo-stdlib"
cat > "$CHECK_ROOT/repo-stdlib/helper.tl" <<'EOF'
(define (helper) : i64 42)
EOF
cat > "$CHECK_ROOT/app/main.tl" <<'EOF'
(import "stdlib/helper.tl")
(define (main) : i64 (helper))
EOF
run_capture check-stdlib-root "$COMPILER" check "$CHECK_ROOT/app/main.tl" --stdlib-root "$CHECK_ROOT/repo-stdlib"
assert_empty "$WORKDIR/check-stdlib-root.stderr"
assert_contains "$WORKDIR/check-stdlib-root.stdout" "Type checking passed!"
cp "$WORKDIR/check-stdlib-root.stdout" "$WORKDIR/check-stdlib-root.expected"

run_capture debug-check-stdlib-root "$COMPILER" debug check "$CHECK_ROOT/app/main.tl" --stdlib-root "$CHECK_ROOT/repo-stdlib"
assert_empty "$WORKDIR/debug-check-stdlib-root.stderr"
cmp -s "$WORKDIR/debug-check-stdlib-root.stdout" "$WORKDIR/check-stdlib-root.expected" || fail "debug check differs from check"

run_expect_failure debug-missing "$COMPILER" debug
assert_empty "$WORKDIR/debug-missing.stdout"
assert_contains "$WORKDIR/debug-missing.stderr" "Error: missing debug subcommand"
assert_contains "$WORKDIR/debug-missing.stderr" "typelisp debug tokenize <file.tl>"

run_expect_failure debug-unknown "$COMPILER" debug wat
assert_empty "$WORKDIR/debug-unknown.stdout"
assert_contains "$WORKDIR/debug-unknown.stderr" "Unknown debug command: wat"
assert_contains "$WORKDIR/debug-unknown.stderr" "typelisp debug check <file.tl>"

run_expect_failure tokenize-missing "$COMPILER" tokenize
assert_empty "$WORKDIR/tokenize-missing.stdout"
assert_contains "$WORKDIR/tokenize-missing.stderr" "Error: missing file argument"

echo "[stage1-wrapper] build"
run_capture build "$COMPILER" build "$SRC" -o "$BIN"
[ -x "$BIN" ] || {
    echo "build did not write executable $BIN" >&2
    exit 1
}
assert_contains "$WORKDIR/build.stdout" "Generated: $BIN"

echo "[stage1-wrapper] package build"
PKG="$WORKDIR/pkg"
mkdir -p "$PKG/src/nested/deeper" "$PKG/vendor/math/src"
cat > "$PKG/typelisp.pkg" <<'EOF'
(package
  (name "stage1_pkg")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
cat > "$PKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 (add-one 41))
EOF
cat > "$PKG/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
PKG_ASM="$PKG/target/typelisp/stage1_pkg/stage1_pkg.s"
run_capture build-package "$COMPILER" build --manifest-path "$PKG/typelisp.pkg" --opt-level 0
[ -f "$PKG_ASM" ] || {
    echo "package build did not write assembly $PKG_ASM" >&2
    exit 1
}
assert_contains "$WORKDIR/build-package.stdout" "Generated: $PKG_ASM"
assert_contains "$PKG_ASM" "main:"
assert_contains "$PKG_ASM" "add_one"

rm -rf "$PKG/target"
run_capture_cwd build-package-discover "$PKG/src/nested/deeper" "$COMPILER" build
[ -f "$PKG_ASM" ] || {
    echo "package discovery did not write assembly $PKG_ASM" >&2
    exit 1
}
assert_contains "$WORKDIR/build-package-discover.stdout" "Generated: ../../../target/typelisp/stage1_pkg/stage1_pkg.s"

run_expect_failure build-package-missing "$COMPILER" build --manifest-path "$WORKDIR/missing.pkg"
assert_empty "$WORKDIR/build-package-missing.stdout"
assert_contains "$WORKDIR/build-package-missing.stderr" "cannot read package manifest"

echo "[stage1-wrapper] run"
set +e
"$COMPILER" run "$SRC" > "$WORKDIR/run.stdout" 2> "$WORKDIR/run.stderr"
run_status=$?
set -e
if [ "$run_status" -ne 7 ]; then
    echo "run expected exit 7, got $run_status" >&2
    echo "stdout:" >&2
    sed 's/^/  /' "$WORKDIR/run.stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$WORKDIR/run.stderr" >&2 || true
    exit 1
fi
printf '' > "$WORKDIR/expected.stdout"
if ! cmp -s "$WORKDIR/expected.stdout" "$WORKDIR/run.stdout"; then
    echo "run stdout mismatch" >&2
    exit 1
fi
if [ -s "$WORKDIR/run.stderr" ]; then
    echo "run stderr was not empty" >&2
    sed 's/^/  /' "$WORKDIR/run.stderr" >&2 || true
    exit 1
fi

echo "[stage1-wrapper] repl"
: > "$WORKDIR/repl-empty.in"
run_stdin_capture repl-empty "$WORKDIR/repl-empty.in" "$COMPILER" repl
assert_contains "$WORKDIR/repl-empty.stdout" "TypeLisp REPL. Type .help for commands."
assert_contains "$WORKDIR/repl-empty.stdout" "tl> "
assert_empty "$WORKDIR/repl-empty.stderr"

cat > "$WORKDIR/repl-session.in" <<'EOF'
.help
.type true
(+ 1 2)
.exit
EOF
run_stdin_capture repl-session "$WORKDIR/repl-session.in" "$COMPILER" repl
assert_contains "$WORKDIR/repl-session.stdout" "TypeLisp REPL commands:"
assert_contains "$WORKDIR/repl-session.stdout" ".type <expr>"
assert_contains "$WORKDIR/repl-session.stdout" "bool"
assert_contains "$WORKDIR/repl-session.stderr" "REPL evaluation is not implemented yet"

run_expect_failure repl-args "$COMPILER" repl unexpected
assert_empty "$WORKDIR/repl-args.stdout"
assert_contains "$WORKDIR/repl-args.stderr" "Error: repl does not accept arguments"

echo "[stage1-wrapper] doc"
if [ "${TYPELISP_STAGE1_SKIP_DOC_SMOKE:-}" = "1" ]; then
    echo "[stage1-wrapper] doc generation skipped"
    run_capture doc-help "$COMPILER" doc help
    assert_empty "$WORKDIR/doc-help.stdout"
    assert_contains "$WORKDIR/doc-help.stderr" "typelisp doc <file.tl>"
else
    DOC_DIR="$WORKDIR/doc"
    DOC_STDLIB="$DOC_DIR/stdlib"
    DOC_ENTRY="$DOC_DIR/entry.tl"
    DOC_LOCAL="$DOC_DIR/local.tl"
    DOC_STDLIB_SOURCE="$DOC_STDLIB/docfixture.tl"
    DOC_MD="$DOC_DIR/entry.md"
    mkdir -p "$DOC_STDLIB"
    cat > "$DOC_LOCAL" <<'EOF'
;;;; Local module docs.

;;; Local answer docs.
(define local-answer : i64 7)
EOF
    cat > "$DOC_STDLIB_SOURCE" <<'EOF'
;;;; Stdlib module docs.

;;; Stdlib answer docs.
(define stdlib-answer : i64 35)
EOF
    cat > "$DOC_ENTRY" <<'EOF'
;;;; Entry module docs.
;;;; ```typelisp
;;;; (import "stdlib/docfixture.tl")
;;;; (define (main) : i64 stdlib-answer)
;;;; ```

(import "local.tl")
(import "stdlib/docfixture.tl")

;;; Entry docs.
(define (main) : i64 (+ local-answer stdlib-answer))
EOF
    run_capture doc "$COMPILER" doc "$DOC_ENTRY" -o "$DOC_MD" --stdlib-root "$DOC_STDLIB"
    assert_empty "$WORKDIR/doc.stderr"
    assert_contains "$WORKDIR/doc.stdout" "Generated: $DOC_MD"
    assert_contains "$DOC_MD" "Entry module docs."
    assert_contains "$DOC_MD" "Local module docs."
    assert_contains "$DOC_MD" "Stdlib module docs."

    echo "[stage1-wrapper] doc --test"
    run_capture doc-test "$COMPILER" doc --test "$DOC_ENTRY" --stdlib-root "$DOC_STDLIB"
    assert_empty "$WORKDIR/doc-test.stderr"
    assert_contains "$WORKDIR/doc-test.stdout" "Doc tests passed: 1 example(s)"
fi

if [ "${TYPELISP_STAGE1_SKIP_TEST_SMOKE:-}" = "1" ]; then
    echo "[stage1-wrapper] test commands skipped"
else
    echo "[stage1-wrapper] test --check"
    TEST_SRC="$WORKDIR/inline-test.tl"
    cat > "$TEST_SRC" <<'EOF'
(import "stdlib/test.tl")

(define (inc [x : i64]) : i64 (+ x 1))

(test inc-basic
  (assert-i64-eq (inc 41) 42 "inc result"))
EOF
    run_capture test-check "$COMPILER" test --check "$TEST_SRC" --target linux-x86_64 --opt-level 3 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-check.stderr"
    assert_contains "$WORKDIR/test-check.stdout" "TypeLisp test typecheck passed: 1 test(s)"

    echo "[stage1-wrapper] test"
    run_capture test-run "$COMPILER" test "$TEST_SRC" --opt-level 2 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-run.stdout"
    assert_contains "$WORKDIR/test-run.stderr" "test inc-basic"
    assert_contains "$WORKDIR/test-run.stderr" "ok inc-basic"
    assert_contains "$WORKDIR/test-run.stderr" "TypeLisp tests passed: 1 test(s)"
    [ ! -f "$TEST_SRC.test.s" ] || {
        echo "test left scratch assembly behind: $TEST_SRC.test.s" >&2
        exit 1
    }

    echo "[stage1-wrapper] test no-tests"
    NO_TEST_SRC="$WORKDIR/no-tests.tl"
    cat > "$NO_TEST_SRC" <<'EOF'
(define (main) : i64 0)
EOF
    run_capture test-no-tests-check "$COMPILER" test --check "$NO_TEST_SRC"
    assert_empty "$WORKDIR/test-no-tests-check.stderr"
    assert_contains "$WORKDIR/test-no-tests-check.stdout" "TypeLisp test typecheck passed: 0 test(s)"
    run_capture test-no-tests-run "$COMPILER" test "$NO_TEST_SRC"
    assert_empty "$WORKDIR/test-no-tests-run.stdout"
    assert_contains "$WORKDIR/test-no-tests-run.stderr" "TypeLisp tests passed: 0 test(s)"
    [ ! -f "$NO_TEST_SRC.test.s" ] || {
        echo "test no-tests left scratch assembly behind: $NO_TEST_SRC.test.s" >&2
        exit 1
    }

    echo "[stage1-wrapper] test failures"
    FAIL_SRC="$WORKDIR/inline-test-fail.tl"
    cat > "$FAIL_SRC" <<'EOF'
(import "stdlib/test.tl")

(test failing-case
  (assert-i64-eq 1 2 "inline failure message"))
EOF
    set +e
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test "$FAIL_SRC" --stdlib-root "$ROOT/stdlib" 3>&2 > "$WORKDIR/test-fail.stdout" 2> "$WORKDIR/test-fail.stderr"
    fail_status=$?
    set -e
    if [ "$fail_status" -eq 0 ]; then
        echo "stage1 wrapper test failure case unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$WORKDIR/test-fail.stdout"
    assert_contains "$WORKDIR/test-fail.stderr" "test failing-case"
    assert_contains "$WORKDIR/test-fail.stderr" "inline failure message"
    assert_contains "$WORKDIR/test-fail.stderr" "typelisp test: test executable exited"
    [ ! -f "$FAIL_SRC.test.s" ] || {
        echo "failing test left scratch assembly behind: $FAIL_SRC.test.s" >&2
        exit 1
    }

    BAD_SRC="$WORKDIR/inline-test-bad.tl"
    cat > "$BAD_SRC" <<'EOF'
(test compile-error
  (missing-inline-test-name))
EOF
    set +e
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test --check "$BAD_SRC" 3>&2 > "$WORKDIR/test-bad.stdout" 2> "$WORKDIR/test-bad.stderr"
    bad_status=$?
    set -e
    if [ "$bad_status" -eq 0 ]; then
        echo "stage1 wrapper test compile-error case unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$WORKDIR/test-bad.stdout"
    assert_contains "$WORKDIR/test-bad.stderr" "typecheck: unbound name missing-inline-test-name"

    set +e
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test "$TEST_SRC" --opt-level 3>&2 > "$WORKDIR/test-missing-opt.stdout" 2> "$WORKDIR/test-missing-opt.stderr"
    missing_opt_status=$?
    set -e
    if [ "$missing_opt_status" -eq 0 ]; then
        echo "stage1 wrapper test missing-opt-level case unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$WORKDIR/test-missing-opt.stdout"
    assert_contains "$WORKDIR/test-missing-opt.stderr" "test: --opt-level requires a value"

    set +e
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test --check "$TEST_SRC" --target nope 3>&2 > "$WORKDIR/test-bad-target.stdout" 2> "$WORKDIR/test-bad-target.stderr"
    bad_target_status=$?
    set -e
    if [ "$bad_target_status" -eq 0 ]; then
        echo "stage1 wrapper test bad-target case unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$WORKDIR/test-bad-target.stdout"
    assert_contains "$WORKDIR/test-bad-target.stderr" "test: unknown target nope"
fi

echo "[stage1-wrapper] fmt"
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

set -- "$COMPILER" fmt
while IFS= read -r fmt_name; do
    [ -n "$fmt_name" ] || continue
    cp "tests/format_golden/$fmt_name.tl" "$WORKDIR/$fmt_name.tl"
    strip_expected_trailing_lf "tests/format_golden/$fmt_name.expected" "$WORKDIR/$fmt_name.expected"
    set -- "$@" "$WORKDIR/$fmt_name.tl"
done < "$WORKDIR/format-expected.txt"
run_capture fmt-golden "$@"
assert_empty "$WORKDIR/fmt-golden.stdout"
assert_empty "$WORKDIR/fmt-golden.stderr"
while IFS= read -r fmt_name; do
    [ -n "$fmt_name" ] || continue
    check_file_exact "$WORKDIR/$fmt_name.tl" "$WORKDIR/$fmt_name.expected"
done < "$WORKDIR/format-expected.txt"

set -- "$COMPILER" fmt --check
while IFS= read -r fmt_name; do
    [ -n "$fmt_name" ] || continue
    set -- "$@" "$WORKDIR/$fmt_name.tl"
done < "$WORKDIR/format-expected.txt"
run_capture fmt-golden-check "$@"
assert_empty "$WORKDIR/fmt-golden-check.stdout"
assert_empty "$WORKDIR/fmt-golden-check.stderr"

cp "tests/format_golden/decls.tl" "$WORKDIR/fmt-changed.tl"
run_expect_failure fmt-check-changed "$COMPILER" fmt --check "$WORKDIR/fmt-changed.tl"
assert_empty "$WORKDIR/fmt-check-changed.stdout"
assert_contains "$WORKDIR/fmt-check-changed.stderr" "fmt: would reformat"
check_file_exact "$WORKDIR/fmt-changed.tl" "tests/format_golden/decls.tl"

run_expect_failure fmt-missing "$COMPILER" fmt "$WORKDIR/missing.tl"
assert_empty "$WORKDIR/fmt-missing.stdout"
assert_nonempty "$WORKDIR/fmt-missing.stderr"

printf '(define (' > "$WORKDIR/fmt-parse-error.tl"
run_expect_failure fmt-parse-error "$COMPILER" fmt "$WORKDIR/fmt-parse-error.tl"
assert_empty "$WORKDIR/fmt-parse-error.stdout"
assert_nonempty "$WORKDIR/fmt-parse-error.stderr"

echo "[stage1-wrapper] debug host-action"
mkdir -p "$(dirname -- "$HOST_ACTION_BIN")"
{
    printf 'typelisp-host-plan v1\n'
    printf 'action build-source\n'
    printf 'source %s:%s\n' "${#SRC}" "$SRC"
    printf 'output %s:%s\n' "${#HOST_ACTION_BIN}" "$HOST_ACTION_BIN"
    printf 'target linux-x86_64\n'
    printf 'backend-mode scalar\n'
    printf 'end\n'
} > "$WORKDIR/host-action.in"
run_capture host-action "$COMPILER" debug host-action < "$WORKDIR/host-action.in"
[ -x "$HOST_ACTION_BIN" ] || {
    echo "debug host-action did not write executable $HOST_ACTION_BIN" >&2
    exit 1
}
assert_contains "$WORKDIR/host-action.stdout" "Generated: $HOST_ACTION_BIN"

cat > "$SCRATCH_ASM" <<'EOF'
.globl _start
_start:
    mov $5, %rdi
    mov $60, %rax
    syscall
EOF
{
    printf 'typelisp-host-plan v1\n'
    printf 'action run-scratch-assembly\n'
    printf 'scratch-assembly-path %s:%s\n' "${#SCRATCH_ASM}" "$SCRATCH_ASM"
    printf 'target linux-x86_64\n'
    printf 'backend-mode scalar\n'
    printf 'end\n'
} > "$WORKDIR/host-action-scratch.in"
set +e
"$COMPILER" debug host-action < "$WORKDIR/host-action-scratch.in" \
    > "$WORKDIR/host-action-scratch.stdout" \
    2> "$WORKDIR/host-action-scratch.stderr"
scratch_status=$?
set -e
if [ "$scratch_status" -ne 5 ]; then
    echo "debug host-action scratch expected exit 5, got $scratch_status" >&2
    echo "stdout:" >&2
    sed 's/^/  /' "$WORKDIR/host-action-scratch.stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$WORKDIR/host-action-scratch.stderr" >&2 || true
    exit 1
fi
[ ! -f "$SCRATCH_ASM" ] || {
    echo "debug host-action scratch did not remove $SCRATCH_ASM" >&2
    exit 1
}

echo "stage1 wrapper smoke passed"
