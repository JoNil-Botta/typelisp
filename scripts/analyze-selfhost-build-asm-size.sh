#!/usr/bin/env sh
set -eu

# Attribute selfhost compiler code size. Assembly mode retains the historical
# source-text character report. --object enables the authoritative report:
# sized text symbols are reconciled with the linked object's .text sections.

usage() {
    cat >&2 <<'EOF'
usage: scripts/analyze-selfhost-build-asm-size.sh [options] [typelisp-binary]

Options:
  --asm <file>              analyze an existing assembly file
  --object <file>           attribute sized text symbols in an unstripped object
  --binary <file>           also report the final linked binary's file/.text bytes
  --target <name>           target triple recorded in the report
  --opt-level <0|1|2>       optimization level (default: 2 when compiling)
  --producer <description>  exact compiler producer recorded in the report
  --producer-binary <file>  record a compiler path, SHA-256, and --version output
  --tsv <file>              write a deterministic machine-readable TSV report
  --top <n>                 number of top modules/symbols to print (default: 20)
  --self-test               run current-symbol classification fixtures

With none of --asm, --object, or --binary, the script compiles src/main.tl and
reports assembly characters. Pass --object for trustworthy linked code bytes.

Environment:
  TYPELISP_BIN              compiler path when no positional compiler is given
  TYPELISP_ASM_SIZE_OUT     output directory (default: target/selfhost-build-asm-size)
  TYPELISP_ASM_SIZE_TOP     default --top value
  TYPELISP_ASM_SIZE_TARGET  default --target value
EOF
}

ASM_ARG=
OBJECT_ARG=
BINARY_ARG=
TARGET=${TYPELISP_ASM_SIZE_TARGET:-}
OPT_LEVEL=
PRODUCER=
PRODUCER_BINARY=
TSV_OUT=
TOP_N=${TYPELISP_ASM_SIZE_TOP:-20}
SELF_TEST=0
compiler_arg=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --asm | --object | --binary | --target | --opt-level | --producer | --producer-binary | --tsv | --top)
            option=$1
            shift
            [ "$#" -gt 0 ] || {
                echo "missing value for $option" >&2
                usage
                exit 2
            }
            case "$option" in
                --asm) ASM_ARG=$1 ;;
                --object) OBJECT_ARG=$1 ;;
                --binary) BINARY_ARG=$1 ;;
                --target) TARGET=$1 ;;
                --opt-level) OPT_LEVEL=$1 ;;
                --producer) PRODUCER=$1 ;;
                --producer-binary) PRODUCER_BINARY=$1 ;;
                --tsv) TSV_OUT=$1 ;;
                --top) TOP_N=$1 ;;
            esac
            ;;
        --self-test) SELF_TEST=1 ;;
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
case "$OPT_LEVEL" in
    '' | 0 | 1 | 2) ;;
    *)
        echo "--opt-level must be 0, 1, or 2: $OPT_LEVEL" >&2
        exit 2
        ;;
esac
if [ -n "$PRODUCER" ] && [ -n "$PRODUCER_BINARY" ]; then
    echo "use only one of --producer and --producer-binary" >&2
    exit 2
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

tmp_root=${TMPDIR:-${TEMP:-/tmp}}
tmp_dir=$(mktemp -d "$tmp_root/tl-selfhost-size.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
module_prefixes_tsv="$tmp_dir/module-prefixes.tsv"
tab=$(printf '\t')

# Current symbols no longer encode module separators as _colon_colon. Mirror
# compiler_backend.tl's path mangling and prefer the longest checked-in module
# prefix, so compiler_backend wins over any shorter compiler prefix.
find src stdlib -type f -name '*.tl' -print \
    | LC_ALL=C sort \
    | awk '
function mangle_path(value) {
    sub(/^src\//, "", value)
    sub(/\.tl$/, "", value)
    gsub(/[\\\/:.]+/, "_", value)
    gsub(/-/, "_", value)
    return value
}
{
    source = $0
    prefix = mangle_path($0)
    print length(prefix) "\t" prefix "\t" source
}
' \
    | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2 \
    | awk -F '\t' 'BEGIN { OFS = "\t" } { print $2, $3 }' \
    > "$module_prefixes_tsv"
duplicate_prefix=$(cut -f 1 "$module_prefixes_tsv" | LC_ALL=C sort | uniq -d | awk 'NR == 1 { print; exit }')
if [ -n "$duplicate_prefix" ]; then
    echo "checked-in modules have an ambiguous mangled prefix: $duplicate_prefix" >&2
    exit 1
fi

classify_symbols() {
    raw_input=$1
    classified_output=$2
    awk -F '\t' '
BEGIN { OFS = "\t" }
NR == FNR {
    prefix_count += 1
    prefixes[prefix_count] = $1
    modules[prefix_count] = $2
    next
}
function starts_module(value, prefix) {
    return value == prefix || index(value, prefix "_") == 1
}
function display_name(raw, value) {
    value = raw
    sub(/^_tl_/, "", value)
    gsub(/_question/, "?", value)
    gsub(/_bang/, "!", value)
    gsub(/_plus/, "+", value)
    gsub(/_star/, "*", value)
    gsub(/_eq/, "=", value)
    gsub(/_lt/, "<", value)
    gsub(/_gt/, ">", value)
    gsub(/_u24/, "$", value)
    return value
}
{
    raw = $1
    bytes = $2 + 0
    metric = $3 + 0
    address = $4
    symbol_type = $5
    module = "runtime/other"
    family = "runtime"
    matched_prefix = ""
    remainder = ""

    if (raw == "main" || raw == "_start" || raw == "_tl_start" || raw ~ /^tl_/) {
        module = "runtime/entry"
    } else if (raw ~ /^_tl___enum_obj_/) {
        module = "generated/enum-objects"
        family = "enum-object"
    } else if (raw ~ /^_tl_/) {
        family = "ordinary"
        body = raw
        sub(/^_tl_/, "", body)
        match_body = body
        if (raw ~ /^_tl___global_init_/) {
            sub(/^__global_init_/, "", match_body)
            family = "global-init"
        }
        module = "generated/type-lisp"
        for (i = 1; i <= prefix_count; i += 1) {
            if (starts_module(match_body, prefixes[i])) {
                matched_prefix = prefixes[i]
                module = modules[i]
                remainder = substr(match_body, length(matched_prefix) + 2)
                break
            }
        }
        if (raw ~ /_clone_u24/) {
            family = "clone"
        } else if (family == "ordinary" && remainder ~ /^stdlib_[A-Za-z0-9_]*_generated_/) {
            family = "specialization"
        }
    }
    print raw, display_name(raw), module, family, bytes, metric, address, symbol_type
}
' "$module_prefixes_tsv" "$raw_input" > "$classified_output"
}

if [ "$SELF_TEST" -eq 1 ]; then
    fixture_raw="$tmp_dir/fixture-raw.tsv"
    fixture_actual="$tmp_dir/fixture-actual.tsv"
    cat > "$fixture_raw" <<'EOF'
_tl_compiler_backend_compiler_backend_emit_function	101	8	10	T
_tl_compiler_backend_compiler_backend_parse_question_bang_u24	7	1	20	T
_tl_build_cli_core_stdlib_hashmap_generated_String_i64_get	53	4	30	T
tl_alloc	13	2	40	T
_tl_compiler_ir_types_clone_u24CompilerIrInstr	29	3	50	T
_tl___global_init_compiler_intern_compiler_intern_pool_slots	11	1	60	T
_tl___enum_obj_core_Option	5	1	70	T
_tl_no_such_module_generated_helper	3	1	80	T
EOF
    classify_symbols "$fixture_raw" "$fixture_actual"
    assert_fixture() {
        fixture_symbol=$1
        fixture_module=$2
        fixture_family=$3
        if ! awk -F '\t' -v symbol="$fixture_symbol" -v module="$fixture_module" -v family="$fixture_family" '
$1 == symbol && $3 == module && $4 == family { found = 1 }
END { exit(found ? 0 : 1) }
' "$fixture_actual"; then
            echo "self-test failed: $fixture_symbol expected module=$fixture_module family=$fixture_family" >&2
            sed 's/^/  /' "$fixture_actual" >&2
            exit 1
        fi
    }
    assert_fixture _tl_compiler_backend_compiler_backend_emit_function src/compiler_backend.tl ordinary
    assert_fixture _tl_compiler_backend_compiler_backend_parse_question_bang_u24 src/compiler_backend.tl ordinary
    assert_fixture _tl_build_cli_core_stdlib_hashmap_generated_String_i64_get src/build_cli_core.tl specialization
    assert_fixture tl_alloc runtime/entry runtime
    assert_fixture _tl_compiler_ir_types_clone_u24CompilerIrInstr src/compiler_ir_types.tl clone
    assert_fixture _tl___global_init_compiler_intern_compiler_intern_pool_slots src/compiler_intern.tl global-init
    assert_fixture _tl___enum_obj_core_Option generated/enum-objects enum-object
    assert_fixture _tl_no_such_module_generated_helper generated/type-lisp ordinary
    if ! awk -F '\t' '
$1 == "_tl_compiler_backend_compiler_backend_parse_question_bang_u24" &&
$2 == "compiler_backend_compiler_backend_parse?!$" { found = 1 }
END { exit(found ? 0 : 1) }
' "$fixture_actual"; then
        echo "self-test failed: escaped current symbol did not decode ?, !, and $" >&2
        exit 1
    fi
    fixture_sum=$(awk -F '\t' '{ total += $5 } END { print total + 0 }' "$fixture_actual")
    fixture_text=230
    fixture_remainder=$((fixture_text - fixture_sum))
    if [ "$fixture_sum" -ne 222 ] || [ "$fixture_remainder" -ne 8 ]; then
        echo "self-test failed: linked text reconciliation expected 222 + 8 = 230" >&2
        exit 1
    fi
    echo "[selfhost-size] self-test passed"
    exit 0
fi

WORKDIR=${TYPELISP_ASM_SIZE_OUT:-target/selfhost-build-asm-size}
ASM_PATH=$ASM_ARG
OBJECT_PATH=$OBJECT_ARG
BINARY_PATH=$BINARY_ARG
SOURCE=src/main.tl
COMPILE_ASM=0
if [ -z "$ASM_PATH" ] && [ -z "$OBJECT_PATH" ] && [ -z "$BINARY_PATH" ]; then
    COMPILE_ASM=1
    ASM_PATH="$WORKDIR/build.s"
    [ -n "$OPT_LEVEL" ] || OPT_LEVEL=2
fi

if [ -n "$ASM_PATH" ] && [ ! -f "$ASM_PATH" ] && [ "$COMPILE_ASM" -eq 0 ]; then
    echo "assembly file not found: $ASM_PATH" >&2
    exit 1
fi
if [ -n "$OBJECT_PATH" ] && [ ! -f "$OBJECT_PATH" ]; then
    echo "object file not found: $OBJECT_PATH" >&2
    exit 1
fi
if [ -n "$BINARY_PATH" ] && [ ! -f "$BINARY_PATH" ]; then
    echo "binary file not found: $BINARY_PATH" >&2
    exit 1
fi

COMPILER=
if [ "$COMPILE_ASM" -eq 1 ]; then
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
    [ -n "$PRODUCER" ] || PRODUCER=$COMPILER
    compile_stdout="$WORKDIR/compile.stdout"
    compile_stderr="$WORKDIR/compile.stderr"
    echo "[selfhost-size] compile $SOURCE -> $ASM_PATH (opt$OPT_LEVEL)" >&2
    if [ -n "$TARGET" ]; then
        target_args="--target $TARGET"
    else
        target_args=
    fi
    # target_args contains only a CLI option and its target-name value.
    # shellcheck disable=SC2086
    if ! "$COMPILER" compile "$SOURCE" -o "$ASM_PATH" \
        $target_args \
        --stdlib-root stdlib \
        --stdlib-root src \
        --opt-level "$OPT_LEVEL" \
        >"$compile_stdout" 2>"$compile_stderr"; then
        echo "[selfhost-size] compile failed" >&2
        sed 's/^/  /' "$compile_stdout" >&2 || true
        sed 's/^/  /' "$compile_stderr" >&2 || true
        exit 1
    fi
fi

if [ -n "$PRODUCER_BINARY" ]; then
    [ -f "$PRODUCER_BINARY" ] || {
        echo "producer binary not found: $PRODUCER_BINARY" >&2
        exit 1
    }
    producer_version=$("$PRODUCER_BINARY" --version 2>/dev/null | awk 'NR == 1 { print; exit }' || true)
    if command -v sha256sum >/dev/null 2>&1; then
        producer_sha256=$(sha256sum "$PRODUCER_BINARY" | awk '{ print $1 }')
    elif command -v shasum >/dev/null 2>&1; then
        producer_sha256=$(shasum -a 256 "$PRODUCER_BINARY" | awk '{ print $1 }')
    else
        producer_sha256=unavailable
    fi
    if [ -n "$producer_version" ]; then
        PRODUCER="$PRODUCER_BINARY sha256=$producer_sha256 ($producer_version)"
    else
        PRODUCER="$PRODUCER_BINARY sha256=$producer_sha256"
    fi
fi
[ -n "$PRODUCER" ] || PRODUCER="(not supplied)"
[ -n "$TARGET" ] || TARGET=unknown
[ -n "$OPT_LEVEL" ] || OPT_LEVEL=unknown
SOURCE_GIT_HASH=$(
    git rev-parse HEAD 2>/dev/null \
        || git.exe rev-parse HEAD 2>/dev/null \
        || printf unknown
)

sanitize_metadata() {
    printf '%s' "$1" | tr '\t\r\n' '   '
}
TARGET=$(sanitize_metadata "$TARGET")
OPT_LEVEL=$(sanitize_metadata "$OPT_LEVEL")
PRODUCER=$(sanitize_metadata "$PRODUCER")
SOURCE_GIT_HASH=$(sanitize_metadata "$SOURCE_GIT_HASH")

assembly_symbols_tsv="$tmp_dir/assembly-symbols.tsv"
assembly_modules_tsv="$tmp_dir/assembly-modules.tsv"
assembly_sections_tsv="$tmp_dir/assembly-sections.tsv"
assembly_total_bytes=
assembly_total_lines=
assembly_symbol_count=

if [ -n "$ASM_PATH" ]; then
    [ -s "$ASM_PATH" ] || {
        echo "assembly file is empty: $ASM_PATH" >&2
        exit 1
    }
    assembly_raw_tsv="$tmp_dir/assembly-raw.tsv"
    awk -v sections="$assembly_sections_tsv" -v symbols="$assembly_raw_tsv" '
function flush_symbol() {
    if (current_symbol != "" && symbol_bytes > 0) {
        print current_symbol "\t" symbol_bytes "\t" symbol_lines "\t0\tA" >> symbols
    }
    current_symbol = ""
    symbol_bytes = 0
    symbol_lines = 0
}
function section_directive(line, value) {
    if (line == ".text" || line == ".data" || line == ".bss") return line
    if (line ~ /^\.section[ \t]+/) {
        value = line
        sub(/^\.section[ \t]+/, "", value)
        sub(/[ \t,].*$/, "", value)
        return ".section " value
    }
    return ""
}
function text_section(section) {
    return section == ".text" || section ~ /^\.section \.text([.$]|$)/
}
{
    line = $0
    next_section = section_directive(line)
    if (next_section != "") {
        flush_symbol()
        current_section = next_section
    } else if (text_section(current_section) && line ~ /^\.globl[ \t]+/) {
        flush_symbol()
    } else if (text_section(current_section) && line ~ /^[A-Za-z_][A-Za-z0-9_.$@]*:$/) {
        flush_symbol()
        current_symbol = line
        sub(/:$/, "", current_symbol)
    }
    if (current_section == "") current_section = "(preamble)"
    line_bytes = length(line) + 1
    section_bytes[current_section] += line_bytes
    section_lines[current_section] += 1
    if (text_section(current_section) && current_symbol != "") {
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
    classify_symbols "$assembly_raw_tsv" "$assembly_symbols_tsv"
    awk -F '\t' 'BEGIN { OFS = "\t" }
{
    bytes[$3] += $5
    lines[$3] += $6
    symbols[$3] += 1
}
END {
    for (module in bytes) print module, bytes[module], lines[module], symbols[module]
}
' "$assembly_symbols_tsv" > "$assembly_modules_tsv"
    assembly_total_bytes=$(wc -c < "$ASM_PATH" | tr -d ' ')
    assembly_total_lines=$(wc -l < "$ASM_PATH" | tr -d ' ')
    assembly_symbol_count=$(wc -l < "$assembly_symbols_tsv" | tr -d ' ')
fi

run_size_tool() {
    size_input=$1
    size_output=$2
    for size_candidate in llvm-size size; do
        if command -v "$size_candidate" >/dev/null 2>&1 && \
            "$size_candidate" -A -d "$size_input" > "$size_output" 2>/dev/null; then
            printf '%s\n' "$size_candidate"
            return 0
        fi
    done
    return 1
}

text_bytes_from_size() {
    size_table=$1
    awk '
$1 ~ /^\.text($|[.$])/ && $2 ~ /^[0-9]+$/ { total += $2 }
END {
    if (total <= 0) exit 1
    print total
}
' "$size_table"
}

linked_symbols_tsv="$tmp_dir/linked-symbols.tsv"
linked_modules_tsv="$tmp_dir/linked-modules.tsv"
linked_families_tsv="$tmp_dir/linked-families.tsv"
object_text_bytes=
function_text_bytes=
text_remainder_bytes=
function_count=
module_count=
clone_function_count=
clone_text_bytes=
object_size_tool=
nm_tool=
symbol_size_mode=

if [ -n "$OBJECT_PATH" ]; then
    nm_raw="$tmp_dir/nm.raw"
    nm_error="$tmp_dir/nm.stderr"
    nm_ok=0
    for nm_candidate in llvm-nm nm; do
        command -v "$nm_candidate" >/dev/null 2>&1 || continue
        if "$nm_candidate" -S --size-sort --radix=d --format=posix "$OBJECT_PATH" > "$nm_raw" 2> "$nm_error"; then
            nm_tool=$nm_candidate
            nm_ok=1
            break
        fi
        if "$nm_candidate" -S --size-sort -t d -P "$OBJECT_PATH" > "$nm_raw" 2> "$nm_error"; then
            nm_tool=$nm_candidate
            nm_ok=1
            break
        fi
    done
    if [ "$nm_ok" -ne 1 ]; then
        echo "no llvm-nm/nm capable of reading sized symbols from: $OBJECT_PATH" >&2
        sed 's/^/  /' "$nm_error" >&2 || true
        exit 1
    fi
    object_size_table="$tmp_dir/object-size.txt"
    if ! object_size_tool=$(run_size_tool "$OBJECT_PATH" "$object_size_table"); then
        echo "no llvm-size/size capable of reading sections from: $OBJECT_PATH" >&2
        exit 1
    fi
    if ! object_text_bytes=$(text_bytes_from_size "$object_size_table"); then
        echo "$object_size_tool reported no non-empty .text sections for: $OBJECT_PATH" >&2
        sed 's/^/  /' "$object_size_table" >&2 || true
        exit 1
    fi

    linked_raw_tsv="$tmp_dir/linked-raw.tsv"
    awk 'BEGIN { OFS = "\t" }
$2 ~ /^[TtWw]$/ && $4 ~ /^[0-9]+$/ && $4 + 0 > 0 {
    print $1, $4, 0, $3, $2
}
' "$nm_raw" > "$linked_raw_tsv"
    symbol_size_mode=symbol-size
    if [ ! -s "$linked_raw_tsv" ]; then
        # COFF does not carry ELF-style st_size values. LLVM still exposes
        # every text symbol's section-relative address, so use the span to the
        # next distinct address (and the final span to .text end). This counts
        # inter-function alignment with the preceding function and preserves
        # exact reconciliation with the linked COFF section.
        address_symbols_tsv="$tmp_dir/address-symbols.tsv"
        awk 'BEGIN { OFS = "\t" }
$2 ~ /^[TtWw]$/ && $3 ~ /^[0-9]+$/ { print $3, $1, $2 }
' "$nm_raw" \
            | LC_ALL=C sort -t "$tab" -k1,1n -k2,2 \
            > "$address_symbols_tsv"
        [ -s "$address_symbols_tsv" ] || {
            echo "$nm_tool returned no text function addresses for: $OBJECT_PATH" >&2
            exit 1
        }
        awk -F '\t' -v text_bytes="$object_text_bytes" 'BEGIN { OFS = "\t" }
function emit_span(next_address, span) {
    span = next_address - previous_address
    if (span > 0) print previous_symbol, span, 0, previous_address, previous_type
}
{
    address = $1 + 0
    if (have_previous && address != previous_address) emit_span(address)
    if (!have_previous || address != previous_address) {
        previous_address = address
        previous_symbol = $2
        previous_type = $3
        have_previous = 1
    }
}
END {
    if (!have_previous || previous_address > text_bytes) exit 1
    emit_span(text_bytes)
}
' "$address_symbols_tsv" > "$linked_raw_tsv"
        [ -s "$linked_raw_tsv" ] || {
            echo "could not derive function address spans within .text for: $OBJECT_PATH" >&2
            exit 1
        }
        symbol_size_mode=address-span
    fi
    classify_symbols "$linked_raw_tsv" "$linked_symbols_tsv"
    function_text_bytes=$(awk -F '\t' '{ total += $5 } END { print total + 0 }' "$linked_symbols_tsv")
    function_count=$(wc -l < "$linked_symbols_tsv" | tr -d ' ')
    if [ "$function_text_bytes" -gt "$object_text_bytes" ]; then
        echo "sized text symbols exceed object .text: $function_text_bytes > $object_text_bytes" >&2
        exit 1
    fi
    text_remainder_bytes=$((object_text_bytes - function_text_bytes))
    awk -F '\t' 'BEGIN { OFS = "\t" }
{
    bytes[$3] += $5
    functions[$3] += 1
}
END {
    for (module in bytes) print module, bytes[module], functions[module]
}
' "$linked_symbols_tsv" > "$linked_modules_tsv"
    awk -F '\t' 'BEGIN { OFS = "\t" }
{
    bytes[$4] += $5
    functions[$4] += 1
}
END {
    for (family in bytes) print family, bytes[family], functions[family]
}
' "$linked_symbols_tsv" > "$linked_families_tsv"
    module_count=$(wc -l < "$linked_modules_tsv" | tr -d ' ')
    clone_totals=$(awk -F '\t' '$1 == "clone" { print $2 "\t" $3 }' "$linked_families_tsv")
    if [ -n "$clone_totals" ]; then
        clone_text_bytes=${clone_totals%%"$tab"*}
        clone_function_count=${clone_totals#*"$tab"}
    else
        clone_text_bytes=0
        clone_function_count=0
    fi
fi

binary_file_bytes=
binary_text_bytes=
binary_size_tool=
binary_object_text_delta_bytes=
if [ -n "$BINARY_PATH" ]; then
    binary_file_bytes=$(wc -c < "$BINARY_PATH" | tr -d ' ')
    binary_size_table="$tmp_dir/binary-size.txt"
    if binary_size_tool=$(run_size_tool "$BINARY_PATH" "$binary_size_table"); then
        binary_text_bytes=$(text_bytes_from_size "$binary_size_table" || true)
    fi
    [ -n "$binary_text_bytes" ] || binary_text_bytes=unavailable
    [ -n "$binary_size_tool" ] || binary_size_tool=unavailable
    if [ -n "$OBJECT_PATH" ] && [ "$binary_text_bytes" != unavailable ]; then
        binary_object_text_delta_bytes=$((binary_text_bytes - object_text_bytes))
    fi
fi

echo "selfhost_build_size_attribution"
printf 'source\t%s\n' "$SOURCE"
printf 'source_git_hash\t%s\n' "$SOURCE_GIT_HASH"
printf 'target\t%s\n' "$TARGET"
printf 'opt_level\t%s\n' "$OPT_LEVEL"
printf 'producer\t%s\n' "$PRODUCER"
if [ -n "$ASM_PATH" ]; then
    printf 'assembly\t%s\n' "$ASM_PATH"
    printf 'assembly_bytes\t%s\n' "$assembly_total_bytes"
    printf 'assembly_lines\t%s\n' "$assembly_total_lines"
    printf 'assembly_text_symbols\t%s\n' "$assembly_symbol_count"
fi
if [ -n "$OBJECT_PATH" ]; then
    printf 'object\t%s\n' "$OBJECT_PATH"
    printf 'symbol_reader\t%s\n' "$nm_tool"
    printf 'symbol_size_mode\t%s\n' "$symbol_size_mode"
    printf 'section_reader\t%s\n' "$object_size_tool"
    printf 'function_count\t%s\n' "$function_count"
    printf 'module_count\t%s\n' "$module_count"
    printf 'clone_function_count\t%s\n' "$clone_function_count"
    printf 'object_text_bytes\t%s\n' "$object_text_bytes"
    printf 'function_text_bytes\t%s\n' "$function_text_bytes"
    printf 'clone_text_bytes\t%s\n' "$clone_text_bytes"
    printf 'text_remainder_bytes\t%s\n' "$text_remainder_bytes"
fi
if [ -n "$BINARY_PATH" ]; then
    printf 'binary\t%s\n' "$BINARY_PATH"
    printf 'binary_file_bytes\t%s\n' "$binary_file_bytes"
    printf 'binary_text_bytes\t%s\n' "$binary_text_bytes"
    if [ -n "$binary_object_text_delta_bytes" ]; then
        printf 'binary_vs_object_text_delta_bytes\t%s\n' "$binary_object_text_delta_bytes"
    fi
    printf 'binary_section_reader\t%s\n' "$binary_size_tool"
fi

if [ -n "$OBJECT_PATH" ]; then
    echo
    echo "linked_module_totals"
    printf 'bytes\tfunctions\tmodule\n'
    LC_ALL=C sort -t "$tab" -k2,2nr -k1,1 "$linked_modules_tsv" | head -n "$TOP_N" | awk -F '\t' '{ printf "%s\t%s\t%s\n", $2, $3, $1 }'

    echo
    echo "linked_family_totals"
    printf 'bytes\tfunctions\tfamily\n'
    LC_ALL=C sort -t "$tab" -k2,2nr -k1,1 "$linked_families_tsv" | awk -F '\t' '{ printf "%s\t%s\t%s\n", $2, $3, $1 }'

    echo
    echo "top_linked_text_symbols"
    printf 'bytes\tfamily\tmodule\tsymbol\n'
    LC_ALL=C sort -t "$tab" -k5,5nr -k1,1 "$linked_symbols_tsv" | head -n "$TOP_N" | awk -F '\t' '{ printf "%s\t%s\t%s\t%s\n", $5, $4, $3, $1 }'

    echo
    echo "top_generated_clone_helpers"
    printf 'bytes\tmodule\tsymbol\n'
    awk -F '\t' '$4 == "clone" { print }' "$linked_symbols_tsv" | LC_ALL=C sort -t "$tab" -k5,5nr -k1,1 | head -n "$TOP_N" | awk -F '\t' '{ printf "%s\t%s\t%s\n", $5, $3, $1 }'
fi

if [ -n "$ASM_PATH" ]; then
    echo
    echo "assembly_section_totals"
    printf 'section\tbytes\tlines\n'
    LC_ALL=C sort -t "$tab" -k1,1 "$assembly_sections_tsv"

    echo
    echo "top_assembly_text_modules"
    printf 'bytes\tlines\tsymbols\tmodule\n'
    LC_ALL=C sort -t "$tab" -k2,2nr -k1,1 "$assembly_modules_tsv" | head -n "$TOP_N" | awk -F '\t' '{ printf "%s\t%s\t%s\t%s\n", $2, $3, $4, $1 }'
fi

if [ -n "$TSV_OUT" ]; then
    mkdir -p "$(dirname -- "$TSV_OUT")"
    {
        printf 'record\ttarget\topt_level\tproducer\tsource_git_hash\tmodule\tfamily\tsymbol\tbytes\tcount\n'
        if [ -n "$OBJECT_PATH" ]; then
            printf 'summary\t%s\t%s\t%s\t%s\t\t\tfunction_count\t\t%s\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$function_count"
            printf 'summary\t%s\t%s\t%s\t%s\t\t\tmodule_count\t\t%s\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$module_count"
            printf 'summary\t%s\t%s\t%s\t%s\t\tclone\tclone_function_count\t\t%s\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$clone_function_count"
            printf 'summary\t%s\t%s\t%s\t%s\t\t\tobject_text_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$object_text_bytes"
            printf 'summary\t%s\t%s\t%s\t%s\t\t\tfunction_text_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$function_text_bytes"
            printf 'summary\t%s\t%s\t%s\t%s\t\tclone\tclone_text_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$clone_text_bytes"
            printf 'summary\t%s\t%s\t%s\t%s\t\t\ttext_remainder_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$text_remainder_bytes"
            LC_ALL=C sort -t "$tab" -k1,1 "$linked_modules_tsv" | awk -F '\t' -v target="$TARGET" -v opt="$OPT_LEVEL" -v producer="$PRODUCER" -v source_hash="$SOURCE_GIT_HASH" 'BEGIN { OFS = "\t" } { print "module", target, opt, producer, source_hash, $1, "", "", $2, $3 }'
            LC_ALL=C sort -t "$tab" -k1,1 "$linked_families_tsv" | awk -F '\t' -v target="$TARGET" -v opt="$OPT_LEVEL" -v producer="$PRODUCER" -v source_hash="$SOURCE_GIT_HASH" 'BEGIN { OFS = "\t" } { print "family", target, opt, producer, source_hash, "", $1, "", $2, $3 }'
            LC_ALL=C sort -t "$tab" -k1,1 "$linked_symbols_tsv" | awk -F '\t' -v target="$TARGET" -v opt="$OPT_LEVEL" -v producer="$PRODUCER" -v source_hash="$SOURCE_GIT_HASH" 'BEGIN { OFS = "\t" } { print "symbol", target, opt, producer, source_hash, $3, $4, $1, $5, 1 }'
        fi
        if [ -n "$ASM_PATH" ]; then
            printf 'summary\t%s\t%s\t%s\t%s\t\t\tassembly_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$assembly_total_bytes"
            printf 'summary\t%s\t%s\t%s\t%s\t\t\tassembly_lines\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$assembly_total_lines"
        fi
        if [ -n "$BINARY_PATH" ]; then
            printf 'summary\t%s\t%s\t%s\t%s\t\t\tbinary_file_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$binary_file_bytes"
            if [ "$binary_text_bytes" != unavailable ]; then
                printf 'summary\t%s\t%s\t%s\t%s\t\t\tbinary_text_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$binary_text_bytes"
            fi
            if [ -n "$binary_object_text_delta_bytes" ]; then
                printf 'summary\t%s\t%s\t%s\t%s\t\t\tbinary_vs_object_text_delta_bytes\t%s\t\n' "$TARGET" "$OPT_LEVEL" "$PRODUCER" "$SOURCE_GIT_HASH" "$binary_object_text_delta_bytes"
            fi
        fi
    } > "$TSV_OUT"
fi
