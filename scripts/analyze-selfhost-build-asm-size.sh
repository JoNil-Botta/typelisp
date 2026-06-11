#!/usr/bin/env sh
set -eu

# analyze-selfhost-build-asm-size.sh - local assembly size report for the
# retained selfhost/build.tl compatibility wrapper. The default path compiles
# the source with TYPELISP_BIN when set, otherwise with the published stage0
# selected by scripts/lib-stage0.sh.

usage() {
    cat >&2 <<'EOF'
usage: scripts/analyze-selfhost-build-asm-size.sh [options] [typelisp-binary]

Options:
  --asm <file>      analyze an existing assembly file instead of compiling
  --top <n>         number of top symbols/modules to print (default: 20)
  --target <name>   pass --target <name> to typelisp compile

Environment:
  TYPELISP_BIN              compiler path when no positional compiler is given
  TYPELISP_ASM_SIZE_OUT     output directory (default: target/selfhost-build-asm-size)
  TYPELISP_ASM_SIZE_TOP     default --top value
  TYPELISP_ASM_SIZE_TARGET  default --target value
EOF
}

ASM_ARG=""
TOP_N=${TYPELISP_ASM_SIZE_TOP:-20}
TARGET=${TYPELISP_ASM_SIZE_TARGET:-}
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
        --top)
            shift
            [ "$#" -gt 0 ] || {
                usage
                exit 2
            }
            TOP_N=$1
            ;;
        --target)
            shift
            [ "$#" -gt 0 ] || {
                usage
                exit 2
            }
            TARGET=$1
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

case "$TOP_N" in
    '' | *[!0-9]*)
        echo "--top must be a positive integer: $TOP_N" >&2
        exit 2
        ;;
    0)
        echo "--top must be greater than zero" >&2
        exit 2
        ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKDIR=${TYPELISP_ASM_SIZE_OUT:-target/selfhost-build-asm-size}
ASM_PATH=${ASM_ARG:-"$WORKDIR/build.s"}
SOURCE=selfhost/build.tl

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
    echo "[asm-size] compile $SOURCE -> $ASM_PATH" >&2
    if [ -n "$TARGET" ]; then
        if ! "$COMPILER" compile "$SOURCE" -o "$ASM_PATH" \
            --target "$TARGET" \
            --stdlib-root stdlib \
            --stdlib-root selfhost \
            >"$compile_stdout" 2>"$compile_stderr"; then
            echo "[asm-size] compile failed" >&2
            sed 's/^/  /' "$compile_stdout" >&2 || true
            sed 's/^/  /' "$compile_stderr" >&2 || true
            exit 1
        fi
    else
        if ! "$COMPILER" compile "$SOURCE" -o "$ASM_PATH" \
            --stdlib-root stdlib \
            --stdlib-root selfhost \
            >"$compile_stdout" 2>"$compile_stderr"; then
            echo "[asm-size] compile failed" >&2
            sed 's/^/  /' "$compile_stdout" >&2 || true
            sed 's/^/  /' "$compile_stderr" >&2 || true
            exit 1
        fi
    fi
fi

[ -s "$ASM_PATH" ] || {
    echo "assembly file is empty: $ASM_PATH" >&2
    exit 1
}

tmp_root=${TMPDIR:-${TEMP:-/tmp}}
tmp_dir=$(mktemp -d "$tmp_root/tl-asm-size.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

sections_tsv="$tmp_dir/sections.tsv"
symbols_tsv="$tmp_dir/symbols.tsv"
modules_tsv="$tmp_dir/modules.tsv"
clone_symbols_tsv="$tmp_dir/clone-symbols.tsv"
tab=$(printf '\t')

awk -v sections="$sections_tsv" -v symbols="$symbols_tsv" '
function decode_name(value, decoded) {
    decoded = value
    gsub(/_colon_colon/, "::", decoded)
    gsub(/_slash/, "/", decoded)
    gsub(/_question/, "?", decoded)
    gsub(/_bang/, "!", decoded)
    gsub(/_u24/, "$", decoded)
    gsub(/_u2e/, ".", decoded)
    gsub(/_u2d/, "-", decoded)
    return decoded
}

function display_name(raw, value) {
    value = raw
    if (value ~ /^_tl_/) {
        sub(/^_tl_/, "", value)
        return decode_name(value)
    }
    return raw
}

function module_name(raw, value, split_at) {
    if (raw ~ /^_tl___enum_obj_/) {
        return "generated/enum-objects"
    }
    if (raw ~ /^_tl_/) {
        value = raw
        sub(/^_tl_/, "", value)
        split_at = index(value, "_colon_colon")
        if (split_at > 0) {
            return decode_name(substr(value, 1, split_at - 1))
        }
        return "generated/type-lisp"
    }
    if (raw == "main" || raw == "_start" || raw == "_tl_start" || raw ~ /^tl_/) {
        return "runtime/entry"
    }
    return "runtime/other"
}

function flush_symbol() {
    if (current_symbol != "" && symbol_bytes > 0) {
        print current_symbol "\t" current_display "\t" current_module "\t" symbol_bytes "\t" symbol_lines >> symbols
    }
    current_symbol = ""
    current_display = ""
    current_module = ""
    symbol_bytes = 0
    symbol_lines = 0
}

function section_directive(line, value) {
    if (line == ".text" || line == ".data" || line == ".bss") {
        return line
    }
    if (line ~ /^\.section[ \t]+/) {
        value = line
        sub(/^\.section[ \t]+/, "", value)
        sub(/[ \t,].*$/, "", value)
        return ".section " value
    }
    return ""
}

{
    line = $0
    next_section = section_directive(line)

    if (next_section != "") {
        flush_symbol()
        current_section = next_section
    } else if (current_section == ".text" && line ~ /^\.globl[ \t]+/) {
        flush_symbol()
    } else if (current_section == ".text" && line ~ /^[A-Za-z_][A-Za-z0-9_.$@]*:$/) {
        flush_symbol()
        current_symbol = line
        sub(/:$/, "", current_symbol)
        current_display = display_name(current_symbol)
        current_module = module_name(current_symbol)
    }

    if (current_section == "") {
        current_section = "(preamble)"
    }

    line_bytes = length(line) + 1
    section_bytes[current_section] += line_bytes
    section_lines[current_section] += 1

    if (current_section == ".text" && current_symbol != "") {
        symbol_bytes += line_bytes
        symbol_lines += 1
    }
}

END {
    flush_symbol()
    for (section in section_bytes) {
        print section "\t" section_bytes[section] "\t" section_lines[section] >> sections
    }
}
' "$ASM_PATH"

awk -F '\t' '
{
    module = $3
    module_bytes[module] += $4
    module_lines[module] += $5
    module_symbols[module] += 1
}
END {
    for (module in module_bytes) {
        print module "\t" module_bytes[module] "\t" module_lines[module] "\t" module_symbols[module]
    }
}
' "$symbols_tsv" > "$modules_tsv"

awk -F '\t' '$1 ~ /_colon_colonclone_u24/ { print }' "$symbols_tsv" > "$clone_symbols_tsv"

total_bytes=$(wc -c < "$ASM_PATH" | tr -d ' ')
total_lines=$(wc -l < "$ASM_PATH" | tr -d ' ')
symbol_count=$(wc -l < "$symbols_tsv" | tr -d ' ')
clone_total=$(awk -F '\t' '
{
    bytes += $4
    lines += $5
    symbols += 1
}
END {
    printf "%d\t%d\t%d\n", bytes, lines, symbols
}
' "$clone_symbols_tsv")

echo "selfhost_build_assembly_size"
printf 'source\t%s\n' "$SOURCE"
printf 'assembly\t%s\n' "$ASM_PATH"
printf 'compiler\t%s\n' "$COMPILER"
if [ -n "$TARGET" ]; then
    printf 'target\t%s\n' "$TARGET"
fi
printf 'total_bytes\t%s\n' "$total_bytes"
printf 'total_lines\t%s\n' "$total_lines"
printf 'text_symbols\t%s\n' "$symbol_count"

echo
echo "section_totals"
printf 'section\tbytes\tlines\n'
sort -t "$tab" -k1,1 "$sections_tsv"

echo
echo "top_text_symbols"
printf 'bytes\tlines\tmodule\tsymbol\n'
sort -t "$tab" -k4,4nr -k2,2 "$symbols_tsv" \
    | head -n "$TOP_N" \
    | awk -F '\t' '{ printf "%s\t%s\t%s\t%s\n", $4, $5, $3, $2 }'

echo
echo "top_text_modules"
printf 'bytes\tlines\tsymbols\tmodule\n'
sort -t "$tab" -k2,2nr -k1,1 "$modules_tsv" \
    | head -n "$TOP_N" \
    | awk -F '\t' '{ printf "%s\t%s\t%s\t%s\n", $2, $3, $4, $1 }'

echo
echo "generated_clone_helpers"
printf 'bytes\tlines\tsymbols\n'
printf '%s\n' "$clone_total"

echo
echo "top_generated_clone_helpers"
printf 'bytes\tlines\tmodule\tsymbol\n'
sort -t "$tab" -k4,4nr -k2,2 "$clone_symbols_tsv" \
    | head -n "$TOP_N" \
    | awk -F '\t' '{ printf "%s\t%s\t%s\t%s\n", $4, $5, $3, $2 }'
