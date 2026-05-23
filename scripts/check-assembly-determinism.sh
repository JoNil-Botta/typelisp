#!/usr/bin/env bash
# check-assembly-determinism.sh — Deterministic assembly output gate.
#
# Compiles a curated corpus of TypeLisp source files twice into separate
# output directories and verifies the emitted .s files match byte-for-byte.
# Exit 0 on full match, exit 1 and show diff on any mismatch.
#
# Usage:
#   ./scripts/check-assembly-determinism.sh [--self-test] [typelisp-binary]
#
# If no binary is given, uses cargo run --release --.
# --self-test: intentionally corrupt one output to verify the comparison
#   path correctly reports failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SELF_TEST=0
BINARY_ARG=""

for arg in "$@"; do
    if [ "$arg" = "--self-test" ]; then
        SELF_TEST=1
    else
        BINARY_ARG="$arg"
    fi
done

if [ -n "$BINARY_ARG" ]; then
    TYP_LISP="$BINARY_ARG"
else
    TYP_LISP="cargo run --quiet --manifest-path $REPO_ROOT/Cargo.toml --release --"
fi

# Corpus: representative TypeLisp programs that compile to assembly.
# Includes self-hosting components and integration test cases.
CORPUS=(
    tests/integration/arithmetic.tl
    tests/integration/calc.tl
    tests/integration/control_flow.tl
    tests/integration/enum_match.tl
    tests/integration/factorial.tl
    tests/integration/fibonacci.tl
    tests/integration/functions.tl
    tests/integration/hello.tl
    tests/integration/lexer.tl
    tests/integration/many_args.tl
    tests/integration/modules_main.tl
    tests/integration/narrow_div_mod.tl
    tests/integration/nested_eval.tl
    tests/integration/nullary_variant_call.tl
    tests/integration/parser.tl
    tests/integration/print.tl
    tests/integration/print_char.tl
    tests/integration/print_string.tl
    tests/integration/string_append.tl
    tests/integration/string_eq.tl
    tests/integration/string_length.tl
    tests/integration/substring.tl
    tests/integration/sym_i64_env.tl
    tests/integration/tl_alloc.tl
    tests/integration/tl_ast.tl
    tests/integration/tl_emit.tl
    tests/integration/tl_eval.tl
    tests/integration/tl_lex.tl
    tests/integration/tl_lexer.tl
    tests/integration/tl_parse.tl
    tests/integration/tl_read.tl
    tests/integration/tl_reader.tl
    tests/integration/tl_token.tl
    tests/integration/token.tl
    tests/integration/tree.tl
    tests/integration/unit_functions.tl
    tests/integration/unit_main.tl
)

# Verify corpus files exist before building anything.
missing=0
for f in "${CORPUS[@]}"; do
    if [[ ! -f "$REPO_ROOT/$f" ]]; then
        echo "ERROR: corpus file not found: $f" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    exit 1
fi

# Build the compiler once up front if using cargo.
if [ $# -lt 1 ]; then
    echo "==> Building typelisp compiler (release)..." >&2
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --quiet
fi

TMP_A="$(mktemp -d /tmp/typelisp-determinism-a.XXXXXX)"
TMP_B="$(mktemp -d /tmp/typelisp-determinism-b.XXXXXX)"
trap "rm -rf '$TMP_A' '$TMP_B'" EXIT

failed=0
for f in "${CORPUS[@]}"; do
    src="$REPO_ROOT/$f"
    base="$(basename "$f" .tl)"
    mkdir -p "$TMP_A/$base" "$TMP_B/$base"

    $TYP_LISP compile "$src" -o "$TMP_A/$base/output.s"
    $TYP_LISP compile "$src" -o "$TMP_B/$base/output.s"

    if ! diff -q "$TMP_A/$base/output.s" "$TMP_B/$base/output.s" > /dev/null; then
        echo "MISMATCH: $f" >&2
        diff -u "$TMP_A/$base/output.s" "$TMP_B/$base/output.s" >&2 || true
        failed=1
    fi
done

if [ "$SELF_TEST" -eq 1 ]; then
    # Intentionally mutate one output to verify the comparison path fails.
    first_base="$(basename "${CORPUS[0]}" .tl)"
    echo "; SELF-TEST MUTATION" >> "$TMP_A/$first_base/output.s"
    echo "==> Self-test: intentionally mutated $first_base output.s" >&2
    if diff -q "$TMP_A/$first_base/output.s" "$TMP_B/$first_base/output.s" > /dev/null; then
        echo "FAIL: self-test mutation did not trigger a mismatch" >&2
        exit 1
    else
        echo "PASS: self-test correctly detected the mutation."
        exit 0
    fi
fi

if [ "$failed" -eq 0 ]; then
    echo "PASS: all ${#CORPUS[@]} corpus files produced identical assembly across two compilations."
    exit 0
else
    echo "FAIL: deterministic assembly gate failed." >&2
    exit 1
fi
