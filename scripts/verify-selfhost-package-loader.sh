#!/usr/bin/env sh
set -eu

# verify-selfhost-package-loader.sh - selfhost loader pkg: corpus.
#
# Builds the selfhost check driver once, then runs it over generated package
# fixtures that exercise typelisp.pkg discovery and pkg:<alias>/... imports
# through the real loader path.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "selfhost package loader verification is Linux-only (requires native selfhost driver execution)"
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_empty_file() {
    file=$1
    label=$2
    if [ -s "$file" ]; then
        echo "unexpected $label:" >&2
        sed 's/^/  /' "$file" >&2
        fail "$label was not empty"
    fi
}

assert_contains_file() {
    file=$1
    needle=$2
    if ! grep -F -- "$needle" "$file" >/dev/null; then
        echo "missing expected text [$needle] in $file" >&2
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2
        exit 1
    fi
}

WORKDIR="$ROOT/target/selfhost-package-loader-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CHECK_BIN="$WORKDIR/selfhost-check"
echo "[selfhost-pkg-loader] building selfhost check driver"
"$COMPILER" build selfhost/check.tl -o "$CHECK_BIN"

run_check_success() {
    name=$1
    source=$2
    out="$WORKDIR/$name.out"
    err="$WORKDIR/$name.err"

    echo "[selfhost-pkg-loader] $name -> expect success"
    set +e
    "$CHECK_BIN" "$source" > "$out" 2> "$err"
    code=$?
    set -e

    if [ "$code" -ne 0 ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$out" >&2
        echo "stderr:" >&2
        sed 's/^/  /' "$err" >&2
        fail "$name exited $code, expected 0"
    fi
    assert_empty_file "$out" "$name stdout"
    assert_empty_file "$err" "$name stderr"
}

run_check_failure() {
    name=$1
    source=$2
    shift 2
    out="$WORKDIR/$name.out"
    err="$WORKDIR/$name.err"

    echo "[selfhost-pkg-loader] $name -> expect diagnostic"
    set +e
    "$CHECK_BIN" "$source" > "$out" 2> "$err"
    code=$?
    set -e

    if [ "$code" -eq 0 ]; then
        fail "$name unexpectedly succeeded"
    fi
    assert_empty_file "$out" "$name stdout"
    for needle in "$@"; do
        assert_contains_file "$err" "$needle"
    done
}

PKG_OK="$WORKDIR/pkg-ok"
mkdir -p "$PKG_OK/src" "$PKG_OK/vendor/math/src"
cat > "$PKG_OK/typelisp.pkg" <<'EOF'
(package
  (name "pkg_loader_ok")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
cat > "$PKG_OK/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(import "../vendor/math/src/./lib.tl")

(define (main) : i64 (add-one 41))
EOF
cat > "$PKG_OK/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
run_check_success "pkg-success-dedup" "$PKG_OK/src/main.tl"

PKG_MISSING_ALIAS="$WORKDIR/pkg-missing-alias"
mkdir -p "$PKG_MISSING_ALIAS/src"
cat > "$PKG_MISSING_ALIAS/typelisp.pkg" <<'EOF'
(package
  (name "pkg_missing_alias")
  (version "0.1.0")
  (entry "src/main.tl"))
EOF
cat > "$PKG_MISSING_ALIAS/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")

(define (main) : i64 0)
EOF
run_check_failure \
    "pkg-missing-alias" \
    "$PKG_MISSING_ALIAS/src/main.tl" \
    "compiler-load: cannot read import" \
    "pkg:math/src/lib.tl"

PKG_MISSING_DEP="$WORKDIR/pkg-missing-dependency-file"
mkdir -p "$PKG_MISSING_DEP/src" "$PKG_MISSING_DEP/vendor/math"
cat > "$PKG_MISSING_DEP/typelisp.pkg" <<'EOF'
(package
  (name "pkg_missing_dependency_file")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
cat > "$PKG_MISSING_DEP/src/main.tl" <<'EOF'
(import "pkg:math/src/missing.tl")

(define (main) : i64 0)
EOF
run_check_failure \
    "pkg-missing-dependency-file" \
    "$PKG_MISSING_DEP/src/main.tl" \
    "compiler-load: cannot read import" \
    "vendor/math/src/missing.tl"

PKG_ESCAPE="$WORKDIR/pkg-parent-escape"
mkdir -p "$PKG_ESCAPE/src" "$PKG_ESCAPE/vendor/math"
cat > "$PKG_ESCAPE/typelisp.pkg" <<'EOF'
(package
  (name "pkg_parent_escape")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
cat > "$PKG_ESCAPE/src/main.tl" <<'EOF'
(import "pkg:math/../escape.tl")

(define (main) : i64 0)
EOF
run_check_failure \
    "pkg-parent-escape" \
    "$PKG_ESCAPE/src/main.tl" \
    "compiler-load: cannot read import" \
    "pkg:math/../escape.tl"

PKG_DUP="$WORKDIR/pkg-flat-duplicate"
mkdir -p "$PKG_DUP/src" "$PKG_DUP/vendor/dup/src"
cat > "$PKG_DUP/typelisp.pkg" <<'EOF'
(package
  (name "pkg_flat_duplicate")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (dup "vendor/dup")))
EOF
cat > "$PKG_DUP/src/main.tl" <<'EOF'
(import "left.tl")
(import "pkg:dup/src/lib.tl")

(define (main) : i64 (left))
EOF
cat > "$PKG_DUP/src/left.tl" <<'EOF'
(define (shared) : i64 1)
(define (left) : i64 (shared))
EOF
cat > "$PKG_DUP/vendor/dup/src/lib.tl" <<'EOF'
(define (shared) : i64 2)
EOF
run_check_failure \
    "pkg-flat-duplicate" \
    "$PKG_DUP/src/main.tl" \
    "symbols: duplicate value declaration shared"

echo "selfhost package loader verification passed"
