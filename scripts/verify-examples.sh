#!/usr/bin/env sh
set -eu

# verify-examples.sh — Compile every .tl file in examples/ and verify exit codes.
# refs #208

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Linux verifies through the GNU `as`/`ld` pipeline; Windows (Git Bash / MSYS /
# Cygwin on the CI runner) verifies through the host-default native toolchain
# (`typelisp build` -> `clang`/`lld-link`), mirroring tests/windows_native.rs.
HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "example verification is unsupported on this host" >&2
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

# On Windows, `typelisp build` emits intermediate .s/.obj next to its input, so
# build from copies under the gitignored WORKDIR instead of polluting examples/.
# Copy the whole directory at once so sibling imports (e.g. calc.tl imports
# token.tl) still resolve among the copies.
if [ "$HOST_OS" = windows ]; then
    cp "$ROOT/examples/"*.tl "$WORKDIR/"
fi

failed=0

for source in "$ROOT/examples/"*.tl; do
    name=$(basename "$source" .tl)
    want=$(expected_exit "$name")
    asm="$WORKDIR/$name.s"
    obj="$WORKDIR/$name.o"
    bin="$WORKDIR/$name"

    if [ "$HOST_OS" = windows ]; then
        echo "[$name] building (host default)"
        "$COMPILER" build "$WORKDIR/$name.tl" -o "$bin.exe"

        echo "[$name] running -> expect exit $want"
        set +e
        "$bin.exe"
        got=$?
        set -e
    else
        echo "[$name] compiling $source"
        "$COMPILER" compile "$source" -o "$asm"

        as "$asm" -o "$obj"
        ld "$obj" -o "$bin"

        echo "[$name] running -> expect exit $want"
        set +e
        "$bin"
        got=$?
        set -e
    fi

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
