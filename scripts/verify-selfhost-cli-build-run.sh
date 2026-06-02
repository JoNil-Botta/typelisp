#!/usr/bin/env sh
set -eu

# verify-selfhost-cli-build-run.sh - focused public build/run smoke for cli.tl.
#
# This is run against a freshly built selfhost/cli.tl binary in the no-Rust gate,
# so it verifies the branch's public `typelisp build` / `typelisp run` behavior
# instead of the already-published seed compiler.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "selfhost cli build/run smoke is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

if [ -z "${TYPELISP_BIN:-}" ]; then
    echo "verify-selfhost-cli-build-run requires TYPELISP_BIN" >&2
    exit 2
fi

COMPILER=$TYPELISP_BIN
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/selfhost-cli-build-run"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_status() {
    label=$1
    got=$2
    expected=$3
    if [ "$got" -ne "$expected" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$WORKDIR/$label.out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$WORKDIR/$label.err" >&2 || true
        fail "$label expected exit $expected, got $got"
    fi
}

assert_empty() {
    label=$1
    file=$2
    [ ! -s "$file" ] || fail "$label wrote unexpected output: $(cat "$file")"
}

assert_contains() {
    label=$1
    file=$2
    text=$3
    if ! grep -F -- "$text" "$file" >/dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$label missing expected text: $text"
    fi
}

COMPILE_SRC="$WORKDIR/compile-main.tl"
COMPILE_ASM="$WORKDIR/compile-main.s"
cat > "$COMPILE_SRC" <<'EOF'
(define (main) : i64 23)
EOF

set +e
"$COMPILER" compile "$COMPILE_SRC" -o "$COMPILE_ASM" > "$WORKDIR/compile.out" 2> "$WORKDIR/compile.err"
status=$?
set -e
assert_status compile "$status" 0
assert_empty compile "$WORKDIR/compile.err"
assert_contains compile "$WORKDIR/compile.out" "Generated:"
assert_contains compile "$COMPILE_ASM" "main:"

BUILD_SRC="$WORKDIR/build-main.tl"
BUILD_EXE="$WORKDIR/built-program"
BUILD_TARGET=linux-x86_64
if [ "$HOST_OS" = windows ]; then
    BUILD_EXE="$BUILD_EXE.exe"
    BUILD_TARGET=windows-x86_64
fi
cat > "$BUILD_SRC" <<'EOF'
(define (main) : i64 19)
EOF

set +e
"$COMPILER" build "$BUILD_SRC" -o "$BUILD_EXE" > "$WORKDIR/build.out" 2> "$WORKDIR/build.err"
status=$?
set -e
assert_status build "$status" 0
assert_empty build "$WORKDIR/build.err"
assert_contains build "$WORKDIR/build.out" "Generated:"
[ -f "$BUILD_EXE" ] || fail "build did not write executable $BUILD_EXE"

set +e
"$BUILD_EXE" > "$WORKDIR/built-program.out" 2> "$WORKDIR/built-program.err"
status=$?
set -e
assert_status built-program "$status" 19
assert_empty built-program "$WORKDIR/built-program.out"
assert_empty built-program "$WORKDIR/built-program.err"

PKG_DIR="$WORKDIR/package-build"
mkdir -p "$PKG_DIR/src"
cat > "$PKG_DIR/typelisp.pkg" <<'EOF'
(package
  (name "cli_pkg_smoke")
  (version "0.1.0")
  (kind bin))
EOF
cat > "$PKG_DIR/src/main.tl" <<'EOF'
(define (main) : i64 29)
EOF
PKG_EXE="$PKG_DIR/target/typelisp/cli_pkg_smoke/cli_pkg_smoke"
if [ "$HOST_OS" = windows ]; then
    PKG_EXE="$PKG_EXE.exe"
fi

set +e
(
    cd "$PKG_DIR"
    "$COMPILER" build --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-build.out" 2> "$WORKDIR/package-build.err"
)
status=$?
set -e
assert_status package-build "$status" 0
assert_empty package-build "$WORKDIR/package-build.err"
assert_contains package-build "$WORKDIR/package-build.out" "Generated:"
[ -f "$PKG_EXE" ] || fail "package build did not write executable $PKG_EXE"

set +e
"$PKG_EXE" > "$WORKDIR/package-program.out" 2> "$WORKDIR/package-program.err"
status=$?
set -e
assert_status package-program "$status" 29
assert_empty package-program "$WORKDIR/package-program.out"
assert_empty package-program "$WORKDIR/package-program.err"

STATICLIB_DIR="$WORKDIR/staticlib-package-build"
mkdir -p "$STATICLIB_DIR/src"
cat > "$STATICLIB_DIR/typelisp.pkg" <<'EOF'
(package
  (name "cli_staticlib_smoke")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$STATICLIB_DIR/src/lib.tl" <<'EOF'
(define (static-answer) : i64 42)
EOF
STATICLIB_ARCHIVE="$STATICLIB_DIR/target/typelisp/cli_staticlib_smoke/libcli_staticlib_smoke.a"
if [ "$HOST_OS" = windows ]; then
    STATICLIB_ARCHIVE="$STATICLIB_DIR/target/typelisp/cli_staticlib_smoke/cli_staticlib_smoke.lib"
fi

set +e
(
    cd "$STATICLIB_DIR"
    "$COMPILER" build --target "$BUILD_TARGET" > "$WORKDIR/staticlib-package-build.out" 2> "$WORKDIR/staticlib-package-build.err"
)
status=$?
set -e
assert_status staticlib-package-build "$status" 0
assert_empty staticlib-package-build "$WORKDIR/staticlib-package-build.err"
assert_contains staticlib-package-build "$WORKDIR/staticlib-package-build.out" "Generated:"
[ -s "$STATICLIB_ARCHIVE" ] || fail "staticlib package build did not write archive $STATICLIB_ARCHIVE"

STATICLIB_OVERRIDE="$WORKDIR/staticlib-entry-override"
mkdir -p "$STATICLIB_OVERRIDE/custom"
cat > "$STATICLIB_OVERRIDE/typelisp.pkg" <<'EOF'
(package
  (name "cli_staticlib_override")
  (version "0.1.0")
  (kind "staticlib")
  (entry "custom/entry.tl"))
EOF
cat > "$STATICLIB_OVERRIDE/custom/entry.tl" <<'EOF'
(define (override-answer) : i64 77)
EOF
STATICLIB_OVERRIDE_ARCHIVE="$STATICLIB_OVERRIDE/target/typelisp/cli_staticlib_override/libcli_staticlib_override.a"
if [ "$HOST_OS" = windows ]; then
    STATICLIB_OVERRIDE_ARCHIVE="$STATICLIB_OVERRIDE/target/typelisp/cli_staticlib_override/cli_staticlib_override.lib"
fi

set +e
(
    cd "$STATICLIB_OVERRIDE"
    "$COMPILER" build --target "$BUILD_TARGET" > "$WORKDIR/staticlib-entry-override.out" 2> "$WORKDIR/staticlib-entry-override.err"
)
status=$?
set -e
assert_status staticlib-entry-override "$status" 0
assert_empty staticlib-entry-override "$WORKDIR/staticlib-entry-override.err"
assert_contains staticlib-entry-override "$WORKDIR/staticlib-entry-override.out" "Generated:"
[ -s "$STATICLIB_OVERRIDE_ARCHIVE" ] || fail "staticlib package build did not honor explicit entry"

RUN_SRC="$WORKDIR/run-main.tl"
cat > "$RUN_SRC" <<'EOF'
(define (main) : i64
  (begin
    (print-string (arg 1))
    17))
EOF

set +e
"$COMPILER" run "$RUN_SRC" -- "run-arg-ok" > "$WORKDIR/run.out" 2> "$WORKDIR/run.err"
status=$?
set -e
assert_status run "$status" 17
assert_empty run "$WORKDIR/run.err"
assert_contains run "$WORKDIR/run.out" "run-arg-ok"

cat > "$WORKDIR/queue.json" <<'EOF'
{"prs":[],"issues":[{"number":1645,"title":"Host actions direct","labels":[{"name":"ready-for-implementation"}]}]}
EOF

set +e
"$COMPILER" run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib \
    < "$WORKDIR/queue.json" > "$WORKDIR/chooser.out" 2> "$WORKDIR/chooser.err"
status=$?
set -e
assert_status chooser "$status" 0
assert_empty chooser "$WORKDIR/chooser.err"
assert_contains chooser "$WORKDIR/chooser.out" "implement issue #1645: Host actions direct"

echo "selfhost cli build/run smoke passed"
