#!/usr/bin/env sh
set -eu

# analyze-stage0-size.sh - linked stage0 binary size and embedded stdlib report.
#
# This reports file bytes, linked section raw sizes, and compressed/expanded
# compiler-owned payload bytes. It is a measurement helper, not a size budget
# gate.

usage() {
    cat >&2 <<'EOF'
usage: scripts/analyze-stage0-size.sh [options] <stage0-binary>

Options:
  --embedded-stdlib <file>  payload build-input declaration file to count
                            (default: the embedded stdlib payload module)
  --compiler-sources <files>  other compiler source files to inventory
                              (default: all top-level src/*.tl modules)

The section report uses llvm-readobj when available, then readelf, then objdump.
It reports only the supplied binary format; Linux and Windows binaries can be
measured independently on hosts with a compatible section reader.
EOF
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Every compiler-owned compressed stream in the binary must be accounted for
# here or the stream counts below reject the report. Source fallback modules use
# independent LZSS frames; the generated TLCI image uses one TLCH envelope.
EMBEDDED_STDLIB="src/compiler_embedded_stdlib_payload.tl src/compiler_embedded_stdlib_tlci_payload.tl"
COMPILER_SOURCES="src/*.tl"
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
        --compiler-sources)
            shift
            [ "$#" -gt 0 ] || { usage; exit 2; }
            COMPILER_SOURCES=$1
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
for embedded_file in $EMBEDDED_STDLIB; do
    [ -f "$embedded_file" ] || {
        echo "embedded stdlib build-input declarations not found: $embedded_file" >&2
        exit 1
    }
done

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
lzss_declarations="$tmp_dir/lzss-declarations.tsv"
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

awk '
function emit_input() {
    path = declaration
    sub(/^[^"]*"/, "", path)
    sub(/".*$/, "", path)
    if (path ~ /^\.\.\/stdlib\//) {
        sub(/^\.\.\/stdlib\//, "", path)
        print "stdlib/" path
    } else {
        directory = declaration_file
        sub(/[^\/]*$/, "", directory)
        sub(/\.tlch$/, "", path)
        print directory path
    }
    declaration = ""
    collecting = 0
}
/^\(include-str-lzss([ \t]|$)|^\(include-bin([ \t]|$)/ {
    declaration = $0
    declaration_file = FILENAME
    collecting = 1
    if ($0 ~ /\)[ \t]*$/) {
        emit_input()
    }
    next
}
collecting {
    declaration = declaration " " $0
    if ($0 ~ /\)[ \t]*$/) {
        emit_input()
    }
}
' $EMBEDDED_STDLIB | sort > "$payload_paths"

[ -s "$payload_paths" ] || {
    echo "embedded stdlib build-input declaration list is empty" >&2
    exit 1
}
expected_payload_streams=$(wc -l < "$payload_paths" | tr -d ' ')
expected_tlch_streams=$(awk '/^\(include-bin([ \t]|$)/ { count += 1 } END { print count + 0 }' $EMBEDDED_STDLIB)

# Inventory the source declarations, independently of binary observations.
# Scanning every production compiler module also makes an unaccounted new
# declaration fail closed, rather than silently ignoring a non-stdlib stream.
awk -v manifests="$EMBEDDED_STDLIB" '
BEGIN {
    n = split(manifests, files, " ")
    for (i = 1; i <= n; i++) manifest[files[i]] = 1
}
FNR == 1 {
    if (collecting) { print "unfinished LZSS declaration in " previous_file > "/dev/stderr"; exit 1 }
    previous_file = FILENAME
    skip = seen[FILENAME]++
}
skip { next }
function emit_input() {
    path = declaration
    sub(/^[^"]*"/, "", path)
    sub(/".*$/, "", path)
    if (path ~ /^\.\.\/stdlib\//) {
        sub(/^\.\.\/stdlib\//, "", path)
        path = "stdlib/" path
    } else {
        directory = FILENAME
        sub(/[^\/]*$/, "", directory)
        path = directory path
    }
    category = (FILENAME in manifest ? "embedded_stdlib_manifest" : "other_compiler_owned")
    print category "\t" FILENAME "\t" path
    collecting = 0
}
/^\(include-str-lzss([ \t]|$)/ { declaration = $0; collecting = 1; if ($0 ~ /\)[ \t]*$/) emit_input(); next }
collecting { declaration = declaration " " $0; if ($0 ~ /\)[ \t]*$/) emit_input() }
END { if (collecting) { print "unfinished LZSS declaration in " FILENAME > "/dev/stderr"; exit 1 } }
' $EMBEDDED_STDLIB $COMPILER_SOURCES > "$lzss_declarations"
sort "$lzss_declarations" -o "$lzss_declarations"
expected_lzss_streams=$(wc -l < "$lzss_declarations" | tr -d ' ')
[ "$expected_lzss_streams" -gt 0 ] || {
    echo "compiler-owned LZSS declaration inventory is empty" >&2
    exit 1
}
manifest_lzss_streams=$(awk -F '\t' '$1 == "embedded_stdlib_manifest" { n++ } END { print n + 0 }' "$lzss_declarations")
other_lzss_streams=$(awk -F '\t' '$1 == "other_compiler_owned" { n++ } END { print n + 0 }' "$lzss_declarations")
awk -F '\t' '$1 == "other_compiler_owned" { print $3 }' "$lzss_declarations" >> "$payload_paths"
expected_payload_streams=$((expected_payload_streams + other_lzss_streams))

# Recover each bounded static LZSS stream directly from the linked binary;
# there is no base64/generated source to read instead.
. "$ROOT/scripts/lib-stage0-lzss.sh"
lzss_counts=$(scan_stage0_lzss "$BINARY") || exit 1
set -- $lzss_counts
payload_streams=$1
compressed_payload_bytes=$2
static_payload_bytes=$3
lzss_v1_streams=$4
lzss_v2_streams=$5
lzss_raw_bytes=$6
encoded_payload_bytes=0
[ "$payload_streams" -eq "$expected_lzss_streams" ] || {
    echo "expected $expected_lzss_streams compiler-owned LZSS payloads from source declarations ($manifest_lzss_streams embedded stdlib, $other_lzss_streams other), found $payload_streams" >&2
    echo "binary and source declaration sets must match; use the source checkout that built the binary" >&2
    exit 1
}

# Recover the TLCI-only TLCH envelope. Its fixed header contains little-endian
# raw and meaningful-bit lengths followed by 4,369 code-length bytes.
binary_scan_bytes=$(wc -c < "$BINARY" | tr -d ' ')
set -- $(od -An -v -tu1 "$BINARY" | awk -v binary_size="$binary_scan_bytes" '
BEGIN {
    split("95 95 116 121 112 101 108 105 115 112 95 101 109 98 101 100 100 101 100 95 115 116 100 108 105 98 95 116 108 99 104 95 118 49 95 95", prefix)
    prefix_len = 36
    mode = "scan"
    prefix_index = 0
}
function reset_scan() {
    mode = "scan"
    prefix_index = 0
}
function finish_payload() {
    payload_count += 1
    raw_total += raw_len
    bitstream_total += bit_bytes
    static_total += prefix_len + 16 + 4369 + bit_bytes
    reset_scan()
}
{
    for (field = 1; field <= NF; field += 1) {
        byte = $field + 0
        if (mode == "scan") {
            if (byte == prefix[prefix_index + 1]) {
                prefix_index += 1
            } else if (byte == prefix[1]) {
                prefix_index = 1
            } else {
                prefix_index = 0
            }
            if (prefix_index == prefix_len) {
                mode = "raw"
                header_index = 0
                raw_len = 0
                bit_len = 0
            }
        } else if (mode == "raw") {
            raw_len += byte * (2 ^ (8 * header_index))
            header_index += 1
            if (header_index == 8) {
                mode = "bits"
                header_index = 0
            }
        } else if (mode == "bits") {
            bit_len += byte * (2 ^ (8 * header_index))
            header_index += 1
            if (header_index == 8) {
                bit_bytes = int(bit_len / 8)
                if (bit_len % 8 != 0) bit_bytes += 1
                remaining = 4369 + bit_bytes
                if (raw_len <= 0 || raw_len > 268435456 || bit_len <= 0 ||
                    remaining > binary_size) {
                    reset_scan()
                } else if (remaining == 0) {
                    finish_payload()
                } else {
                    mode = "body"
                }
            }
        } else if (mode == "body") {
            remaining -= 1
            if (remaining == 0) finish_payload()
        }
    }
}
END { printf "%d %.0f %.0f %.0f\n", payload_count, raw_total, bitstream_total, static_total }
')
tlch_payload_streams=$1
tlch_raw_bytes=$2
tlch_bitstream_bytes=$3
tlch_static_bytes=$4
[ "$tlch_payload_streams" -eq "$expected_tlch_streams" ] || {
    echo "expected $expected_tlch_streams embedded stdlib TLCH payloads in binary, found $tlch_payload_streams" >&2
    exit 1
}
static_payload_bytes=$((static_payload_bytes + tlch_static_bytes))

[ $((expected_lzss_streams + expected_tlch_streams)) -eq "$expected_payload_streams" ] || {
    echo "embedded stdlib payload declaration accounting mismatch" >&2
    exit 1
}

while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -f "$path" ]; then
        # Generated build inputs live under target/ and are absent from a fresh
        # checkout, so measuring a downloaded binary must not fail on them. The
        # stream is still counted above; only its expanded size is unknown.
        case "$path" in
            target/* | */target/*)
                printf '%s\t%s\t%s\n' generated_unavailable 0 "$path" \
                    >> "$payloads_tsv"
                continue
                ;;
        esac
        echo "embedded stdlib payload not found: $path" >&2
        exit 1
    fi
    bytes=$(wc -c < "$path" | tr -d ' ')
    case "$path" in
        stdlib/tests/*) bucket=stdlib_tests ;;
        stdlib/*.tl) bucket=stdlib_top_level_modules ;;
        stdlib/*) bucket=stdlib_other ;;
        target/* | */target/*) bucket=generated_images ;;
        *) bucket=other ;;
    esac
    if awk -F '\t' -v path="$path" '$1 == "other_compiler_owned" && $3 == path { found = 1 } END { exit !found }' "$lzss_declarations"; then
        bucket=other_compiler_owned
    fi
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
echo "all_compiler_owned_payloads"
printf 'source_manifest\t%s\n' "$EMBEDDED_STDLIB"
printf 'compiler_source_inventory\t%s\n' "$COMPILER_SOURCES"
printf 'embedded_stdlib_manifest_lzss_declarations\t%s\n' "$manifest_lzss_streams"
printf 'other_compiler_owned_lzss_declarations\t%s\n' "$other_lzss_streams"
printf 'total_files\t%s\n' "$payload_files"
printf 'expanded_source_bytes\t%s\n' "$payload_total"
printf 'lzss_payload_streams\t%s\n' "$payload_streams"
printf 'lzss_v1_streams\t%s\n' "$lzss_v1_streams"
printf 'lzss_v2_streams\t%s\n' "$lzss_v2_streams"
printf 'lzss_raw_bytes\t%s\n' "$lzss_raw_bytes"
printf 'compressed_token_bytes\t%s\n' "$compressed_payload_bytes"
printf 'tlci_envelope_raw_bytes\t%s\n' "$tlch_raw_bytes"
printf 'tlci_envelope_bitstream_bytes\t%s\n' "$tlch_bitstream_bytes"
printf 'tlci_envelope_static_bytes\t%s\n' "$tlch_static_bytes"
printf 'static_payload_bytes\t%s\n' "$static_payload_bytes"
printf 'encoded_payload_bytes\t%s\n' "$encoded_payload_bytes"
printf 'bucket\tfiles\tbytes\n'
for bucket in stdlib_top_level_modules stdlib_tests stdlib_other \
    generated_images generated_unavailable other other_compiler_owned; do
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
echo "compiler_owned_lzss_declarations"
printf 'category\tdeclaration_source\tinput_path\n'
cat "$lzss_declarations"

echo
echo "compiler_owned_payload_files"
printf 'bytes\tbucket\tpath\n'
sort -t "$tab" -k3,3 "$payloads_tsv" \
    | awk -F '\t' '{ printf "%s\t%s\t%s\n", $2, $1, $3 }'
