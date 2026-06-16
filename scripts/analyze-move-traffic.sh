#!/usr/bin/env sh
set -eu

# analyze-move-traffic.sh - deterministic adjacent movq traffic census.
#
# By default this compiles src/main.tl with TYPELISP_BIN (or the published
# stage0 fallback) and analyzes the emitted assembly. Use --asm to analyze an
# existing assembly file.

usage() {
    cat >&2 <<'EOF'
usage: scripts/analyze-move-traffic.sh [options] [typelisp-binary]

Options:
  --asm <file>       analyze an existing assembly file instead of compiling
  --target <name>    pass --target <name> to typelisp compile
  --opt-level <n>    pass --opt-level <n> to typelisp compile

Environment:
  TYPELISP_BIN                compiler path when no positional compiler is given
  TYPELISP_MOVE_TRAFFIC_OUT   output directory (default target/move-traffic)
  TYPELISP_MOVE_TRAFFIC_TARGET default --target value
  TYPELISP_MOVE_TRAFFIC_OPT_LEVEL default --opt-level value
EOF
}

ASM_ARG=""
TARGET=${TYPELISP_MOVE_TRAFFIC_TARGET:-}
OPT_LEVEL=${TYPELISP_MOVE_TRAFFIC_OPT_LEVEL:-}
compiler_arg=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --asm)
            shift
            [ "$#" -gt 0 ] || {
                usage
                exit 2
            }
            ASM_ARG=$1
            ;;
        --target)
            shift
            [ "$#" -gt 0 ] || {
                usage
                exit 2
            }
            TARGET=$1
            ;;
        --opt-level)
            shift
            [ "$#" -gt 0 ] || {
                usage
                exit 2
            }
            OPT_LEVEL=$1
            ;;
        -h | --help)
            usage
            exit 0
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

case "$OPT_LEVEL" in
    "" | 0 | 1 | 2) ;;
    *)
        echo "--opt-level must be 0, 1, or 2: $OPT_LEVEL" >&2
        exit 2
        ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKDIR=${TYPELISP_MOVE_TRAFFIC_OUT:-target/move-traffic}
ASM_PATH=${ASM_ARG:-"$WORKDIR/selfhost.s"}
SOURCE=src/main.tl

if [ -n "$ASM_ARG" ]; then
    [ -f "$ASM_PATH" ] || {
        echo "assembly file not found: $ASM_PATH" >&2
        exit 1
    }
    COMPILER="(not used; --asm supplied)"
else
    mkdir -p "$WORKDIR"
    if [ -n "$compiler_arg" ]; then
        COMPILER=$compiler_arg
    elif [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi

    if [ ! -x "$COMPILER" ]; then
        echo "typelisp compiler is not executable: $COMPILER" >&2
        exit 1
    fi

    compile_stdout="$WORKDIR/compile.stdout"
    compile_stderr="$WORKDIR/compile.stderr"
    echo "[move-traffic] compile $SOURCE -> $ASM_PATH" >&2
    set -- "$COMPILER" compile "$SOURCE" -o "$ASM_PATH"
    if [ -n "$TARGET" ]; then
        set -- "$@" --target "$TARGET"
    fi
    if [ -n "$OPT_LEVEL" ]; then
        set -- "$@" --opt-level "$OPT_LEVEL"
    fi
    set -- "$@" --stdlib-root stdlib --stdlib-root src
    if ! "$@" >"$compile_stdout" 2>"$compile_stderr"; then
        echo "[move-traffic] compile failed" >&2
        sed 's/^/  /' "$compile_stdout" >&2 || true
        sed 's/^/  /' "$compile_stderr" >&2 || true
        exit 1
    fi
fi

[ -s "$ASM_PATH" ] || {
    echo "assembly file is empty: $ASM_PATH" >&2
    exit 1
}

echo "move_traffic_census"
printf 'source\t%s\n' "$SOURCE"
printf 'assembly\t%s\n' "$ASM_PATH"
printf 'compiler\t%s\n' "$COMPILER"
if [ -n "$TARGET" ]; then
    printf 'target\t%s\n' "$TARGET"
fi
if [ -n "$OPT_LEVEL" ]; then
    printf 'opt_level\t%s\n' "$OPT_LEVEL"
fi
printf 'metric\tcount\n'

awk '
function is_reg(value) {
    return value ~ /^%[A-Za-z0-9]+$/
}

function is_stack(value) {
    return value ~ /^-?[0-9]+[(]%rbp[)]$/
}

function is_local(value) {
    return is_reg(value) || is_stack(value)
}

function clear_prev() {
    prev_src = ""
    prev_dst = ""
    has_prev = 0
}

function parse_movq(line, body, comma) {
    if (line !~ /^    movq /) {
        return 0
    }
    body = substr(line, 10)
    comma = index(body, ", ")
    if (comma <= 1) {
        return 0
    }
    src = substr(body, 1, comma - 1)
    dst = substr(body, comma + 2)
    return 1
}

{
    if (!parse_movq($0)) {
        clear_prev()
        next
    }

    movq_total += 1
    if (is_local(src) && is_local(dst)) {
        local_movq_total += 1
    }

    if (has_prev) {
        adjacent_movq_pairs += 1
        if (prev_src == src && prev_dst == dst) {
            exact_duplicate_pairs += 1
        }
        if (prev_src == dst && prev_dst == src) {
            swap_back_pairs += 1
        }
        if (is_stack(prev_src) && prev_src == src && is_reg(prev_dst) && is_reg(dst)) {
            stack_load_same_slot_pairs += 1
        }
        if (is_reg(prev_src) && is_reg(src) && is_stack(prev_dst) && prev_dst == dst) {
            stack_store_same_slot_pairs += 1
        }
        if (is_reg(prev_src) && is_stack(prev_dst) && prev_dst == src && is_reg(dst)) {
            store_then_load_same_slot_pairs += 1
        }
    }

    prev_src = src
    prev_dst = dst
    has_prev = 1
}

END {
    printf "movq_total\t%d\n", movq_total
    printf "local_movq_total\t%d\n", local_movq_total
    printf "adjacent_movq_pairs\t%d\n", adjacent_movq_pairs
    printf "exact_duplicate_pairs\t%d\n", exact_duplicate_pairs
    printf "swap_back_pairs\t%d\n", swap_back_pairs
    printf "stack_load_same_slot_pairs\t%d\n", stack_load_same_slot_pairs
    printf "store_then_load_same_slot_pairs\t%d\n", store_then_load_same_slot_pairs
    printf "stack_store_same_slot_pairs\t%d\n", stack_store_same_slot_pairs
}
' "$ASM_PATH"
