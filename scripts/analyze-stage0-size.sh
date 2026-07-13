#!/usr/bin/env sh
set -eu

# analyze-stage0-size.sh - linked stage0 binary size and embedded stdlib report.
#
# This reports file bytes, linked section raw sizes, and compressed/expanded
# embedded stdlib payload bytes. It is a measurement helper, not a size budget
# gate.

usage() {
    cat >&2 <<'EOF'
usage: scripts/analyze-stage0-size.sh [options] <stage0-binary>

Options:
  --embedded-stdlib <file>  generated payload source to count
                            (default: src/compiler_embedded_stdlib_payload.tl)

The section report uses llvm-readobj when available, then readelf, then objdump.
It reports only the supplied binary format; Linux and Windows binaries can be
measured independently on hosts with a compatible section reader.
EOF
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

EMBEDDED_STDLIB=src/compiler_embedded_stdlib_payload.tl
BINARY=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --embedded-stdlib)
            shift
            [ "$#" -gt 0 ] || {
                usage
                exit 2
            }
            EMBEDDED_STDLIB=$1
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
            if [ -n "$BINARY" ]; then
                usage
                exit 2
            fi
            BINARY=$1
            ;;
    esac
    shift
done

[ -n "$BINARY" ] || {
    usage
    exit 2
}
[ -f "$BINARY" ] || {
    echo "stage0 binary not found: $BINARY" >&2
    exit 1
}
[ -s "$BINARY" ] || {
    echo "stage0 binary is empty: $BINARY" >&2
    exit 1
}
[ -f "$EMBEDDED_STDLIB" ] || {
    echo "embedded stdlib manifest not found: $EMBEDDED_STDLIB" >&2
    exit 1
}

SECTION_TOOL_CANDIDATES=
if command -v llvm-readobj >/dev/null 2>&1; then
    SECTION_TOOL_CANDIDATES="${SECTION_TOOL_CANDIDATES} llvm-readobj"
fi
if command -v readelf >/dev/null 2>&1; then
    SECTION_TOOL_CANDIDATES="${SECTION_TOOL_CANDIDATES} readelf"
fi
if command -v objdump >/dev/null 2>&1; then
    SECTION_TOOL_CANDIDATES="${SECTION_TOOL_CANDIDATES} objdump"
fi
if [ -z "$SECTION_TOOL_CANDIDATES" ]; then
    echo "no section reader found: install llvm-readobj, readelf, or objdump" >&2
    exit 1
fi

tmp_root=${TMPDIR:-${TEMP:-/tmp}}
tmp_dir=$(mktemp -d "$tmp_root/tl-stage0-size.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

sections_tsv="$tmp_dir/sections.tsv"
payload_paths="$tmp_dir/payload-paths.txt"
payloads_tsv="$tmp_dir/payloads.tsv"
tab=$(printf '\t')
: > "$payloads_tsv"

parse_llvm_readobj_sections() {
    "$SECTION_TOOL" --sections "$BINARY" | awk -v out="$sections_tsv" '
function trim(value) {
    sub(/^[ \t]+/, "", value)
    sub(/[ \t]+$/, "", value)
    return value
}

function decimal(value, s, i, c, digit, n) {
    value = trim(value)
    if (value ~ /^0[xX]/) {
        s = substr(value, 3)
        n = 0
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c >= "0" && c <= "9") {
                digit = c + 0
            } else if (c >= "a" && c <= "f") {
                digit = index("abcdef", c) + 9
            } else if (c >= "A" && c <= "F") {
                digit = index("ABCDEF", c) + 9
            } else {
                digit = 0
            }
            n = (n * 16) + digit
        }
        return n
    }
    return value + 0
}

function value_after_colon(line, value) {
    value = line
    sub(/^[^:]+:[ \t]*/, "", value)
    return trim(value)
}

function flush_section() {
    if (!in_section || name == "") {
        return
    }
    if (raw == "" && size != "") {
        raw = size
        if (type == "SHT_NOBITS") {
            raw = 0
        }
    }
    if (virtual == "" && size != "") {
        virtual = size
    }
    if (raw == "") {
        return
    }
    order += 1
    print order "\t" name "\t" raw "\t" (virtual == "" ? raw : virtual) >> out
}

/^Format:/ {
    format = value_after_colon($0)
}

/^[ \t]*Section[ \t]*\{/ {
    name = ""
    type = ""
    raw = ""
    virtual = ""
    size = ""
    in_section = 1
    next
}

in_section && /^[ \t]*Name:/ {
    name = value_after_colon($0)
    sub(/[ \t]+\(.*$/, "", name)
    next
}

in_section && /^[ \t]*Type:/ {
    type = value_after_colon($0)
    sub(/[ \t(].*$/, "", type)
    next
}

in_section && /^[ \t]*RawDataSize:/ {
    raw = decimal(value_after_colon($0))
    next
}

in_section && /^[ \t]*VirtualSize:/ {
    virtual = decimal(value_after_colon($0))
    next
}

in_section && /^[ \t]*Size:/ {
    size = decimal(value_after_colon($0))
    next
}

in_section && /^[ \t]*\}/ {
    flush_section()
    in_section = 0
    next
}

END {
    if (format != "") {
        print format > (out ".format")
    }
}
'
}

parse_readelf_sections() {
    "$SECTION_TOOL" -SW "$BINARY" | awk -v out="$sections_tsv" '
function decimal_hex(value, s, i, c, digit, n) {
    s = value
    sub(/^0[xX]/, "", s)
    n = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "0" && c <= "9") {
            digit = c + 0
        } else if (c >= "a" && c <= "f") {
            digit = index("abcdef", c) + 9
        } else if (c >= "A" && c <= "F") {
            digit = index("ABCDEF", c) + 9
        } else {
            digit = 0
        }
        n = (n * 16) + digit
    }
    return n
}

/^[ \t]*\[/ {
    if ($1 == "[") {
        name = $3
        type = $4
        size = decimal_hex($7)
    } else {
        name = $2
        type = $3
        size = decimal_hex($6)
    }
    if (name == "NULL" || name == "Name" || type == "Type") {
        next
    }
    order += 1
    raw = size
    if (type == "NOBITS") {
        raw = 0
    }
    print order "\t" name "\t" raw "\t" size >> out
}
'
    printf 'ELF (readelf)\n' > "$sections_tsv.format"
}

parse_objdump_sections() {
    "$SECTION_TOOL" -h "$BINARY" | awk -v out="$sections_tsv" '
function decimal_hex(value, s, i, c, digit, n) {
    s = value
    sub(/^0[xX]/, "", s)
    n = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "0" && c <= "9") {
            digit = c + 0
        } else if (c >= "a" && c <= "f") {
            digit = index("abcdef", c) + 9
        } else if (c >= "A" && c <= "F") {
            digit = index("ABCDEF", c) + 9
        } else {
            digit = 0
        }
        n = (n * 16) + digit
    }
    return n
}

/^[ \t]*[0-9]+[ \t]+/ {
    order += 1
    size = decimal_hex($3)
    print order "\t" $2 "\t" size "\t" size >> out
}
'
    printf 'object file (objdump)\n' > "$sections_tsv.format"
}

parse_sections_with_tool() {
    SECTION_TOOL=$1
    : > "$sections_tsv"
    rm -f "$sections_tsv.format"
    case "$SECTION_TOOL" in
        llvm-readobj) parse_llvm_readobj_sections ;;
        readelf) parse_readelf_sections ;;
        objdump) parse_objdump_sections ;;
    esac
}

SECTION_TOOL=
for candidate in $SECTION_TOOL_CANDIDATES; do
    err_file="$tmp_dir/sections-$candidate.err"
    if parse_sections_with_tool "$candidate" 2> "$err_file" && [ -s "$sections_tsv" ]; then
        SECTION_TOOL=$candidate
        break
    fi
done

[ -n "$SECTION_TOOL" ] || {
    echo "could not parse any sections from $BINARY with available section readers" >&2
    for candidate in $SECTION_TOOL_CANDIDATES; do
        err_file="$tmp_dir/sections-$candidate.err"
        if [ -s "$err_file" ]; then
            sed "s/^/  $candidate: /" "$err_file" >&2
        fi
    done
    exit 1
}

if grep -F '(include-str ' "$EMBEDDED_STDLIB" >/dev/null 2>&1; then
    awk '
    match($0, /\(include-str[ \t]+[^ \t]+[ \t]+"[^"]+"/) {
        path = $0
        sub(/^[^"]*"/, "", path)
        sub(/".*$/, "", path)
        print path
    }
    ' "$EMBEDDED_STDLIB" | sort > "$payload_paths"
    encoded_payload_bytes=0
    compressed_payload_bytes=0
else
    tr -d '\r' < tools/embedded-stdlib-payload/modules.txt |
        sed '/^[[:space:]]*$/d; s#^#stdlib/#' |
        sort > "$payload_paths"
    encoded_payload_bytes=$(awk '
    /^[ \t]+"[A-Za-z0-9+\/=]+"[ \t]*$/ {
        line = $0
        sub(/^[ \t]+"/, "", line)
        sub(/"[ \t]*$/, "", line)
        total += length(line)
    }
    END { printf "%d\n", total }
    ' "$EMBEDDED_STDLIB")
    compressed_payload_bytes=$(awk '
    /\(CompilerEmbeddedStdlibPayloadSome[ \t]*$/ { state = 1; next }
    state == 1 && $0 ~ /^[ \t]+[0-9]+[ \t]*$/ { state = 2; next }
    state == 2 && $0 ~ /^[ \t]+[0-9]+[ \t]*$/ {
        value = $0
        gsub(/[ \t]/, "", value)
        total += value
        state = 0
    }
    END { printf "%d\n", total }
    ' "$EMBEDDED_STDLIB")
fi

while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$path" ] || {
        echo "embedded stdlib payload not found: $path" >&2
        exit 1
    }
    bytes=$(wc -c < "$path" | tr -d ' ')
    case "$path" in
        stdlib/tests/*) bucket=stdlib_tests ;;
        stdlib/*.tl) bucket=stdlib_top_level_modules ;;
        stdlib/*) bucket=stdlib_other ;;
        *) bucket=other ;;
    esac
    printf '%s\t%s\t%s\n' "$bucket" "$bytes" "$path" >> "$payloads_tsv"
done < "$payload_paths"

format=$(cat "$sections_tsv.format" 2>/dev/null || printf 'unknown')
binary_bytes=$(wc -c < "$BINARY" | tr -d ' ')
section_raw_total=$(awk -F '\t' '{ total += $3 } END { printf "%d\n", total }' "$sections_tsv")
section_virtual_total=$(awk -F '\t' '{ total += $4 } END { printf "%d\n", total }' "$sections_tsv")
payload_total=$(awk -F '\t' '{ total += $2 } END { printf "%d\n", total }' "$payloads_tsv" 2>/dev/null || printf '0')
payload_files=$(wc -l < "$payloads_tsv" 2>/dev/null | tr -d ' ' || printf '0')

echo "stage0_binary_size"
printf 'binary\t%s\n' "$BINARY"
printf 'format\t%s\n' "$format"
printf 'section_tool\t%s\n' "$SECTION_TOOL"
printf 'total_bytes\t%s\n' "$binary_bytes"
printf 'section_raw_total_bytes\t%s\n' "$section_raw_total"
printf 'section_virtual_total_bytes\t%s\n' "$section_virtual_total"

echo
echo "section_raw_sizes"
printf 'section\traw_bytes\tvirtual_bytes\n'
sort -n -t "$tab" -k1,1 "$sections_tsv" \
    | awk -F '\t' '{ printf "%s\t%s\t%s\n", $2, $3, $4 }'

echo
echo "embedded_stdlib_payloads"
printf 'source_manifest\t%s\n' "$EMBEDDED_STDLIB"
printf 'total_files\t%s\n' "$payload_files"
printf 'expanded_source_bytes\t%s\n' "$payload_total"
printf 'compressed_token_bytes\t%s\n' "$compressed_payload_bytes"
printf 'encoded_payload_bytes\t%s\n' "$encoded_payload_bytes"
printf 'bucket\tfiles\tbytes\n'
for bucket in stdlib_top_level_modules stdlib_tests stdlib_other other; do
    awk -F '\t' -v bucket="$bucket" '
$1 == bucket {
    files += 1
    bytes += $2
}
END {
    printf "%s\t%d\t%d\n", bucket, files, bytes
}
' "$payloads_tsv"
done

echo
echo "embedded_stdlib_files"
printf 'bytes\tbucket\tpath\n'
sort -t "$tab" -k3,3 "$payloads_tsv" \
    | awk -F '\t' '{ printf "%s\t%s\t%s\n", $2, $1, $3 }'
