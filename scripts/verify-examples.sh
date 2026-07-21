#!/usr/bin/env sh
set -eu

# verify-examples.sh — Compile every .tl file in examples/ and verify its exit
# code plus exact user-visible stdout.
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
    # Local-development fallback: fetch the published
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
        arena_lifetimes) echo 42 ;;
        calc) echo 14 ;;
        char_literals) echo 64 ;;
        hello) echo 0 ;;
        lexer) echo 12 ;;
        nested_eval) echo 7 ;;
        parser) echo 14 ;;
        safe_threading) echo 42 ;;
        token) echo 0 ;;
        *) echo "unknown example: $1" >&2; exit 1 ;;
    esac
}

# Exact user-visible output for each runnable example. Keeping these transcripts
# checked makes the examples useful from a terminal instead of relying only on
# otherwise invisible process exit codes.
expected_stdout() {
    case "$1" in
        arena_lifetimes) printf '%s\n' 'arena lifetime score: 42' ;;
        calc) printf '%s\n' 'calculator result: 14' ;;
        char_literals) printf '%s\n' 'character literal code sum: 64' ;;
        hello)
            printf '%s\n' \
                'Hello, TypeLisp!' \
                'factorial(5) = 120'
            ;;
        lexer) printf '%s\n' 'lexer score: 12' ;;
        nested_eval) printf '%s\n' 'nested evaluator result: 7' ;;
        parser) printf '%s\n' 'parser result: 14' ;;
        safe_threading) printf '%s\n' 'safe threading score: 42' ;;
        token) : ;;
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
    stdout="$WORKDIR/$name.stdout"
    stderr="$WORKDIR/$name.stderr"
    want_stdout="$WORKDIR/$name.expected.stdout"
    expected_stdout "$name" > "$want_stdout"

    echo "[$name] checking format and source conventions"
    "$COMPILER" fmt --check "$source"
    "$COMPILER" lint "$source" --check \
        --deprecated-string-concat \
        --redundant-function-name \
        --prefer-dotted-field \
        --name-case

    if [ "$HOST_OS" = windows ]; then
        echo "[$name] compiling (windows-x86_64)"
        "$COMPILER" compile "$WORKDIR/$name.tl" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) -o "$asm"
        assemble_and_link "$name" "$asm" "$obj" "$bin"

        echo "[$name] running -> expect exit $want"
        set +e
        "$bin" > "$stdout" 2> "$stderr"
        got=$?
        set -e
    else
        echo "[$name] compiling $source"
        "$COMPILER" compile "$source" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) -o "$asm"
        assemble_and_link "$name" "$asm" "$obj" "$bin"

        echo "[$name] running -> expect exit $want"
        set +e
        "$bin" > "$stdout" 2> "$stderr"
        got=$?
        set -e
    fi

    cat "$stdout"
    if [ "$got" -ne "$want" ]; then
        echo "FAIL: $name expected exit $want, got $got" >&2
        failed=$((failed + 1))
    else
        echo "PASS: $name exit $got"
    fi
    if [ -s "$stderr" ]; then
        echo "FAIL: $name wrote unexpected stderr" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        failed=$((failed + 1))
    fi
    if ! cmp -s "$want_stdout" "$stdout"; then
        echo "FAIL: $name stdout mismatch" >&2
        echo "expected:" >&2
        sed 's/^/  /' "$want_stdout" >&2 || true
        echo "actual:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        failed=$((failed + 1))
    else
        echo "PASS: $name stdout"
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "$failed example(s) failed" >&2
    exit 1
fi

echo "All examples compiled, linked, and ran with expected exit codes and stdout."
