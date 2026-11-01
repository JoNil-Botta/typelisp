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
# independent LZSS frames; the generated TLCI catalog uses one versioned TLCH envelope.
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

. "$ROOT/scripts/lib-stage0-declarations.sh"
declarations="$tmp_dir/declarations.tsv"
stage0_payload_declarations "$EMBEDDED_STDLIB" "$COMPILER_SOURCES" > "$declarations"
awk -F '\t' '{ print $4 }' "$declarations" | sort > "$payload_paths"

[ -s "$payload_paths" ] || {
    echo "embedded stdlib build-input declaration list is empty" >&2
    exit 1
}
expected_payload_streams=$(wc -l < "$payload_paths" | tr -d ' ')
expected_tlch_streams=$(awk -F '\t' '$1 == "include-bin" { n++ } END { print n + 0 }' "$declarations")
awk -F '\t' '$1 == "include-str-lzss" { print $2 "\t" $3 "\t" $4 }' "$declarations" | sort > "$lzss_declarations"
expected_lzss_streams=$(wc -l < "$lzss_declarations" | tr -d ' ')
[ "$expected_lzss_streams" -gt 0 ] || {
    echo "compiler-owned LZSS declaration inventory is empty" >&2
    exit 1
}
manifest_lzss_streams=$(awk -F '\t' '$1 == "embedded_stdlib_manifest" { n++ } END { print n + 0 }' "$lzss_declarations")
other_lzss_streams=$(awk -F '\t' '$1 == "other_compiler_owned" { n++ } END { print n + 0 }' "$lzss_declarations")

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

# Recover both deployment versions without losing declaration-derived counts.
. "$ROOT/scripts/lib-stage0-tlch.sh"
tlch_counts=$(scan_stage0_tlch "$BINARY") || exit 1
set -- $tlch_counts
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
        # Normalize declaration-relative paths such as src/../target/ first.
        generated_path=$(printf '%s\n' "$path" | awk '
            {
                n = split($0, parts, "/")
                for (i = 1; i <= n; i++) {
                    if (parts[i] == "" || parts[i] == ".") continue
                    if (parts[i] == ".." && depth && stack[depth] != "..") depth--
                    else stack[++depth] = parts[i]
                }
                if (substr($0, 1, 1) == "/") printf "/"
                for (i = 1; i <= depth; i++) printf "%s%s", (i > 1 ? "/" : ""), stack[i]
                print ""
            }
        ')
        case "$generated_path" in
            target/* | "$ROOT"/target/*)
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
