#!/usr/bin/env sh
set -eu

# verify-examples.sh — Compile every .tl file in examples/ and verify exit codes.
# refs #208

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "example verification is Linux-only (requires as + ld)" >&2
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

# Expected exit codes for each example program.
# Programs without a main function compile to an implicit main that returns 0.
expected_exit() {
    case "$1" in
        calc) echo 14 ;;
        char_literals) echo 64 ;;
        hello) echo 0 ;;
        lexer) echo 12 ;;
        nested_eval) echo 7 ;;
        parser) echo 14 ;;
        token) echo 0 ;;
        *) echo "unknown example: $1" >&2; exit 1 ;;
    esac
}

WORKDIR="$ROOT/target/example-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

failed=0

for source in "$ROOT/examples/"*.tl; do
    name=$(basename "$source" .tl)
    want=$(expected_exit "$name")
    asm="$WORKDIR/$name.s"
    obj="$WORKDIR/$name.o"
    bin="$WORKDIR/$name"

    echo "[$name] compiling $source"
    "$COMPILER" compile "$source" -o "$asm"

    as "$asm" -o "$obj"
    ld "$obj" -o "$bin"

    echo "[$name] running -> expect exit $want"
    set +e
    "$bin"
    got=$?
    set -e

    if [ "$got" -ne "$want" ]; then
        echo "FAIL: $name expected exit $want, got $got" >&2
        failed=$((failed + 1))
    else
        echo "PASS: $name exit $got"
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "$failed example(s) failed" >&2
    exit 1
fi

echo "All examples compiled, linked, and ran with expected exit codes."
