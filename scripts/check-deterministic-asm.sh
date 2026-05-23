#!/usr/bin/env sh
set -eu

usage() {
    echo "usage: $0 [--self-test]" >&2
}

self_test=0
if [ "${1:-}" = "--self-test" ]; then
    self_test=1
elif [ "${1:-}" != "" ]; then
    usage
    exit 2
fi

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "deterministic assembly check is Linux-only" >&2
        exit 1
        ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKDIR=${DETERMINISTIC_ASM_DIR:-target/deterministic-asm}
RUN1="$WORKDIR/run1"
RUN2="$WORKDIR/run2"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --quiet
    COMPILER="$ROOT/target/debug/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

corpus() {
    cat <<'EOF'
tl_lexer tests/integration/tl_lexer.tl
tl_reader tests/integration/tl_reader.tl
tl_eval tests/integration/tl_eval.tl
tl_ast tests/integration/tl_ast.tl
tl_emit tests/integration/tl_emit.tl
tl_parse tests/integration/tl_parse.tl
calc tests/integration/calc.tl
modules_main tests/integration/modules_main.tl
tree tests/integration/tree.tl
enum_string_payload tests/integration/enum_string_payload.tl
substring tests/integration/substring.tl
string_eq tests/integration/string_eq.tl
string_append tests/integration/string_append.tl
print_string tests/integration/print_string.tl
nested_eval tests/integration/nested_eval.tl
char_literals examples/char_literals.tl
sym_i64_env tests/integration/sym_i64_env.tl
EOF
}

compile_pass() {
    pass_name=$1
    out_dir=$2

    mkdir -p "$out_dir"
    corpus | while read -r name source; do
        [ -n "$name" ] || continue
        out="$out_dir/$name.s"
        echo "[$pass_name] $source -> $out"
        "$COMPILER" compile "$source" -o "$out"
    done
}

compare_outputs() {
    failed_marker="$WORKDIR/.deterministic-asm-failed"
    rm -f "$failed_marker"

    corpus | while read -r name _source; do
        [ -n "$name" ] || continue
        left="$RUN1/$name.s"
        right="$RUN2/$name.s"

        if ! cmp -s "$left" "$right"; then
            echo "deterministic assembly mismatch: $name" >&2
            if command -v diff >/dev/null 2>&1; then
                diff -u "$left" "$right" || true
            else
                cmp -l "$left" "$right" | sed -n '1,40p' || true
            fi
            : > "$failed_marker"
        fi
    done

    [ ! -f "$failed_marker" ]
}

rm -rf "$RUN1" "$RUN2"
mkdir -p "$RUN1" "$RUN2"

compile_pass run1 "$RUN1"
compile_pass run2 "$RUN2"

if [ "$self_test" -eq 1 ]; then
    if ! compare_outputs; then
        echo "--self-test setup failed: fresh outputs already differ" >&2
        exit 1
    fi

    printf '\n# deterministic-asm self-test mutation\n' >> "$RUN2/tl_lexer.s"
    if compare_outputs; then
        echo "--self-test failed: mutated output was not detected" >&2
        exit 1
    fi
    echo "--self-test passed: mutated output was detected"
    exit 0
fi

if ! compare_outputs; then
    exit 1
fi

echo "deterministic assembly check passed for $(corpus | wc -l | tr -d ' ') files"
