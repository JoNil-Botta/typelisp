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

# The check is host-agnostic in substance: it only runs `typelisp compile` (the
# default linux-x86_64 backend emits identical `.s` text regardless of host; no
# assembler/linker is invoked) twice and `cmp`s the outputs. Allow it on Linux
# and on Windows hosts (Git Bash / MSYS / Cygwin) so the Windows CI job can run
# it for parity (#755). Other hosts stay gated until the check is exercised
# there.
case "$(uname -s)" in
    Linux* | MINGW* | MSYS* | CYGWIN*) ;;
    *)
        echo "deterministic assembly check is unsupported on this host" >&2
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
    # Local-development fallback: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
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
tl_format_doc src/format_doc.tl
tl_lex src/lex.tl
tl_compiler_parse_core src/compiler_parse_core.tl
tl_compiler_symbols src/compiler_symbols.tl
tl_doc_extract src/doc_extract.tl
tl_doc_render src/doc_render.tl
tl_doc_html src/doc_html.tl
tl_read src/read.tl
tl_token src/token.tl
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
            cp src/sym_i64_env.tl "$input_dir/sym_i64_env_core.tl"
            cp src/compiler_intern.tl "$input_dir/compiler_intern.tl"
            echo "$input_dir/sym_i64_env.tl"
            ;;
        *)
            echo "$source"
            ;;
    esac
}

# Optional reuse of the compile-manifest gate's emitted assembly. When
# TYPELISP_DETERMINISTIC_ASM_MANIFEST_DIR points at a populated
# verify-selfhost-compile-manifest.sh work directory, corpus entries that have
# a `direct` manifest case take the manifest's .s as their first compile and
# only compile once more here (with the manifest-equivalent invocation, so the
# byte comparison stays valid). Determinism coverage is unchanged: every entry
# is still two independent compiles by the same binary, compared byte-for-byte
# (and the shared entries additionally assert batch/single-compile parity).
MANIFEST_SHARE_DIR=${TYPELISP_DETERMINISTIC_ASM_MANIFEST_DIR:-}
MANIFEST_FILE=${TYPELISP_COMPILE_MANIFEST:-src/compile_manifest.txt}

compiler_input_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

manifest_case_id_for_source() {
    [ -n "$MANIFEST_SHARE_DIR" ] || return 1
    [ -f "$MANIFEST_FILE" ] || return 1
    _id=$(tr -d '\r' < "$MANIFEST_FILE" | awk -F'|' -v src="$1" '
        $1 == "case" && $3 == src && $6 == "direct" { print $2; exit }
    ')
    [ -n "$_id" ] || return 1
    printf '%s\n' "$_id"
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
        if case_id=$(manifest_case_id_for_source "$source"); then
            shared_asm="$MANIFEST_SHARE_DIR/$case_id/$case_id.s"
            if [ "$pass_name" = run1 ]; then
                if [ ! -s "$shared_asm" ]; then
                    echo "compile-manifest assembly missing for $name: $shared_asm" >&2
                    echo "(run scripts/verify-selfhost-compile-manifest.sh first, or unset TYPELISP_DETERMINISTIC_ASM_MANIFEST_DIR)" >&2
                    exit 1
                fi
                echo "[$pass_name] reuse compile-manifest assembly for $name"
                cp "$shared_asm" "$out"
            else
                echo "[$pass_name] $source -> $out (compile-manifest invocation)"
                "$COMPILER" compile "$(compiler_input_path "$ROOT/$source")" -o "$out" \
                    --target linux-x86_64 \
                    --stdlib-root "$(compiler_input_path "$ROOT/stdlib")"
            fi
            continue
        fi
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
