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
if [ "$HOST_OS" = windows ]; then
    BUILD_EXE="$BUILD_EXE.exe"
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
