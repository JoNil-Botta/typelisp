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

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

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

assert_contains_any() {
    file=$1
    shift
    for needle in "$@"; do
        if grep -qF -- "$needle" "$file"; then
            return 0
        fi
    done
    echo "expected one of the accepted snippets in $file" >&2
    for needle in "$@"; do
        echo "  $needle" >&2
    done
    sed 's/^/  /' "$file" >&2 || true
    exit 1
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
signature_colon
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
# cli-gate-case stage1-wrapper-compile wrapper run_capture
run_capture compile "$COMPILER" compile "$SRC" -o "$ASM"
[ -f "$ASM" ] || {
    echo "compile did not write $ASM" >&2
    exit 1
}
assert_contains "$WORKDIR/compile.stdout" "Wrote $ASM"

# A source without `main` takes the compiler-synthesis path that creates the
# fallback entry AST after parsing. Its generated names are intentionally not
# required to have parser-token provenance.
SYNTH_SRC="$WORKDIR/synthesized-entry.tl"
SYNTH_ASM="$WORKDIR/synthesized-entry.s"
cat > "$SYNTH_SRC" <<'EOF'
(define SYNTHETIC-VALUE : i64 7)
EOF
# cli-gate-case stage1-wrapper-compile-synthesized-entry wrapper run_capture
run_capture compile-synthesized-entry \
    "$COMPILER" compile "$SYNTH_SRC" -o "$SYNTH_ASM"
[ -f "$SYNTH_ASM" ] || {
    echo "synthesized-entry compile did not write $SYNTH_ASM" >&2
    exit 1
}
assert_contains "$WORKDIR/compile-synthesized-entry.stdout" "Wrote $SYNTH_ASM"

CFG_SRC="$WORKDIR/cfg-feature.tl"
CFG_ASM="$WORKDIR/cfg-feature.s"
cat > "$CFG_SRC" <<'EOF'
(import "stdlib/string.tl")
(cfg feature (define marker : String "enabled-cfg-feature"))
(cfg (not feature) (define marker : String "disabled-cfg-feature"))
(define (main) : i64 (string-length marker))
EOF
# cli-gate-case stage1-wrapper-compile-cfg wrapper run_capture
run_capture compile-cfg "$COMPILER" compile "$CFG_SRC" -o "$CFG_ASM" --cfg feature
assert_contains "$CFG_ASM" "enabled-cfg-feature"
assert_not_contains "$CFG_ASM" "disabled-cfg-feature"

CFG_BATCH_ONE="$WORKDIR/cfg-batch-one.tl"
CFG_BATCH_TWO="$WORKDIR/cfg-batch-two.tl"
CFG_BATCH_ONE_ASM="$WORKDIR/cfg-batch-one.s"
CFG_BATCH_TWO_ASM="$WORKDIR/cfg-batch-two.s"
CFG_BATCH_LIST="$WORKDIR/cfg-batch.txt"
cat > "$CFG_BATCH_ONE" <<'EOF'
(import "stdlib/string.tl")
(cfg feature (define marker : String "enabled-cfg-batch-one"))
(cfg (not feature) (define marker : String "disabled-cfg-batch-one"))
(define (main) : i64 (string-length marker))
EOF
cat > "$CFG_BATCH_TWO" <<'EOF'
(import "stdlib/string.tl")
(cfg feature (define marker : String "enabled-cfg-batch-two"))
(cfg (not feature) (define marker : String "disabled-cfg-batch-two"))
(define (main) : i64 (string-length marker))
EOF
printf '%s|%s\n%s|%s\n' \
    "$CFG_BATCH_ONE" "$CFG_BATCH_ONE_ASM" \
    "$CFG_BATCH_TWO" "$CFG_BATCH_TWO_ASM" \
    > "$CFG_BATCH_LIST"
# cli-gate-case stage1-wrapper-compile-cfg-batch wrapper run_capture
run_capture compile-cfg-batch "$COMPILER" compile --batch "$CFG_BATCH_LIST" --cfg feature
assert_contains "$CFG_BATCH_ONE_ASM" "enabled-cfg-batch-one"
assert_not_contains "$CFG_BATCH_ONE_ASM" "disabled-cfg-batch-one"
assert_contains "$CFG_BATCH_TWO_ASM" "enabled-cfg-batch-two"
assert_not_contains "$CFG_BATCH_TWO_ASM" "disabled-cfg-batch-two"

echo "[host-action-cli] compile --emit-ir"
# cli-gate-case stage1-wrapper-compile-ir wrapper run_capture
run_capture compile-ir "$COMPILER" compile "$SRC" --emit-ir
[ -f "$IR" ] || {
    echo "compile --emit-ir did not write $IR" >&2
    exit 1
}
assert_contains "$WORKDIR/compile-ir.stdout" "Wrote $IR"
assert_contains "$IR" "typelisp-ir-summary v1"

# cli-gate-case stage1-wrapper-compile-missing-source wrapper run_expect_failure
run_expect_failure compile-missing-source "$COMPILER" compile
assert_empty "$WORKDIR/compile-missing-source.stdout"
assert_contains "$WORKDIR/compile-missing-source.stderr" "compile: expected source path"

# cli-gate-case stage1-wrapper-help wrapper run_capture
run_capture help "$COMPILER" help
assert_empty "$WORKDIR/help.stdout"

# cli-gate-case stage1-wrapper-check wrapper run_capture
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
# cli-gate-case stage1-wrapper-check-stdlib-root wrapper run_capture
run_capture check-stdlib-root "$COMPILER" check "$CHECK_ROOT/app/main.tl" --stdlib-root "$CHECK_ROOT/repo-stdlib"
assert_empty "$WORKDIR/check-stdlib-root.stderr"
assert_contains "$WORKDIR/check-stdlib-root.stdout" "Type checking passed!"
cp "$WORKDIR/check-stdlib-root.stdout" "$WORKDIR/check-stdlib-root.expected"

echo "[host-action-cli] build"
# cli-gate-case stage1-wrapper-build wrapper run_capture
run_capture build "$COMPILER" build "$SRC" -o "$BIN"
[ -x "$BIN" ] || {
    echo "build did not write executable $BIN" >&2
    exit 1
}
assert_contains "$WORKDIR/build.stdout" "Built $BIN"

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
(import "macros.tl" module stage1.macros as macros)
(define (main) : i64 (macros.add-one-macro 41))
EOF
    cat > "$PKG/src/macros.tl" <<'EOF'
(module stage1.macros)
(import "pkg:math/src/lib.tl")
(define stage1-exported-value : i64 7)
(defstruct Stage1Point
  (x i64)
  (y i64))
(defenum Stage1Tag
  (Stage1A)
  (Stage1B i64))
(defmacro (add-one-macro [value : i64]) : i64
  `(add-one ,value))
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
    # cli-gate-case stage1-wrapper-check-package wrapper run_capture
    run_capture check-package "$COMPILER" check --manifest-path "$PKG/typelisp.pkg"
    assert_empty "$WORKDIR/check-package.stderr"
    assert_contains "$WORKDIR/check-package.stdout" "Type checking passed!"
    # cli-gate-case stage1-wrapper-check-package-discover wrapper run_capture_cwd
    run_capture_cwd check-package-discover "$PKG/src/nested/deeper" "$COMPILER" check
    assert_empty "$WORKDIR/check-package-discover.stderr"
    assert_contains "$WORKDIR/check-package-discover.stdout" "Type checking passed!"
    BAD_PKG_SOURCE="$PKG/src/non_entry_bad.tl"
    cat > "$BAD_PKG_SOURCE" <<'EOF'
(define (package-non-entry) : i64 true)
EOF
    # cli-gate-case stage1-wrapper-check-package-orphan-bad wrapper run_capture
    run_capture check-package-orphan-bad "$COMPILER" check --manifest-path "$PKG/typelisp.pkg"
    assert_empty "$WORKDIR/check-package-orphan-bad.stderr"
    assert_contains "$WORKDIR/check-package-orphan-bad.stdout" "Type checking passed!"
    # cli-gate-case stage1-wrapper-check-file-bad wrapper run_expect_failure
    run_expect_failure check-file-bad "$COMPILER" check "$BAD_PKG_SOURCE"
    assert_empty "$WORKDIR/check-file-bad.stdout"
    assert_contains "$WORKDIR/check-file-bad.stderr" "non_entry_bad.tl"
    assert_not_contains "$WORKDIR/check-file-bad.stderr" "${BAD_PKG_SOURCE}${BAD_PKG_SOURCE}"
    rm "$BAD_PKG_SOURCE"
    # cli-gate-case stage1-wrapper-check-file-manifest wrapper run_expect_failure
    run_expect_failure check-file-manifest "$COMPILER" check "$SRC" --manifest-path "$PKG/typelisp.pkg"
    assert_empty "$WORKDIR/check-file-manifest.stdout"
    assert_contains "$WORKDIR/check-file-manifest.stderr" "cannot combine input path with --manifest-path"
    PKG_OUT_DIR="$PKG/target/release"
    PKG_BIN="$PKG_OUT_DIR/stage1_pkg"
    PKG_ASM="$PKG_OUT_DIR/stage1_pkg.s"
    PKG_TLCI="$PKG_OUT_DIR/stage1_pkg.tlci"
    MATH_ARCHIVE="$PKG/vendor/math/target/release/libstage1_math.a"
    MATH_TLCI="$PKG/vendor/math/target/release/stage1_math.tlci"
    PKG_DEV_OUT_DIR="$PKG/target/dev"
    PKG_DEV_BIN="$PKG_DEV_OUT_DIR/stage1_pkg"
    PKG_DEV_ASM="$PKG_DEV_OUT_DIR/stage1_pkg.s"
    PKG_DEV_TLCI="$PKG_DEV_OUT_DIR/stage1_pkg.tlci"
    MATH_DEV_ARCHIVE="$PKG/vendor/math/target/dev/libstage1_math.a"
    MATH_DEV_TLCI="$PKG/vendor/math/target/dev/stage1_math.tlci"
    # cli-gate-case stage1-wrapper-build-package wrapper run_capture
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
    [ -s "$PKG_TLCI" ] || {
        echo "package build did not write tlci image $PKG_TLCI" >&2
        exit 1
    }
    [ -s "$MATH_TLCI" ] || {
        echo "package build did not write dependency tlci image $MATH_TLCI" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package.stdout" "Built $MATH_ARCHIVE"
    assert_contains "$WORKDIR/build-package.stdout" "Built $PKG_BIN"
    assert_contains "$WORKDIR/build-package.stdout" "Built $MATH_TLCI"
    assert_contains "$WORKDIR/build-package.stdout" "Built $PKG_TLCI"
    assert_contains "$PKG_ASM" "main:"
    assert_contains "$PKG_ASM" ".extern _tl_stage1_math_src_lib_add_one"
    assert_not_contains "$PKG_ASM" "_tl_stage1_math_src_lib_add_one:"
    # cli-gate-case stage1-wrapper-inspect-package-tlci wrapper run_capture
    run_capture inspect-package-tlci "$COMPILER" inspect "$PKG_TLCI"
    PRODUCER_IDENTITY=$($COMPILER --producer-identity)
    assert_empty "$WORKDIR/inspect-package-tlci.stderr"
    assert_contains "$WORKDIR/inspect-package-tlci.stdout" "tlci image"
    assert_contains "$WORKDIR/inspect-package-tlci.stdout" "package-name: stage1_pkg"
    assert_contains "$WORKDIR/inspect-package-tlci.stdout" "producer-compiler-identity: $PRODUCER_IDENTITY"
    assert_contains "$WORKDIR/inspect-package-tlci.stdout" "code: offset="
    assert_not_contains "$WORKDIR/inspect-package-tlci.stdout" "code: offset=0 bytes=0"
    assert_not_contains "$WORKDIR/inspect-package-tlci.stdout" "  (none)"
    cp "$PKG_TLCI" "$WORKDIR/stage1_pkg.first.tlci"
    # cli-gate-case stage1-wrapper-build-package-repeat wrapper run_capture
    run_capture build-package-repeat "$COMPILER" build --manifest-path "$PKG/typelisp.pkg" --opt-level 0
    if ! cmp -s "$WORKDIR/stage1_pkg.first.tlci" "$PKG_TLCI"; then
        echo "package build rewrote $PKG_TLCI nondeterministically" >&2
        exit 1
    fi
    BAD_TLCI="$WORKDIR/bad.tlci"
    printf 'bad' > "$BAD_TLCI"
    # cli-gate-case stage1-wrapper-inspect-bad-tlci wrapper run_expect_failure
    run_expect_failure inspect-bad-tlci "$COMPILER" inspect "$BAD_TLCI"
    assert_empty "$WORKDIR/inspect-bad-tlci.stdout"
    assert_contains "$WORKDIR/inspect-bad-tlci.stderr" "inspect: $BAD_TLCI: tlci: truncated header"
    set +e
    "$PKG_BIN" > "$WORKDIR/build-package-bin.stdout" 2> "$WORKDIR/build-package-bin.stderr"
    pkg_bin_status=$?
    set -e
    if [ "$pkg_bin_status" -ne 42 ]; then
        echo "package executable expected exit 42, got $pkg_bin_status" >&2
        exit 1
    fi

    rm -rf "$PKG/target"
    # cli-gate-case stage1-wrapper-build-package-dev wrapper run_capture
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
    [ -s "$PKG_DEV_TLCI" ] || {
        echo "package dev profile build did not write tlci image $PKG_DEV_TLCI" >&2
        exit 1
    }
    [ -s "$MATH_DEV_TLCI" ] || {
        echo "package dev profile build did not write dependency tlci image $MATH_DEV_TLCI" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package-dev.stdout" "Built $MATH_DEV_ARCHIVE"
    assert_contains "$WORKDIR/build-package-dev.stdout" "Built $PKG_DEV_BIN"
    assert_contains "$WORKDIR/build-package-dev.stdout" "Built $MATH_DEV_TLCI"
    assert_contains "$WORKDIR/build-package-dev.stdout" "Built $PKG_DEV_TLCI"

    rm -rf "$PKG/target"
    # cli-gate-case stage1-wrapper-build-package-discover wrapper run_capture_cwd
    run_capture_cwd build-package-discover "$PKG/src/nested/deeper" "$COMPILER" build
    [ -x "$PKG_BIN" ] || {
        echo "package discovery did not write executable $PKG_BIN" >&2
        exit 1
    }
    [ -f "$PKG_ASM" ] || {
        echo "package discovery did not keep assembly side artifact $PKG_ASM" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package-discover.stdout" "Built ../../../target/release/stage1_pkg"

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
    LIB_ARCHIVE="$LIBPKG/target/release/libstage1_lib.a"
    LIB_TLCI="$LIBPKG/target/release/stage1_lib.tlci"
    # cli-gate-case stage1-wrapper-build-package-lib wrapper run_capture
    run_capture build-package-lib "$COMPILER" build --manifest-path "$LIBPKG/typelisp.pkg"
    [ -s "$LIB_ARCHIVE" ] || {
        echo "package lib build did not write static archive $LIB_ARCHIVE" >&2
        exit 1
    }
    [ -s "$LIB_TLCI" ] || {
        echo "package lib build did not write tlci image $LIB_TLCI" >&2
        exit 1
    }
    assert_contains "$WORKDIR/build-package-lib.stdout" "Built $LIB_ARCHIVE"
    assert_contains "$WORKDIR/build-package-lib.stdout" "Built $LIB_TLCI"

# cli-gate-case stage1-wrapper-build-package-missing wrapper run_expect_failure
run_expect_failure build-package-missing "$COMPILER" build --manifest-path "$WORKDIR/missing.pkg"
assert_empty "$WORKDIR/build-package-missing.stdout"
assert_contains "$WORKDIR/build-package-missing.stderr" "cannot read package manifest"
# cli-gate-case stage1-wrapper-check-package-missing wrapper run_expect_failure
run_expect_failure check-package-missing "$COMPILER" check --manifest-path "$WORKDIR/missing.pkg"
assert_empty "$WORKDIR/check-package-missing.stdout"
assert_contains "$WORKDIR/check-package-missing.stderr" "cannot read package manifest"

echo "[host-action-cli] run"
set +e
# cli-gate-case stage1-wrapper-run direct "$COMPILER"
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

RUN_CFG_SRC="$WORKDIR/run-cfg.tl"
cat > "$RUN_CFG_SRC" <<'EOF'
(define (main) : i64 (cfg feature 11 3))
EOF
set +e
# cli-gate-case stage1-wrapper-run-cfg direct "$COMPILER"
"$COMPILER" run "$RUN_CFG_SRC" --cfg feature > "$WORKDIR/run-cfg.stdout" 2> "$WORKDIR/run-cfg.stderr"
run_cfg_status=$?
set -e
if [ "$run_cfg_status" -ne 11 ]; then
    echo "run --cfg expected exit 11, got $run_cfg_status" >&2
    echo "stdout:" >&2
    sed 's/^/  /' "$WORKDIR/run-cfg.stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$WORKDIR/run-cfg.stderr" >&2 || true
    exit 1
fi
assert_empty "$WORKDIR/run-cfg.stdout"
assert_empty "$WORKDIR/run-cfg.stderr"

echo "[host-action-cli] repl"
: > "$WORKDIR/repl-empty.in"
# cli-gate-case stage1-wrapper-repl-empty wrapper run_stdin_capture
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
# cli-gate-case stage1-wrapper-repl-session wrapper run_stdin_capture
run_stdin_capture repl-session "$WORKDIR/repl-session.in" "$COMPILER" repl
assert_contains "$WORKDIR/repl-session.stdout" "TypeLisp REPL commands:"
assert_contains "$WORKDIR/repl-session.stdout" ".type <expr>"
assert_contains "$WORKDIR/repl-session.stdout" "bool"
assert_contains "$WORKDIR/repl-session.stdout" "tl> 3"
assert_empty "$WORKDIR/repl-session.stderr"

# cli-gate-case stage1-wrapper-repl-args wrapper run_expect_failure
run_expect_failure repl-args "$COMPILER" repl unexpected
assert_empty "$WORKDIR/repl-args.stdout"
assert_contains "$WORKDIR/repl-args.stderr" "Error: repl does not accept arguments"

echo "[host-action-cli] lsp"
LSP_INIT="$WORKDIR/lsp-init-shutdown.in"
: > "$LSP_INIT"
lsp_frame_append "$LSP_INIT" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
lsp_frame_append "$LSP_INIT" '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
# cli-gate-case stage1-wrapper-lsp-init-shutdown wrapper run_stdin_capture
run_stdin_capture lsp-init-shutdown "$LSP_INIT" "$COMPILER" lsp
assert_empty "$WORKDIR/lsp-init-shutdown.stderr"
assert_contains "$WORKDIR/lsp-init-shutdown.stdout" '"id":1'
assert_contains "$WORKDIR/lsp-init-shutdown.stdout" '"textDocumentSync"'
assert_contains "$WORKDIR/lsp-init-shutdown.stdout" '"id":2'

printf 'X-Test: 1\r\n\r\n' > "$WORKDIR/lsp-missing-length.in"
# cli-gate-case stage1-wrapper-lsp-missing-length wrapper run_stdin_expect_failure
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
# cli-gate-case stage1-wrapper-lsp-diagnostics wrapper run_stdin_capture
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
    # cli-gate-case stage1-wrapper-doc wrapper run_capture
    run_capture doc "$COMPILER" doc "$DOC_ENTRY" -o "$DOC_MD" --stdlib-root "$DOC_STDLIB"
    assert_empty "$WORKDIR/doc.stderr"
    assert_contains "$WORKDIR/doc.stdout" "Wrote $DOC_MD"
    assert_contains "$DOC_MD" "Entry module docs."
    assert_contains "$DOC_MD" "Local module docs."
    assert_contains "$DOC_MD" "Stdlib module docs."

    echo "[host-action-cli] doc --test"
    # cli-gate-case stage1-wrapper-doc-test wrapper run_capture
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
    # cli-gate-case stage1-wrapper-test-check wrapper run_capture
    run_capture test-check "$COMPILER" test --check "$TEST_SRC" --target linux-x86_64 --opt-level 2 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-check.stderr"
    assert_contains "$WORKDIR/test-check.stdout" "TypeLisp test typecheck passed: 1 test(s)"

    TEST_BATCH_SRC="$WORKDIR/inline-test-batch.tl"
    cat > "$TEST_BATCH_SRC" <<'EOF'
(import "stdlib/test.tl")

(test batch-one
  (assert-i64-eq (+ 20 22) 42 "batch one"))

(test batch-two
  (assert-i64-eq (* 6 7) 42 "batch two"))
EOF
    TEST_BATCH_LIST="$WORKDIR/inline-test-batch.txt"
    printf '%s\n' "$TEST_SRC" "$TEST_BATCH_SRC" > "$TEST_BATCH_LIST"
    # cli-gate-case stage1-wrapper-test-check-batch wrapper run_capture
    run_capture test-check-batch "$COMPILER" test --check --batch "$TEST_BATCH_LIST" --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-check-batch.stderr"
    assert_contains "$WORKDIR/test-check-batch.stdout" "TypeLisp test file: $TEST_SRC (1 test(s))"
    assert_contains "$WORKDIR/test-check-batch.stdout" "TypeLisp test typecheck passed: 1 test(s)"
    assert_contains "$WORKDIR/test-check-batch.stdout" "TypeLisp test file: $TEST_BATCH_SRC (2 test(s))"
    assert_contains "$WORKDIR/test-check-batch.stdout" "TypeLisp test typecheck passed: 2 test(s)"
    assert_contains "$WORKDIR/test-check-batch.stdout" "TypeLisp test batch typecheck passed: 3 test(s) in 2 file(s)"
    # cli-gate-case stage1-wrapper-test-check-batch-with-file wrapper run_expect_failure
    run_expect_failure test-check-batch-with-file "$COMPILER" test --check --batch "$TEST_BATCH_LIST" "$TEST_SRC" --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-check-batch-with-file.stderr" "test: cannot combine input paths with --batch"

    echo "[host-action-cli] test --batch"
    # cli-gate-case stage1-wrapper-test-run-batch wrapper run_capture
    run_capture test-run-batch "$COMPILER" test --batch "$TEST_BATCH_LIST" --target linux-x86_64 --opt-level 2 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-run-batch.stdout" "TypeLisp test file: $TEST_SRC (1 test(s))"
    assert_contains "$WORKDIR/test-run-batch.stdout" "TypeLisp test file: $TEST_BATCH_SRC (2 test(s))"
    assert_contains "$WORKDIR/test-run-batch.stdout" "TypeLisp test batch passed: 3 test(s) in 2 file(s)"
    assert_contains "$WORKDIR/test-run-batch.stderr" "test inc-basic"
    assert_contains "$WORKDIR/test-run-batch.stderr" "ok inc-basic"
    assert_contains "$WORKDIR/test-run-batch.stderr" "test batch-one"
    assert_contains "$WORKDIR/test-run-batch.stderr" "ok batch-two"
    if [ "$(grep -c '^TypeLisp tests passed: ' "$WORKDIR/test-run-batch.stderr")" -ne 2 ]; then
        fail "test execution batch did not report one success summary per source"
    fi

    TEST_BATCH_FAIL_SRC="$WORKDIR/inline-test-batch-fail.tl"
    cat > "$TEST_BATCH_FAIL_SRC" <<'EOF'
(import "stdlib/test.tl")

(test intentional-batch-failure
  (assert-i64-eq 1 2 "intentional batch failure"))
EOF
    TEST_BATCH_SENTINEL_SRC="$WORKDIR/inline-test-batch-sentinel.tl"
    cat > "$TEST_BATCH_SENTINEL_SRC" <<'EOF'
(import "stdlib/test.tl")

(test must-not-run-in-failed-batch
  (assert-i64-eq 42 42 "isolation sentinel"))
EOF
    TEST_BATCH_FAIL_LIST="$WORKDIR/inline-test-batch-fail.txt"
    printf '%s\n' "$TEST_SRC" "$TEST_BATCH_FAIL_SRC" "$TEST_BATCH_SENTINEL_SRC" > "$TEST_BATCH_FAIL_LIST"
    # cli-gate-case stage1-wrapper-test-run-batch-failure wrapper run_expect_failure
    run_expect_failure test-run-batch-failure "$COMPILER" test --batch "$TEST_BATCH_FAIL_LIST" --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-run-batch-failure.stderr" "intentional batch failure"
    assert_contains "$WORKDIR/test-run-batch-failure.stderr" "test: batch source failed: $TEST_BATCH_FAIL_SRC"
    assert_not_contains "$WORKDIR/test-run-batch-failure.stderr" "must-not-run-in-failed-batch"
    # cli-gate-case stage1-wrapper-test-run-batch-sentinel-fresh wrapper run_capture
    run_capture test-run-batch-sentinel-fresh "$COMPILER" test "$TEST_BATCH_SENTINEL_SRC" --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-run-batch-sentinel-fresh.stderr" "ok must-not-run-in-failed-batch"

    TEST_BATCH_BAD_SRC="$WORKDIR/inline-test-batch-bad.tl"
    cat > "$TEST_BATCH_BAD_SRC" <<'EOF'
(test batch-compile-error
  (missing-inline-test-name))
EOF
    TEST_BATCH_BAD_LIST="$WORKDIR/inline-test-batch-bad.txt"
    printf '%s\n' "$TEST_BATCH_BAD_SRC" "$TEST_BATCH_SENTINEL_SRC" > "$TEST_BATCH_BAD_LIST"
    # cli-gate-case stage1-wrapper-test-run-batch-compile-error wrapper run_expect_failure
    run_expect_failure test-run-batch-compile-error "$COMPILER" test --batch "$TEST_BATCH_BAD_LIST" --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-run-batch-compile-error.stderr" "unbound name missing-inline-test-name"
    assert_contains "$WORKDIR/test-run-batch-compile-error.stderr" "test: batch source failed: $TEST_BATCH_BAD_SRC"
    assert_not_contains "$WORKDIR/test-run-batch-compile-error.stderr" "must-not-run-in-failed-batch"

    TEST_BATCH_LOWER_BAD_SRC="$WORKDIR/inline-test-batch-lower-bad.tl"
    cat > "$TEST_BATCH_LOWER_BAD_SRC" <<'EOF'
(test batch-lower-error
  (begin
    '(+ 1 2)
    unit))
EOF
    TEST_BATCH_LOWER_BAD_LIST="$WORKDIR/inline-test-batch-lower-bad.txt"
    printf '%s\n' "$TEST_BATCH_LOWER_BAD_SRC" "$TEST_BATCH_SENTINEL_SRC" > "$TEST_BATCH_LOWER_BAD_LIST"
    # cli-gate-case stage1-wrapper-test-run-batch-lower-error wrapper run_expect_failure
    run_expect_failure test-run-batch-lower-error "$COMPILER" test --batch "$TEST_BATCH_LOWER_BAD_LIST" --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-run-batch-lower-error.stderr" "Expr value is compile-time only"
    assert_contains "$WORKDIR/test-run-batch-lower-error.stderr" "test: batch source failed: $TEST_BATCH_LOWER_BAD_SRC"
    assert_not_contains "$WORKDIR/test-run-batch-lower-error.stderr" "must-not-run-in-failed-batch"

    echo "[host-action-cli] test"
    # cli-gate-case stage1-wrapper-test-run wrapper run_capture
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
    # cli-gate-case stage1-wrapper-test-no-tests-check wrapper run_capture
    run_capture test-no-tests-check "$COMPILER" test --check "$NO_TEST_SRC"
    assert_empty "$WORKDIR/test-no-tests-check.stderr"
    assert_contains "$WORKDIR/test-no-tests-check.stdout" "TypeLisp test typecheck passed: 0 test(s)"
    # cli-gate-case stage1-wrapper-test-no-tests-run wrapper run_capture
    run_capture test-no-tests-run "$COMPILER" test "$NO_TEST_SRC"
    assert_empty "$WORKDIR/test-no-tests-run.stdout"
    assert_contains "$WORKDIR/test-no-tests-run.stderr" "TypeLisp tests passed: 0 test(s)"
    TEST_BATCH_ZERO_LIST="$WORKDIR/inline-test-batch-zero.txt"
    printf '%s\n' "$NO_TEST_SRC" "$TEST_SRC" > "$TEST_BATCH_ZERO_LIST"
    # cli-gate-case stage1-wrapper-test-run-batch-zero wrapper run_capture
    run_capture test-run-batch-zero "$COMPILER" test --batch "$TEST_BATCH_ZERO_LIST" --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-run-batch-zero.stdout" "TypeLisp test file: $NO_TEST_SRC (0 test(s))"
    assert_contains "$WORKDIR/test-run-batch-zero.stdout" "TypeLisp test batch passed: 1 test(s) in 2 file(s)"
    assert_contains "$WORKDIR/test-run-batch-zero.stderr" "TypeLisp tests passed: 0 test(s)"
    [ ! -f "$NO_TEST_SRC.test.s" ] || {
        echo "test no-tests left scratch assembly behind: $NO_TEST_SRC.test.s" >&2
        exit 1
    }

    echo "[host-action-cli] test package discovery"
    TEST_PKG="$WORKDIR/inline-test-pkg"
    mkdir -p "$TEST_PKG/src/nested" "$TEST_PKG/target/ignored" \
        "$TEST_PKG/vendor/child/src" "$TEST_PKG/tests/nested" \
        "$TEST_PKG/tests/format_golden" "$TEST_PKG/tests/target/ignored" \
        "$TEST_PKG/tests/vendor/child/src"
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
    cat > "$TEST_PKG/tests/vendor/child/src/fail.tl" <<'EOF'
(define (main) : i64 9)
EOF
    # cli-gate-case stage1-wrapper-test-package-check wrapper run_capture_cwd
    run_capture_cwd test-package-check "$TEST_PKG/src/nested" "$COMPILER" test --check --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-package-check.stderr"
    assert_contains "$WORKDIR/test-package-check.stdout" "TypeLisp test file:"
    assert_contains "$WORKDIR/test-package-check.stdout" "TypeLisp integration test file:"
    assert_contains_any "$WORKDIR/test-package-check.stdout" \
        "TypeLisp package test typecheck passed: 4 test(s) in 4 file(s)" \
        "TypeLisp package test typecheck passed: 4 test(s) in 12 file(s)"
    # cli-gate-case stage1-wrapper-test-package-run wrapper run_capture_cwd
    run_capture_cwd test-package-run "$TEST_PKG/src/nested" "$COMPILER" test --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/test-package-run.stdout" "TypeLisp integration test file:"
    assert_contains_any "$WORKDIR/test-package-run.stdout" \
        "TypeLisp package tests passed: 4 test(s) in 4 file(s)" \
        "TypeLisp package tests passed: 4 test(s) in 12 file(s)"
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
    # cli-gate-case stage1-wrapper-test-package-no-tests wrapper run_capture_cwd
    run_capture_cwd test-package-no-tests "$TEST_EMPTY_PKG" "$COMPILER" test --check --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
    assert_empty "$WORKDIR/test-package-no-tests.stderr"
    assert_contains_any "$WORKDIR/test-package-no-tests.stdout" \
        "TypeLisp package test typecheck passed: 0 test(s) in 0 file(s)" \
        "TypeLisp package test typecheck passed: 0 test(s) in 1 file(s)"

    echo "[host-action-cli] test failures"
    FAIL_SRC="$WORKDIR/inline-test-fail.tl"
    cat > "$FAIL_SRC" <<'EOF'
(import "stdlib/test.tl")

(test failing-case
  (assert-i64-eq 1 2 "inline failure message"))
EOF
    set +e
    # cli-gate-case stage1-wrapper-test-fail direct TYPELISP_STAGE1_HEARTBEAT_FD=3
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
    # cli-gate-case stage1-wrapper-test-package-integration-fail direct TYPELISP_STAGE1_HEARTBEAT_FD=3
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test --target linux-x86_64 --manifest-path "$FAIL_PKG/typelisp.pkg" 3>&2 > "$WORKDIR/test-package-integration-fail.stdout" 2> "$WORKDIR/test-package-integration-fail.stderr"
    pkg_fail_status=$?
    set -e
    if [ "$pkg_fail_status" -ne 1 ]; then
        echo "host-action CLI package integration failure exited $pkg_fail_status, expected 1" >&2
        exit 1
    fi
    assert_contains "$WORKDIR/test-package-integration-fail.stdout" "TypeLisp integration test file:"
    assert_contains "$WORKDIR/test-package-integration-fail.stderr" "typelisp test: test executable exited with exit status: 7"

    DIAG_PKG="$WORKDIR/integration-lower-diagnostic-pkg"
    mkdir -p "$DIAG_PKG/src" "$DIAG_PKG/tests"
    cat > "$DIAG_PKG/typelisp.pkg" <<'EOF'
(package
  (name "integration_lower_diagnostic_pkg")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    cat > "$DIAG_PKG/src/lib.tl" <<'EOF'
(define lib-value : i64 42)
EOF
    cat > "$DIAG_PKG/tests/quote_runtime_value.tl" <<'EOF'
(define (main) : i64
  (begin
    '(+ 1 2)
    0))
EOF
    set +e
    # cli-gate-case stage1-wrapper-test-package-integration-lower-diagnostic direct TYPELISP_STAGE1_HEARTBEAT_FD=3
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test --target linux-x86_64 --manifest-path "$DIAG_PKG/typelisp.pkg" 3>&2 > "$WORKDIR/test-package-integration-lower-diagnostic.stdout" 2> "$WORKDIR/test-package-integration-lower-diagnostic.stderr"
    pkg_diag_status=$?
    set -e
    if [ "$pkg_diag_status" -ne 1 ]; then
        echo "host-action CLI package integration diagnostic exited $pkg_diag_status, expected 1" >&2
        exit 1
    fi
    assert_contains "$WORKDIR/test-package-integration-lower-diagnostic.stdout" "TypeLisp integration test file:"
    assert_contains "$WORKDIR/test-package-integration-lower-diagnostic.stderr" "error: Expr value is compile-time only"
    assert_contains "$WORKDIR/test-package-integration-lower-diagnostic.stderr" "quote_runtime_value.tl:3:5"
    assert_contains "$WORKDIR/test-package-integration-lower-diagnostic.stderr" "'(+ 1 2)"
    assert_contains "$WORKDIR/test-package-integration-lower-diagnostic.stderr" "|     ^"

    BAD_SRC="$WORKDIR/inline-test-bad.tl"
    cat > "$BAD_SRC" <<'EOF'
(test compile-error
  (missing-inline-test-name))
EOF
    set +e
    # cli-gate-case stage1-wrapper-test-bad direct TYPELISP_STAGE1_HEARTBEAT_FD=3
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
    # cli-gate-case stage1-wrapper-test-missing-opt direct TYPELISP_STAGE1_HEARTBEAT_FD=3
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
    # cli-gate-case stage1-wrapper-test-invalid-opt direct TYPELISP_STAGE1_HEARTBEAT_FD=3
    TYPELISP_STAGE1_HEARTBEAT_FD=3 "$COMPILER" test "$TEST_SRC" --opt-level 3 3>&2 > "$WORKDIR/test-invalid-opt.stdout" 2> "$WORKDIR/test-invalid-opt.stderr"
    invalid_opt_status=$?
    set -e
    if [ "$invalid_opt_status" -eq 0 ]; then
        echo "host-action CLI test invalid-opt-level case unexpectedly succeeded" >&2
        exit 1
    fi
    assert_empty "$WORKDIR/test-invalid-opt.stdout"
    assert_contains "$WORKDIR/test-invalid-opt.stderr" "test: invalid --opt-level 3; expected 0, 1, or 2"

    set +e
    # cli-gate-case stage1-wrapper-test-bad-target direct TYPELISP_STAGE1_HEARTBEAT_FD=3
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
# cli-gate-expand stage1-wrapper-fmt-golden-{fixture} wrapper run_capture fixture=char_literal,comments,decls,flow,let_bindings,negative_int,quote,signature_colon,tail_comment
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
# cli-gate-expand stage1-wrapper-fmt-golden-check-{fixture} wrapper run_capture fixture=char_literal,comments,decls,flow,let_bindings,negative_int,quote,signature_colon,tail_comment
run_capture fmt-golden-check "$@"
assert_empty "$WORKDIR/fmt-golden-check.stdout"
assert_empty "$WORKDIR/fmt-golden-check.stderr"

cat > "$WORKDIR/fmt-changed.tl" <<'EOF'
(define (main) : i64
  (let ([x : i64 42])
    x))
EOF
cp "$WORKDIR/fmt-changed.tl" "$WORKDIR/fmt-changed.expected"
# cli-gate-case stage1-wrapper-fmt-check-changed wrapper run_expect_failure
run_expect_failure fmt-check-changed "$COMPILER" fmt --check "$WORKDIR/fmt-changed.tl"
assert_empty "$WORKDIR/fmt-check-changed.stdout"
assert_contains "$WORKDIR/fmt-check-changed.stderr" "fmt: would reformat"
check_file_exact "$WORKDIR/fmt-changed.tl" "$WORKDIR/fmt-changed.expected"

# cli-gate-case stage1-wrapper-fmt-missing wrapper run_expect_failure
run_expect_failure fmt-missing "$COMPILER" fmt "$WORKDIR/missing.tl"
assert_empty "$WORKDIR/fmt-missing.stdout"
assert_nonempty "$WORKDIR/fmt-missing.stderr"

printf '(define (' > "$WORKDIR/fmt-parse-error.tl"
# cli-gate-case stage1-wrapper-fmt-parse-error wrapper run_expect_failure
run_expect_failure fmt-parse-error "$COMPILER" fmt "$WORKDIR/fmt-parse-error.tl"
assert_empty "$WORKDIR/fmt-parse-error.stdout"
assert_nonempty "$WORKDIR/fmt-parse-error.stderr"
assert_contains "$WORKDIR/fmt-parse-error.stderr" "fmt-parse-error.tl:1:10: format cst: unclosed delimiter"

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
(define (main) : i64
  (let
    [a : i64 1]
    (let
      [b : i64 (+ a 1)]
      (+ a b))))
EOF
# cli-gate-case stage1-wrapper-fmt-package-check wrapper run_expect_failure
run_expect_failure fmt-package-check "$COMPILER" fmt --manifest-path "$FMTLINT_PKG/typelisp.pkg" --check
assert_empty "$WORKDIR/fmt-package-check.stdout"
assert_contains "$WORKDIR/fmt-package-check.stderr" "needs_fmt.tl"
# cli-gate-case stage1-wrapper-fmt-package-rewrite wrapper run_capture
run_capture fmt-package-rewrite "$COMPILER" fmt --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/fmt-package-rewrite.stdout"
assert_empty "$WORKDIR/fmt-package-rewrite.stderr"
assert_contains "$FMTLINT_PKG/src/needs_fmt.tl" "  (+ 1 2)"
# cli-gate-case stage1-wrapper-fmt-package-discover wrapper run_capture_cwd
run_capture_cwd fmt-package-discover "$FMTLINT_PKG/src/nested/deeper" "$COMPILER" fmt --check
assert_empty "$WORKDIR/fmt-package-discover.stdout"
assert_empty "$WORKDIR/fmt-package-discover.stderr"
# cli-gate-case stage1-wrapper-fmt-file-manifest wrapper run_expect_failure
run_expect_failure fmt-file-manifest "$COMPILER" fmt "$SRC" --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/fmt-file-manifest.stdout"
assert_contains "$WORKDIR/fmt-file-manifest.stderr" "cannot combine input paths with --manifest-path"
FMT_NOPKG=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-fmt-nopkg.XXXXXX")
# cli-gate-case stage1-wrapper-fmt-no-manifest wrapper run_expect_failure_cwd
run_expect_failure_cwd fmt-no-manifest "$FMT_NOPKG" "$COMPILER" fmt --check
assert_empty "$WORKDIR/fmt-no-manifest.stdout"
assert_contains "$WORKDIR/fmt-no-manifest.stderr" "could not find typelisp.pkg"
rm -rf "$FMT_NOPKG"

echo "[host-action-cli] lint"
# cli-gate-case stage1-wrapper-lint-help wrapper run_capture
run_capture lint-help "$COMPILER" lint --help
assert_empty "$WORKDIR/lint-help.stdout"
assert_contains "$WORKDIR/lint-help.stderr" "Usage:"
assert_contains "$WORKDIR/lint-help.stderr" "typelisp lint [<file.tl>...] [--check] [--deprecated-string-concat] [--redundant-function-name] [--prefer-dotted-field] [--name-case] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]"
assert_contains "$WORKDIR/lint-help.stderr" "Summary:"

LINT_NOPKG=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-lint-nopkg.XXXXXX")
# cli-gate-case stage1-wrapper-lint-missing wrapper run_expect_failure_cwd
run_expect_failure_cwd lint-missing "$LINT_NOPKG" "$COMPILER" lint
assert_empty "$WORKDIR/lint-missing.stdout"
assert_contains "$WORKDIR/lint-missing.stderr" "could not find typelisp.pkg"
rm -rf "$LINT_NOPKG"

# cli-gate-case stage1-wrapper-lint-clean wrapper run_capture
run_capture lint-clean "$COMPILER" lint "$SRC"
assert_empty "$WORKDIR/lint-clean.stderr"
assert_contains "$WORKDIR/lint-clean.stdout" "lint: 0 finding(s)"

# cli-gate-case stage1-wrapper-lint-clean-check wrapper run_capture
run_capture lint-clean-check "$COMPILER" lint "$SRC" --check
assert_empty "$WORKDIR/lint-clean-check.stderr"
assert_contains "$WORKDIR/lint-clean-check.stdout" "lint: 0 finding(s)"

LINT_SRC="$WORKDIR/lint_bad.tl"
cat > "$LINT_SRC" <<'EOF'
(define (main) : i64
  (let
    [a : i64 1]
    (let
      [b : i64 (+ a 1)]
      (+ a b))))
EOF
# cli-gate-case stage1-wrapper-lint-nested-let wrapper run_capture
run_capture lint-nested-let "$COMPILER" lint "$LINT_SRC"
assert_empty "$WORKDIR/lint-nested-let.stderr"
assert_contains "$WORKDIR/lint-nested-let.stdout" "lint_bad.tl:"
assert_contains "$WORKDIR/lint-nested-let.stdout" "nested let"
assert_contains "$WORKDIR/lint-nested-let.stdout" "merge bindings"
assert_contains "$WORKDIR/lint-nested-let.stdout" "lint: 1 finding(s)"

# cli-gate-case stage1-wrapper-lint-nested-let-check wrapper run_expect_failure
run_expect_failure lint-nested-let-check "$COMPILER" lint "$LINT_SRC" --check
assert_empty "$WORKDIR/lint-nested-let-check.stderr"
assert_contains "$WORKDIR/lint-nested-let-check.stdout" "lint_bad.tl:"
assert_contains "$WORKDIR/lint-nested-let-check.stdout" "nested let"
assert_contains "$WORKDIR/lint-nested-let-check.stdout" "lint: 1 finding(s)"

# cli-gate-case stage1-wrapper-lint-multi wrapper run_capture
run_capture lint-multi "$COMPILER" lint "$SRC" "$LINT_SRC"
assert_empty "$WORKDIR/lint-multi.stderr"
assert_contains "$WORKDIR/lint-multi.stdout" "--- $SRC"
assert_contains "$WORKDIR/lint-multi.stdout" "--- $LINT_SRC"
assert_contains "$WORKDIR/lint-multi.stdout" "lint_bad.tl:"
assert_contains "$WORKDIR/lint-multi.stdout" "lint: 0 finding(s)"
assert_contains "$WORKDIR/lint-multi.stdout" "lint: 1 finding(s)"
lint_multi_clean_line=$(grep -nF -- "--- $SRC" "$WORKDIR/lint-multi.stdout" | head -n 1 | cut -d: -f1)
lint_multi_bad_line=$(grep -nF -- "--- $LINT_SRC" "$WORKDIR/lint-multi.stdout" | head -n 1 | cut -d: -f1)
if [ "$lint_multi_clean_line" -ge "$lint_multi_bad_line" ]; then
    fail "lint multi-file output did not preserve input path order"
fi

# cli-gate-case stage1-wrapper-lint-package-check wrapper run_expect_failure
run_expect_failure lint-package-check "$COMPILER" lint --manifest-path "$FMTLINT_PKG/typelisp.pkg" --check
assert_empty "$WORKDIR/lint-package-check.stderr"
assert_contains "$WORKDIR/lint-package-check.stdout" "lint_bad.tl:"
assert_contains "$WORKDIR/lint-package-check.stdout" "lint: 1 finding(s)"
# cli-gate-case stage1-wrapper-lint-package-discover wrapper run_capture_cwd
run_capture_cwd lint-package-discover "$FMTLINT_PKG/src/nested/deeper" "$COMPILER" lint
assert_empty "$WORKDIR/lint-package-discover.stderr"
assert_contains "$WORKDIR/lint-package-discover.stdout" "lint_bad.tl:"
# cli-gate-case stage1-wrapper-lint-file-manifest wrapper run_expect_failure
run_expect_failure lint-file-manifest "$COMPILER" lint "$SRC" --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/lint-file-manifest.stdout"
assert_contains "$WORKDIR/lint-file-manifest.stderr" "cannot combine input paths with --manifest-path"
# cli-gate-case stage1-wrapper-lint-files-manifest wrapper run_expect_failure
run_expect_failure lint-files-manifest "$COMPILER" lint "$SRC" "$LINT_SRC" --manifest-path "$FMTLINT_PKG/typelisp.pkg"
assert_empty "$WORKDIR/lint-files-manifest.stdout"
assert_contains "$WORKDIR/lint-files-manifest.stderr" "cannot combine input paths with --manifest-path"

# cli-gate-case stage1-wrapper-lint-missing-file wrapper run_expect_failure
run_expect_failure lint-missing-file "$COMPILER" lint "$WORKDIR/missing-lint.tl"
assert_empty "$WORKDIR/lint-missing-file.stdout"
assert_nonempty "$WORKDIR/lint-missing-file.stderr"

printf '(define (' > "$WORKDIR/lint-parse-error.tl"
# cli-gate-case stage1-wrapper-lint-parse-error wrapper run_expect_failure
run_expect_failure lint-parse-error "$COMPILER" lint "$WORKDIR/lint-parse-error.tl"
assert_empty "$WORKDIR/lint-parse-error.stdout"
assert_nonempty "$WORKDIR/lint-parse-error.stderr"

# cli-gate-case stage1-wrapper-lint-parse-error-check wrapper run_expect_failure
run_expect_failure lint-parse-error-check "$COMPILER" lint "$WORKDIR/lint-parse-error.tl" --check
assert_empty "$WORKDIR/lint-parse-error-check.stdout"
assert_nonempty "$WORKDIR/lint-parse-error-check.stderr"

echo "[host-action-cli] opt2 build-invariance reference handoff"
assert_contains scripts/ci-verify.sh "TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE"
assert_contains scripts/ci-verify.sh "TYPELISP_OPT2_CLI_REFERENCE_ASM"
handoff_build_line=$(grep -nF 'scripts/check-build-invariance.sh' scripts/ci-verify.sh | head -n 1 | cut -d: -f1)
handoff_opt2_line=$(grep -nF 'scripts/check-opt2-cli-regression.sh' scripts/ci-verify.sh | head -n 1 | cut -d: -f1)
if [ -z "$handoff_build_line" ] || [ -z "$handoff_opt2_line" ] || [ "$handoff_build_line" -ge "$handoff_opt2_line" ]; then
    fail "Linux CI must run build-invariance before the opt2 regression handoff"
fi
HANDOFF_ROOT="$WORKDIR/opt2-handoff-repo"
HANDOFF_SCRIPTS="$HANDOFF_ROOT/scripts"
HANDOFF_LOG="$HANDOFF_ROOT/invocations.log"
HANDOFF_REFERENCE="$HANDOFF_ROOT/validated-opt1.s"
HANDOFF_SEED="$HANDOFF_ROOT/fake-seed"
HANDOFF_GENERATED="$HANDOFF_ROOT/fake-generated"
rm -rf "$HANDOFF_ROOT"
mkdir -p "$HANDOFF_SCRIPTS"
cp scripts/check-opt2-cli-regression.sh "$HANDOFF_SCRIPTS/check-opt2-cli-regression.sh"
cp scripts/lib-native-link.sh "$HANDOFF_SCRIPTS/lib-native-link.sh"
cp scripts/lib-linux-entry.sh "$HANDOFF_SCRIPTS/lib-linux-entry.sh"
printf '.text\nvalidated opt1 reference\n' > "$HANDOFF_REFERENCE"

cat > "$HANDOFF_SEED" <<'EOF'
#!/usr/bin/env sh
set -eu

printf 'seed' >> "$OPT2_HANDOFF_TEST_LOG"
for arg in "$@"; do
    printf '|%s' "$arg" >> "$OPT2_HANDOFF_TEST_LOG"
done
printf '\n' >> "$OPT2_HANDOFF_TEST_LOG"

command=${1:-}
case "$command" in
    run)
        exit 42
        ;;
    build)
        if [ "${OPT2_HANDOFF_TEST_SKIP_GENERATED:-0}" -eq 0 ]; then
            mkdir -p target/release
            cp "$OPT2_HANDOFF_TEST_GENERATED" target/release/typelisp
            chmod +x target/release/typelisp
        fi
        ;;
    compile)
        out=""
        shift
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -o ]; then
                shift
                out=$1
            fi
            shift
        done
        [ -n "$out" ] || exit 1
        cp "$OPT2_HANDOFF_TEST_REFERENCE" "$out"
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "$HANDOFF_GENERATED" <<'EOF'
#!/usr/bin/env sh
set -eu

printf 'generated' >> "$OPT2_HANDOFF_TEST_LOG"
for arg in "$@"; do
    printf '|%s' "$arg" >> "$OPT2_HANDOFF_TEST_LOG"
done
printf '\n' >> "$OPT2_HANDOFF_TEST_LOG"

[ "${1:-}" = compile ] || exit 1
out=""
opt_level=""
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            shift
            out=$1
            ;;
        --opt-level)
            shift
            opt_level=$1
            ;;
    esac
    shift
done
[ -n "$out" ] || exit 1
if [ "$opt_level" = 1 ] && [ "${OPT2_HANDOFF_TEST_CROSS_MISMATCH:-0}" -eq 1 ]; then
    printf '.text\ncross mismatch\n' > "$out"
else
    cp "$OPT2_HANDOFF_TEST_REFERENCE" "$out"
fi
EOF
chmod +x "$HANDOFF_SEED" "$HANDOFF_GENERATED" "$HANDOFF_SCRIPTS/check-opt2-cli-regression.sh"

: > "$HANDOFF_LOG"
# cli-gate-case stage1-wrapper-opt2-handoff-supplied delegated run_capture
run_capture opt2-handoff-supplied \
    env \
    TYPELISP_BIN="$HANDOFF_SEED" \
    TYPELISP_OPT2_CLI_REFERENCE_ASM="$HANDOFF_REFERENCE" \
    OPT2_HANDOFF_TEST_LOG="$HANDOFF_LOG" \
    OPT2_HANDOFF_TEST_GENERATED="$HANDOFF_GENERATED" \
    OPT2_HANDOFF_TEST_REFERENCE="$HANDOFF_REFERENCE" \
    "$HANDOFF_SCRIPTS/check-opt2-cli-regression.sh"
assert_contains "$HANDOFF_LOG" "seed|build|--manifest-path|typelisp.pkg|--profile|release|--opt-level|2"
assert_contains "$HANDOFF_LOG" "generated|compile|src/main.tl|-o|$HANDOFF_ROOT/target/opt2-cli-regression/cli-opt2.s"
assert_contains "$HANDOFF_LOG" "generated|compile|src/main.tl|-o|$HANDOFF_ROOT/target/opt2-cli-regression/cli-opt2built-opt1.s"
assert_not_contains "$HANDOFF_LOG" "seed|compile|src/main.tl"
assert_contains "$WORKDIR/opt2-handoff-supplied.stdout" "reference: reuse validated build-invariance stage4 src/main @ opt1 assembly"
assert_contains "$WORKDIR/opt2-handoff-supplied.stdout" "cross-fixpoint holds"

: > "$HANDOFF_LOG"
# cli-gate-case stage1-wrapper-opt2-handoff-standalone delegated run_capture
run_capture opt2-handoff-standalone \
    env -u TYPELISP_OPT2_CLI_REFERENCE_ASM \
    TYPELISP_BIN="$HANDOFF_SEED" \
    OPT2_HANDOFF_TEST_LOG="$HANDOFF_LOG" \
    OPT2_HANDOFF_TEST_GENERATED="$HANDOFF_GENERATED" \
    OPT2_HANDOFF_TEST_REFERENCE="$HANDOFF_REFERENCE" \
    "$HANDOFF_SCRIPTS/check-opt2-cli-regression.sh"
assert_contains "$HANDOFF_LOG" "seed|compile|src/main.tl|-o|$HANDOFF_ROOT/target/opt2-cli-regression/cli-opt1-ref.s"
assert_contains "$WORKDIR/opt2-handoff-standalone.stdout" "reference: converged compiler compiles src/main.tl at opt1"
assert_contains "$WORKDIR/opt2-handoff-standalone.stdout" "cross-fixpoint holds"

# cli-gate-case stage1-wrapper-opt2-handoff-empty-reference delegated run_expect_failure
run_expect_failure opt2-handoff-empty-reference \
    env \
    TYPELISP_BIN="$HANDOFF_SEED" \
    TYPELISP_OPT2_CLI_REFERENCE_ASM= \
    OPT2_HANDOFF_TEST_LOG="$HANDOFF_LOG" \
    OPT2_HANDOFF_TEST_GENERATED="$HANDOFF_GENERATED" \
    OPT2_HANDOFF_TEST_REFERENCE="$HANDOFF_REFERENCE" \
    "$HANDOFF_SCRIPTS/check-opt2-cli-regression.sh"
assert_contains "$WORKDIR/opt2-handoff-empty-reference.stderr" "supplied opt1 reference path is empty"

# cli-gate-case stage1-wrapper-opt2-handoff-missing-release delegated run_expect_failure
run_expect_failure opt2-handoff-missing-release \
    env \
    TYPELISP_BIN="$HANDOFF_SEED" \
    TYPELISP_OPT2_CLI_REFERENCE_ASM="$HANDOFF_REFERENCE" \
    OPT2_HANDOFF_TEST_LOG="$HANDOFF_LOG" \
    OPT2_HANDOFF_TEST_GENERATED="$HANDOFF_GENERATED" \
    OPT2_HANDOFF_TEST_REFERENCE="$HANDOFF_REFERENCE" \
    OPT2_HANDOFF_TEST_SKIP_GENERATED=1 \
    "$HANDOFF_SCRIPTS/check-opt2-cli-regression.sh"
assert_contains "$WORKDIR/opt2-handoff-missing-release.stderr" "generated compiler is missing or empty"

# cli-gate-case stage1-wrapper-opt2-handoff-cross-mismatch delegated run_expect_failure
run_expect_failure opt2-handoff-cross-mismatch \
    env \
    TYPELISP_BIN="$HANDOFF_SEED" \
    TYPELISP_OPT2_CLI_REFERENCE_ASM="$HANDOFF_REFERENCE" \
    OPT2_HANDOFF_TEST_LOG="$HANDOFF_LOG" \
    OPT2_HANDOFF_TEST_GENERATED="$HANDOFF_GENERATED" \
    OPT2_HANDOFF_TEST_REFERENCE="$HANDOFF_REFERENCE" \
    OPT2_HANDOFF_TEST_CROSS_MISMATCH=1 \
    "$HANDOFF_SCRIPTS/check-opt2-cli-regression.sh"
assert_contains "$WORKDIR/opt2-handoff-cross-mismatch.stderr" "CROSS-FIXPOINT MISMATCH"

echo "host-action CLI smoke passed"
