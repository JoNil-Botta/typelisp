#!/usr/bin/env sh
set -eu

# verify-examples.sh — Compile every .tl file in examples/ and verify exit codes.
# refs #208

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Compile-only stage1 artifacts do not have the public `build` host action, so
# verify examples through explicit compile -> assemble -> link -> run using the
# same native linker setup as bootstrap and integration.
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

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

# Expected exit codes for each example program.
expected_exit() {
    case "$1" in
        calc) echo 14 ;;
        char_literals) echo 64 ;;
        hello) echo 120 ;;   # main returns factorial(5)
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

# On Windows, build from copies under the gitignored WORKDIR instead of
# polluting examples/. Copy the whole directory at once so sibling imports
# (e.g. calc.tl imports token.tl) still resolve among the copies.
if [ "$HOST_OS" = windows ]; then
    cp "$ROOT/examples/"*.tl "$WORKDIR/"
fi

failed=0

for source in "$ROOT/examples/"*.tl; do
    name=$(basename "$source" .tl)
    want=$(expected_exit "$name")
    asm="$WORKDIR/$name.s"
    obj="$WORKDIR/$name.$NL_OBJ_EXT"
    bin="$WORKDIR/$name$NL_BIN_EXT"

    if [ "$HOST_OS" = windows ]; then
        echo "[$name] compiling (windows-x86_64)"
        "$COMPILER" compile "$WORKDIR/$name.tl" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) -o "$asm"
        assemble_and_link "$name" "$asm" "$obj" "$bin"

        echo "[$name] running -> expect exit $want"
        set +e
        "$bin"
        got=$?
        set -e
    else
        echo "[$name] compiling $source"
        "$COMPILER" compile "$source" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) -o "$asm"
        assemble_and_link "$name" "$asm" "$obj" "$bin"

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
