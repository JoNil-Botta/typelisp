#!/usr/bin/env sh
set -eu

usage() {
    echo "usage: $0 [--self-test] [typelisp-binary]" >&2
}

self_test=0
compiler_arg=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --self-test)
            self_test=1
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            if [ -n "$compiler_arg" ]; then
                usage
                exit 2
            fi
            compiler_arg=$1
            ;;
    esac
    shift
done

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

if [ -n "$compiler_arg" ]; then
    COMPILER=$compiler_arg
elif [ -n "${TYPELISP_BIN:-}" ]; then
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
arithmetic tests/integration/arithmetic.tl
argv tests/integration/argv.tl
calc tests/integration/calc.tl
control_flow tests/integration/control_flow.tl
enum_match tests/integration/enum_match.tl
enum_string_payload tests/integration/enum_string_payload.tl
factorial tests/integration/factorial.tl
fibonacci tests/integration/fibonacci.tl
functions tests/integration/functions.tl
hello tests/integration/hello.tl
lexer tests/integration/lexer.tl
many_args tests/integration/many_args.tl
modules_main tests/integration/modules_main.tl
narrow_div_mod tests/integration/narrow_div_mod.tl
nested_eval tests/integration/nested_eval.tl
nullary_variant_call tests/integration/nullary_variant_call.tl
parser tests/integration/parser.tl
print tests/integration/print.tl
print_char tests/integration/print_char.tl
print_string tests/integration/print_string.tl
string_append tests/integration/string_append.tl
string_eq tests/integration/string_eq.tl
string_length tests/integration/string_length.tl
substring tests/integration/substring.tl
sym_i64_env tests/integration/sym_i64_env.tl
tl_alloc tests/integration/tl_alloc.tl
tl_ast selfhost/ast.tl
tl_emit selfhost/emit.tl
tl_eval selfhost/eval.tl
tl_lex selfhost/lex.tl
tl_lexer selfhost/lexer.tl
tl_parse_core selfhost/parse_core.tl
tl_parse selfhost/parse.tl
tl_compile_smoke selfhost/compile_smoke.tl
tl_read selfhost/read.tl
tl_reader selfhost/reader.tl
tl_token selfhost/token.tl
token tests/integration/token.tl
tree tests/integration/tree.tl
unit_functions tests/integration/unit_functions.tl
unit_main tests/integration/unit_main.tl
char_literals examples/char_literals.tl
EOF
}

compile_source_for_case() {
    name=$1
    source=$2
    out_dir=$3

    case "$name" in
        sym_i64_env)
            input_dir="$out_dir/.inputs/$name"
            rm -rf "$input_dir"
            mkdir -p "$input_dir"
            cp "$source" "$input_dir/sym_i64_env.tl"
            cp selfhost/sym_i64_env.tl "$input_dir/sym_i64_env_core.tl"
            echo "$input_dir/sym_i64_env.tl"
            ;;
        *)
            echo "$source"
            ;;
    esac
}

compile_pass() {
    pass_name=$1
    out_dir=$2

    mkdir -p "$out_dir"
    corpus | while read -r name source; do
        [ -n "$name" ] || continue
        if [ ! -f "$source" ]; then
            echo "corpus file not found: $source" >&2
            exit 1
        fi
        out="$out_dir/$name.s"
        compile_source=$(compile_source_for_case "$name" "$source" "$out_dir")
        echo "[$pass_name] $compile_source -> $out"
        "$COMPILER" compile "$compile_source" -o "$out"
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

    first_name=$(corpus | sed -n '1s/ .*//p')
    printf '\n# deterministic-asm self-test mutation\n' >> "$RUN2/$first_name.s"
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
