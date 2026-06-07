#!/usr/bin/env sh
set -eu

# Smoke-test a TYPELISP_BIN-compatible host-action CLI surface: compile, check,
# source/package build, run, repl, lsp, doc, test, fmt, and lint. The script
# name is retained for external callers that still invoke the legacy path.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "host-action CLI smoke is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "host-action CLI smoke requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/host-action-cli-smoke"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SRC="$WORKDIR/smoke.tl"
ASM="$WORKDIR/smoke.s"
IR="$WORKDIR/smoke.ir"
BIN="$WORKDIR/smoke-bin"

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
    if ! grep -qF -- "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    fi
}

assert_not_contains() {
    file=$1
    needle=$2
    if grep -qF -- "$needle" "$file"; then
        echo "did not expect '$needle' in $file" >&2
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

lsp_frame_append() {
    frame_file=$1
    frame_body=$2
    frame_len=$(printf '%s' "$frame_body" | wc -c | tr -d ' ')
    {
        printf 'Content-Length: %s\r\n\r\n' "$frame_len"
        printf '%s' "$frame_body"
    } >> "$frame_file"
}

run_capture() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if ! TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@" 3>&2 > "$stdout" 2> "$stderr"; then
        echo "host-action CLI smoke command failed: $label" >&2
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
        echo "host-action CLI smoke command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

run_stdin_expect_failure() {
    label=$1
    input=$2
    shift 2
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    set +e
    "$@" < "$input" > "$stdout" 2> "$stderr"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "host-action CLI smoke command unexpectedly succeeded: $label" >&2
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
        echo "host-action CLI smoke command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

run_expect_failure_cwd() {
    label=$1
    cwd=$2
    shift 2
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    set +e
    (cd "$cwd" && TYPELISP_STAGE1_HEARTBEAT_FD=3 "$@") 3>&2 > "$stdout" 2> "$stderr"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "host-action CLI smoke command unexpectedly succeeded: $label" >&2
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
        echo "host-action CLI smoke command unexpectedly succeeded: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

echo "[host-action-cli] compile"
run_capture compile "$COMPILER" compile "$SRC" -o "$ASM"
[ -f "$ASM" ] || {
    echo "compile did not write $ASM" >&2
    exit 1
}
assert_contains "$WORKDIR/compile.stdout" "Generated: $ASM"

echo "[host-action-cli] compile --emit-ir"
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

run_capture help "$COMPILER" help
assert_empty "$WORKDIR/help.stdout"

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

echo "[host-action-cli] build"
run_capture build "$COMPILER" build "$SRC" -o "$BIN"
[ -x "$BIN" ] || {
    echo "build did not write executable $BIN" >&2
    exit 1
}
assert_contains "$WORKDIR/build.stdout" "Generated: $BIN"

echo "[host-action-cli] package build"
    PKG="$WORKDIR/pkg"
    mkdir -p "$PKG/src/nested/deeper" "$PKG/vendor/math/src"
    cat > "$PKG/typelisp.pkg" <<'EOF'
(package
  (name "stage1_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
    cat > "$PKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 (add-one 41))
EOF
    cat > "$PKG/vendor/math/typelisp.pkg" <<'EOF'
(package
  (name "stage1_math")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    cat > "$PKG/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
    mkdir -p "$PKG/target"
    cat > "$PKG/target/ignored.tl" <<'EOF'
(define (ignored) : i64 true)
EOF
    cat > "$PKG/vendor/math/src/non_entry_bad.tl" <<'EOF'
(define (nested-package-source) : i64 true)
EOF
    run_capture check-package "$COMPILER" check --manifest-path "$PKG/typelisp.pkg"
    assert_empty "$WORKDIR/check-package.stderr"
    assert_contains "$WORKDIR/check-package.stdout" "Type checking passed!"
    run_capture_cwd check-package-discover "$PKG/src/nested/deeper" "$COMPILER" check
    assert_empty "$WORKDIR/check-package-discover.stderr"
    assert_contains "$WORKDIR/check-package-discover.stdout" "Type checking passed!"
    cat > "$PKG/src/non_entry_bad.tl" <<'EOF'
(define (package-non-entry) : i64 true)
EOF
    run_expect_failure check-package-bad "$COMPILER" check --manifest-path "$PKG/typelisp.pkg"
    assert_empty "$WORKDIR/check-package-bad.stdout"
    assert_contains "$WORKDIR/check-package-bad.stderr" "check: package source failed:"
    assert_contains "$WORKDIR/check-package-bad.stderr" "non_entry_bad.tl"
    rm "$PKG/src/non_entry_bad.tl"
    run_expect_failure check-file-manifest "$COMPILER" check "$SRC" --manifest-path "$PKG/typelisp.pkg"
    assert_empty "$WORKDIR/check-file-manifest.stdout"
    assert_contains "$WORKDIR/check-file-manifest.stderr" "cannot combine input path with --manifest-path"
    PKG_OUT_DIR="$PKG/target/typelisp/release/stage1_pkg"
    PKG_BIN="$PKG_OUT_DIR/stage1_pkg"
    PKG_ASM="$PKG_OUT_DIR/stage1_pkg.s"
    MATH_ARCHIVE="$PKG/vendor/math/target/typelisp/release/stage1_math/libstage1_math.a"
    PKG_DEV_OUT_DIR="$PKG/target/typelisp/dev/stage1_pkg"
    PKG_DEV_BIN="$PKG_DEV_OUT_DIR/stage1_pkg"
    PKG_DEV_ASM="$PKG_DEV_OUT_DIR/stage1_pkg.s"
    MATH_DEV_ARCHIVE="$PKG/vendor/math/target/typelisp/dev/stage1_math/libstage1_math.a"
    run_capture build-package "$COMPILER" build --manifest-path "$PKG/typelisp.pkg" --opt-level 0
    [ -x "$PKG_BIN" ] || {
        echo "package build did not write executable $PKG_BIN" >&2
        exit 1
    }
    [ -f "$PKG_ASM" ] || {
        echo "package build did not keep assembly side artifact $PKG_ASM" >&2
        exit 1
    }
    [ -s "$MATH_ARCHIVE" ] || {
        echo "package build did not write dependency archive $MATH_ARCHIVE" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package.stdout" "Generated: $MATH_ARCHIVE"
    assert_contains "$WORKDIR/build-package.stdout" "Generated: $PKG_BIN"
    assert_contains "$PKG_ASM" "main:"
    assert_contains "$PKG_ASM" ".extern _tl_stage1_math_src_lib_add_one"
    assert_not_contains "$PKG_ASM" "_tl_stage1_math_src_lib_add_one:"
    set +e
    "$PKG_BIN" > "$WORKDIR/build-package-bin.stdout" 2> "$WORKDIR/build-package-bin.stderr"
    pkg_bin_status=$?
    set -e
    if [ "$pkg_bin_status" -ne 42 ]; then
        echo "package executable expected exit 42, got $pkg_bin_status" >&2
        exit 1
    fi

    rm -rf "$PKG/target"
    run_capture build-package-dev "$COMPILER" build --manifest-path "$PKG/typelisp.pkg" --profile dev
    [ -x "$PKG_DEV_BIN" ] || {
        echo "package dev profile build did not write executable $PKG_DEV_BIN" >&2
        exit 1
    }
    [ -f "$PKG_DEV_ASM" ] || {
        echo "package dev profile build did not keep assembly side artifact $PKG_DEV_ASM" >&2
        exit 1
    }
    [ -s "$MATH_DEV_ARCHIVE" ] || {
        echo "package dev profile build did not write dependency archive $MATH_DEV_ARCHIVE" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package-dev.stdout" "Generated: $MATH_DEV_ARCHIVE"
    assert_contains "$WORKDIR/build-package-dev.stdout" "Generated: $PKG_DEV_BIN"

    rm -rf "$PKG/target"
    run_capture_cwd build-package-discover "$PKG/src/nested/deeper" "$COMPILER" build
    [ -x "$PKG_BIN" ] || {
        echo "package discovery did not write executable $PKG_BIN" >&2
        exit 1
    }
    [ -f "$PKG_ASM" ] || {
        echo "package discovery did not keep assembly side artifact $PKG_ASM" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package-discover.stdout" "Generated: ../../../target/typelisp/release/stage1_pkg/stage1_pkg"

    LIBPKG="$WORKDIR/libpkg"
    mkdir -p "$LIBPKG/src"
    cat > "$LIBPKG/typelisp.pkg" <<'EOF'
(package
  (name "stage1_lib")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    cat > "$LIBPKG/src/lib.tl" <<'EOF'
(define (add-two [x : i64]) : i64 (+ x 2))
EOF
    LIB_ARCHIVE="$LIBPKG/target/typelisp/release/stage1_lib/libstage1_lib.a"
    run_capture build-package-lib "$COMPILER" build --manifest-path "$LIBPKG/typelisp.pkg"
    [ -s "$LIB_ARCHIVE" ] || {
        echo "package lib build did not write static archive $LIB_ARCHIVE" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package-lib.stdout" "Generated: $LIB_ARCHIVE"

run_expect_failure build-package-missing "$COMPILER" build --manifest-path "$WORKDIR/missing.pkg"
assert_empty "$WORKDIR/build-package-missing.stdout"
assert_contains "$WORKDIR/build-package-missing.stderr" "cannot read package manifest"
run_expect_failure check-package-missing "$COMPILER" check --manifest-path "$WORKDIR/missing.pkg"
assert_empty "$WORKDIR/check-package-missing.stdout"
assert_contains "$WORKDIR/check-package-missing.stderr" "cannot read package manifest"

echo "[host-action-cli] run"
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

echo "[host-action-cli] repl"
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
assert_contains "$WORKDIR/repl-session.stdout" "tl> 3"
assert_empty "$WORKDIR/repl-session.stderr"

run_expect_failure repl-args "$COMPILER" repl unexpected
assert_empty "$WORKDIR/repl-args.stdout"
assert_contains "$WORKDIR/repl-args.stderr" "Error: repl does not accept arguments"

echo "[host-action-cli] lsp"
LSP_INIT="$WORKDIR/lsp-init-shutdown.in"
: > "$LSP_INIT"
lsp_frame_append "$LSP_INIT" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
lsp_frame_append "$LSP_INIT" '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
run_stdin_capture lsp-init-shutdown "$LSP_INIT" "$COMPILER" lsp
assert_empty "$WORKDIR/lsp-init-shutdown.stderr"
assert_contains "$WORKDIR/lsp-init-shutdown.stdout" '"id":1'
assert_contains "$WORKDIR/lsp-init-shutdown.stdout" '"textDocumentSync"'
assert_contains "$WORKDIR/lsp-init-shutdown.stdout" '"id":2'

printf 'X-Test: 1\r\n\r\n' > "$WORKDIR/lsp-missing-length.in"
run_stdin_expect_failure lsp-missing-length "$WORKDIR/lsp-missing-length.in" "$COMPILER" lsp
assert_contains "$WORKDIR/lsp-missing-length.stdout" '"code":-32700'
assert_contains "$WORKDIR/lsp-missing-length.stderr" "lsp: missing Content-Length"

LSP_DIAG="$WORKDIR/lsp-diagnostics.in"
LSP_PROJECT="$WORKDIR/lsp-project"
mkdir -p "$LSP_PROJECT"
LSP_URI="file://$LSP_PROJECT/main.tl"
: > "$LSP_DIAG"
lsp_frame_append "$LSP_DIAG" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
lsp_frame_append "$LSP_DIAG" '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$LSP_URI"'","languageId":"typelisp","version":1,"text":"(define (main) : i64 true)"}}}'
lsp_frame_append "$LSP_DIAG" '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"'"$LSP_URI"'","version":2},"contentChanges":[{"text":"(define (main) : i64 0)"}]}}'
lsp_frame_append "$LSP_DIAG" '{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"'"$LSP_URI"'"}}}'
run_stdin_capture lsp-diagnostics "$LSP_DIAG" "$COMPILER" lsp
assert_empty "$WORKDIR/lsp-diagnostics.stderr"
assert_contains "$WORKDIR/lsp-diagnostics.stdout" '"code":"E0200"'
assert_contains "$WORKDIR/lsp-diagnostics.stdout" "typecheck: return type mismatch"
assert_contains "$WORKDIR/lsp-diagnostics.stdout" '"diagnostics":[]'

echo "[host-action-cli] doc"
DOC_DIR="$WORKDIR/doc"
    DOC_STDLIB="$DOC_DIR/stdlib"
    DOC_ENTRY="$DOC_DIR/entry.tl"
    DOC_LOCAL="$DOC_DIR/local.tl"
    DOC_STDLIB_SOURCE="$DOC_STDLIB/docfixture.tl"
    DOC_MD="$DOC_DIR/entry.md"
    mkdir -p "$DOC_STDLIB"
    cat > "$DOC_LOCAL" <<'EOF'
;# Local module docs.

;: Local answer docs.
(define local-answer : i64 7)
EOF
    cat > "$DOC_STDLIB_SOURCE" <<'EOF'
;# Stdlib module docs.

;: Stdlib answer docs.
(define stdlib-answer : i64 35)
EOF
    cat > "$DOC_ENTRY" <<'EOF'
;# Entry module docs.
;# ```typelisp
;# (import "stdlib/docfixture.tl")
;# (define (main) : i64 stdlib-answer)
;# ```

(import "local.tl")
(import "stdlib/docfixture.tl")

;: Entry docs.
(define (main) : i64 (+ local-answer stdlib-answer))
EOF
    run_capture doc "$COMPILER" doc "$DOC_ENTRY" -o "$DOC_MD" --stdlib-root "$DOC_STDLIB"
    assert_empty "$WORKDIR/doc.stderr"
    assert_contains "$WORKDIR/doc.stdout" "Generated: $DOC_MD"
    assert_contains "$DOC_MD" "Entry module docs."
    assert_contains "$DOC_MD" "Local module docs."
    assert_contains "$DOC_MD" "Stdlib module docs."

    echo "[host-action-cli] doc --test"
    run_capture doc-test "$COMPILER" doc --test "$DOC_ENTRY" --stdlib-root "$DOC_STDLIB"
    assert_empty "$WORKDIR/doc-test.stderr"
assert_contains "$WORKDIR/doc-test.stdout" "Doc tests passed: 1 example(s)"

echo "[host-action-cli] test --check"
    TEST_SRC="$WORKDIR/inline-test.tl"
    cat > "$TEST_SRC" <<'EOF'
(import "stdlib/test.tl")

(define (inc [x : i64]) : i64 (+ x 1))

(test inc-basic
  (assert-i64-eq (inc 41) 42 "inc result"))
EOF
    run_capture test-check "$COMPILER" test --check "$TEST_SRC" --target linux-x86_64 --opt-level 2 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-check.stderr"
    assert_contains "$WORKDIR/test-check.stdout" "TypeLisp test typecheck passed: 1 test(s)"

    echo "[host-action-cli] test"
    run_capture test-run "$COMPILER" test "$TEST_SRC" --opt-level 1 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-run.stdout"
    assert_contains "$WORKDIR/test-run.stderr" "test inc-basic"
    assert_contains "$WORKDIR/test-run.stderr" "ok inc-basic"
    assert_contains "$WORKDIR/test-run.stderr" "TypeLisp tests passed: 1 test(s)"
    [ ! -f "$TEST_SRC.test.s" ] || {
        echo "test left scratch assembly behind: $TEST_SRC.test.s" >&2
        exit 1
    }

    echo "[host-action-cli] test no-tests"
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

    echo "[host-action-cli] test package discovery"
    TEST_PKG="$WORKDIR/inline-test-pkg"
    mkdir -p "$TEST_PKG/src/nested" "$TEST_PKG/target/ignored" \
        "$TEST_PKG/vendor/child/src" "$TEST_PKG/tests/nested" \
        "$TEST_PKG/tests/target/ignored" "$TEST_PKG/tests/vendor/child/src"
    cat > "$TEST_PKG/typelisp.pkg" <<'EOF'
(package
  (name "inline_test_pkg")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    cat > "$TEST_PKG/src/lib.tl" <<'EOF'
(import "stdlib/test.tl")

(define (inc [x : i64]) : i64 (+ x 1))

(test pkg-entry
  (if (= (inc 41) 42)
    unit
    (let [_ : i64 (/ 1 0)] unit)))
EOF
    cat > "$TEST_PKG/src/nested/more.tl" <<'EOF'
(test pkg-nested
  (if (= (+ 20 22) 42)
    unit
    (let [_ : i64 (/ 1 0)] unit)))
EOF
    cat > "$TEST_PKG/src/no-tests.tl" <<'EOF'
(define package-no-test-value : i64 42)
EOF
    i=0
    while [ "$i" -lt 2500 ]; do
        printf '(define package-large-no-inline-%s : i64 %s)\n' "$i" "$i"
        i=$((i + 1))
    done > "$TEST_PKG/src/large-no-inline.tl"
    cat > "$TEST_PKG/target/ignored/fail.tl" <<'EOF'
(test ignored-target
  (panic "target directory inline test should be ignored"))
EOF
    cat > "$TEST_PKG/vendor/child/typelisp.pkg" <<'EOF'
(package (name "child") (version "0.1.0") (kind "lib"))
EOF
    cat > "$TEST_PKG/vendor/child/src/fail.tl" <<'EOF'
(test ignored-nested-package
  (panic "nested package inline test should be ignored"))
EOF
    cat > "$TEST_PKG/tests/basic.tl" <<'EOF'
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-i64-eq (+ 21 21) 42 "package tests dir basic")
    0))
EOF
    cat > "$TEST_PKG/tests/nested/more.tl" <<'EOF'
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-i64-eq (* 6 7) 42 "package nested tests dir")
    0))
EOF
    cat > "$TEST_PKG/tests/target/ignored/fail.tl" <<'EOF'
(define (main) : i64 9)
EOF
    cat > "$TEST_PKG/tests/vendor/child/typelisp.pkg" <<'EOF'
(package (name "child-tests") (version "0.1.0") (kind "lib"))
EOF
    cat > "$TEST_PKG/tests/vendor/child/src/fail.tl" <<'EOF'
(define (main) : i64 9)
EOF
    run_capture_cwd test-package-check "$TEST_PKG/src/nested" "$COMPILER" test --check --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-package-check.stderr"
    assert_contains "$WORKDIR/test-package-check.stdout" "TypeLisp test file:"
    assert_contains "$WORKDIR/test-package-check.stdout" "TypeLisp integration test file:"
    assert_contains "$WORKDIR/test-package-check.stdout" "TypeLisp package test typecheck passed: 4 test(s) in 4 file(s)"
    run_capture_cwd test-package-run "$TEST_PKG/src/nested" "$COMPILER" test --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-package-run.stdout" "TypeLisp integration test file:"
    assert_contains "$WORKDIR/test-package-run.stdout" "TypeLisp package tests passed: 4 test(s) in 4 file(s)"
    assert_contains "$WORKDIR/test-package-run.stderr" "test pkg-entry"
    assert_contains "$WORKDIR/test-package-run.stderr" "ok pkg-entry"
    assert_contains "$WORKDIR/test-package-run.stderr" "test pkg-nested"
    assert_contains "$WORKDIR/test-package-run.stderr" "ok pkg-nested"

    TEST_EMPTY_PKG="$WORKDIR/inline-test-empty-pkg"
    mkdir -p "$TEST_EMPTY_PKG/src"
    cat > "$TEST_EMPTY_PKG/typelisp.pkg" <<'EOF'
(package
  (name "inline_test_empty_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
    cat > "$TEST_EMPTY_PKG/src/main.tl" <<'EOF'
(define (main) : i64 0)
EOF
    run_capture_cwd test-package-no-tests "$TEST_EMPTY_PKG" "$COMPILER" test --check --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-package-no-tests.stderr"
    assert_contains "$WORKDIR/test-package-no-tests.stdout" "TypeLisp package test typecheck passed: 0 test(s) in 0 file(s)"

    echo "[host-action-cli] test failures"
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
        echo "host-action CLI test failure case unexpectedly succeeded" >&2
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

    FAIL_PKG="$WORKDIR/integration-test-fail-pkg"
    mkdir -p "$FAIL_PKG/src" "$FAIL_PKG/tests"
    cat > "$FAIL_PKG/typelisp.pkg" <<'EOF'
(package
  (name "integration_test_fail_pkg")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    cat > "$FAIL_PKG/src/lib.tl" <<'EOF'
(define lib-value : i64 42)
EOF
    cat > "$FAIL_PKG/tests/fail.tl" <<'EOF'
(define (main) : i64 7)
EOF
    set +e
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test --target linux-x86_64 --manifest-path "$FAIL_PKG/typelisp.pkg" 3>&2 > "$WORKDIR/test-package-integration-fail.stdout" 2> "$WORKDIR/test-package-integration-fail.stderr"
    pkg_fail_status=$?
    set -e
    if [ "$pkg_fail_status" -ne 1 ]; then
        echo "host-action CLI package integration failure exited $pkg_fail_status, expected 1" >&2
        exit 1
    fi
    assert_contains "$WORKDIR/test-package-integration-fail.stdout" "TypeLisp integration test file:"
    assert_contains "$WORKDIR/test-package-integration-fail.stderr" "typelisp test: test executable exited with exit status: 7"

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
        echo "host-action CLI test compile-error case unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$WORKDIR/test-bad.stdout"
    assert_contains "$WORKDIR/test-bad.stderr" "typecheck: unbound name missing-inline-test-name"

    set +e
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test "$TEST_SRC" --opt-level 3>&2 > "$WORKDIR/test-missing-opt.stdout" 2> "$WORKDIR/test-missing-opt.stderr"
    missing_opt_status=$?
    set -e
    if [ "$missing_opt_status" -eq 0 ]; then
        echo "host-action CLI test missing-opt-level case unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$WORKDIR/test-missing-opt.stdout"
    assert_contains "$WORKDIR/test-missing-opt.stderr" "test: --opt-level requires a value"

    set +e
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test --check "$TEST_SRC" --target nope 3>&2 > "$WORKDIR/test-bad-target.stdout" 2> "$WORKDIR/test-bad-target.stderr"
    bad_target_status=$?
    set -e
    if [ "$bad_target_status" -eq 0 ]; then
        echo "host-action CLI test bad-target case unexpectedly succeeded" >&2
        exit 1
    fi
assert_empty "$WORKDIR/test-bad-target.stdout"
assert_contains "$WORKDIR/test-bad-target.stderr" "test: unknown target nope"

echo "[host-action-cli] fmt"
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

cat > "$WORKDIR/fmt-changed.tl" <<'EOF'
(define (main) : i64
(+ 1 2))
EOF
cp "$WORKDIR/fmt-changed.tl" "$WORKDIR/fmt-changed.expected"
run_expect_failure fmt-check-changed "$COMPILER" fmt --check "$WORKDIR/fmt-changed.tl"
assert_empty "$WORKDIR/fmt-check-changed.stdout"
assert_contains "$WORKDIR/fmt-check-changed.stderr" "fmt: would reformat"
check_file_exact "$WORKDIR/fmt-changed.tl" "$WORKDIR/fmt-changed.expected"

run_expect_failure fmt-missing "$COMPILER" fmt "$WORKDIR/missing.tl"
assert_empty "$WORKDIR/fmt-missing.stdout"
assert_nonempty "$WORKDIR/fmt-missing.stderr"

printf '(define (' > "$WORKDIR/fmt-parse-error.tl"
run_expect_failure fmt-parse-error "$COMPILER" fmt "$WORKDIR/fmt-parse-error.tl"
assert_empty "$WORKDIR/fmt-parse-error.stdout"
assert_nonempty "$WORKDIR/fmt-parse-error.stderr"

FMTLINT_PKG="$WORKDIR/fmtlint-pkg"
mkdir -p "$FMTLINT_PKG/src/nested/deeper"
cat > "$FMTLINT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "stage1_fmtlint")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
cat > "$FMTLINT_PKG/src/main.tl" <<'EOF'
(define (main) : i64 0)
EOF
cat > "$FMTLINT_PKG/src/needs_fmt.tl" <<'EOF'
(define (needs-format) : i64
(+ 1 2))
EOF
cat > "$FMTLINT_PKG/src/lint_bad.tl" <<'EOF'
(define (classify [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))
EOF
run_expect_failure fmt-package-check "$COMPILER" fmt --manifest-path "$FMTLINT_PKG/typelisp.pkg" --check
assert_empty "$WORKDIR/fmt-package-check.stdout"
assert_contains "$WORKDIR/fmt-package-check.stderr" "needs_fmt.tl"
run_capture fmt-package-rewrite "$COMPILER" fmt --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/fmt-package-rewrite.stdout"
assert_empty "$WORKDIR/fmt-package-rewrite.stderr"
assert_contains "$FMTLINT_PKG/src/needs_fmt.tl" "  (+ 1 2)"
run_capture_cwd fmt-package-discover "$FMTLINT_PKG/src/nested/deeper" "$COMPILER" fmt --check
assert_empty "$WORKDIR/fmt-package-discover.stdout"
assert_empty "$WORKDIR/fmt-package-discover.stderr"
run_expect_failure fmt-file-manifest "$COMPILER" fmt "$SRC" --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/fmt-file-manifest.stdout"
assert_contains "$WORKDIR/fmt-file-manifest.stderr" "cannot combine input paths with --manifest-path"
FMT_NOPKG=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-fmt-nopkg.XXXXXX")
run_expect_failure_cwd fmt-no-manifest "$FMT_NOPKG" "$COMPILER" fmt --check
assert_empty "$WORKDIR/fmt-no-manifest.stdout"
assert_contains "$WORKDIR/fmt-no-manifest.stderr" "could not find typelisp.pkg"
rm -rf "$FMT_NOPKG"

echo "[host-action-cli] lint"
assert_contains "$WORKDIR/help.stderr" "typelisp lint [<file.tl>...] [--check] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]"

LINT_NOPKG=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-lint-nopkg.XXXXXX")
run_expect_failure_cwd lint-missing "$LINT_NOPKG" "$COMPILER" lint
assert_empty "$WORKDIR/lint-missing.stdout"
assert_contains "$WORKDIR/lint-missing.stderr" "could not find typelisp.pkg"
rm -rf "$LINT_NOPKG"

run_capture lint-clean "$COMPILER" lint "$SRC"
assert_empty "$WORKDIR/lint-clean.stderr"
assert_contains "$WORKDIR/lint-clean.stdout" "lint: 0 finding(s)"

run_capture lint-clean-check "$COMPILER" lint "$SRC" --check
assert_empty "$WORKDIR/lint-clean-check.stderr"
assert_contains "$WORKDIR/lint-clean-check.stdout" "lint: 0 finding(s)"

LINT_SRC="$WORKDIR/lint_ladder.tl"
cat > "$LINT_SRC" <<'EOF'
(define (classify [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))
EOF
run_capture lint-nested-if "$COMPILER" lint "$LINT_SRC"
assert_empty "$WORKDIR/lint-nested-if.stderr"
assert_contains "$WORKDIR/lint-nested-if.stdout" "lint_ladder.tl:"
assert_contains "$WORKDIR/lint-nested-if.stdout" "nested if-ladder"
assert_contains "$WORKDIR/lint-nested-if.stdout" "prefer cond"
assert_contains "$WORKDIR/lint-nested-if.stdout" "match"
assert_contains "$WORKDIR/lint-nested-if.stdout" "lint: 1 finding(s)"

run_expect_failure lint-nested-if-check "$COMPILER" lint "$LINT_SRC" --check
assert_empty "$WORKDIR/lint-nested-if-check.stderr"
assert_contains "$WORKDIR/lint-nested-if-check.stdout" "lint_ladder.tl:"
assert_contains "$WORKDIR/lint-nested-if-check.stdout" "nested if-ladder"
assert_contains "$WORKDIR/lint-nested-if-check.stdout" "lint: 1 finding(s)"

run_capture lint-multi "$COMPILER" lint "$SRC" "$LINT_SRC"
assert_empty "$WORKDIR/lint-multi.stderr"
assert_contains "$WORKDIR/lint-multi.stdout" "--- $SRC"
assert_contains "$WORKDIR/lint-multi.stdout" "--- $LINT_SRC"
assert_contains "$WORKDIR/lint-multi.stdout" "lint_ladder.tl:"
assert_contains "$WORKDIR/lint-multi.stdout" "lint: 0 finding(s)"
assert_contains "$WORKDIR/lint-multi.stdout" "lint: 1 finding(s)"
lint_multi_clean_line=$(grep -nF -- "--- $SRC" "$WORKDIR/lint-multi.stdout" | head -n 1 | cut -d: -f1)
lint_multi_ladder_line=$(grep -nF -- "--- $LINT_SRC" "$WORKDIR/lint-multi.stdout" | head -n 1 | cut -d: -f1)
if [ "$lint_multi_clean_line" -ge "$lint_multi_ladder_line" ]; then
    fail "lint multi-file output did not preserve input path order"
fi

run_expect_failure lint-package-check "$COMPILER" lint --manifest-path "$FMTLINT_PKG/typelisp.pkg" --check
assert_empty "$WORKDIR/lint-package-check.stderr"
assert_contains "$WORKDIR/lint-package-check.stdout" "lint_bad.tl:"
assert_contains "$WORKDIR/lint-package-check.stdout" "lint: 1 finding(s)"
run_capture_cwd lint-package-discover "$FMTLINT_PKG/src/nested/deeper" "$COMPILER" lint
assert_empty "$WORKDIR/lint-package-discover.stderr"
assert_contains "$WORKDIR/lint-package-discover.stdout" "lint_bad.tl:"
run_expect_failure lint-file-manifest "$COMPILER" lint "$SRC" --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/lint-file-manifest.stdout"
assert_contains "$WORKDIR/lint-file-manifest.stderr" "cannot combine input paths with --manifest-path"
run_expect_failure lint-files-manifest "$COMPILER" lint "$SRC" "$LINT_SRC" --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/lint-files-manifest.stdout"
assert_contains "$WORKDIR/lint-files-manifest.stderr" "cannot combine input paths with --manifest-path"

run_expect_failure lint-missing-file "$COMPILER" lint "$WORKDIR/missing-lint.tl"
assert_empty "$WORKDIR/lint-missing-file.stdout"
assert_nonempty "$WORKDIR/lint-missing-file.stderr"

printf '(define (' > "$WORKDIR/lint-parse-error.tl"
run_expect_failure lint-parse-error "$COMPILER" lint "$WORKDIR/lint-parse-error.tl"
assert_empty "$WORKDIR/lint-parse-error.stdout"
assert_nonempty "$WORKDIR/lint-parse-error.stderr"

run_expect_failure lint-parse-error-check "$COMPILER" lint "$WORKDIR/lint-parse-error.tl" --check
assert_empty "$WORKDIR/lint-parse-error-check.stdout"
assert_nonempty "$WORKDIR/lint-parse-error-check.stderr"

echo "host-action CLI smoke passed"
