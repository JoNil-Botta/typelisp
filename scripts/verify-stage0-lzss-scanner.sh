#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-stage0-lzss.sh"
work=$(mktemp -d "${TMPDIR:-${TEMP:-/tmp}}/tl-lzss-scanner.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

frame() {
    printf '__typelisp_embedded_stdlib_lzss_v%s__%s\n' "$1" "$2"
    printf '%b' "$3"
}
expect() {
    actual=$(scan_stage0_lzss "$work/frame")
    [ "$actual" = "$1" ] || {
        echo "LZSS scanner $label: expected $1, got $actual" >&2
        exit 1
    }
}
reject() {
    if scan_stage0_lzss "$work/frame" > "$work/out" 2> "$work/err"; then
        echo "LZSS scanner accepted $label" >&2
        exit 1
    fi
    grep -F "$1" "$work/err" >/dev/null || {
        cat "$work/err" >&2
        exit 1
    }
}

label=empty
frame 1 0 '' > "$work/frame"
expect '1 0 38 1 0 0'
frame 2 0 '' > "$work/frame"
expect '1 0 38 0 1 0'
label=v1-literal
frame 1 1 '\001A' > "$work/frame"
expect '1 2 40 1 0 1'
label=v1-overlapping-match
frame 1 19 '\001A\000\017' > "$work/frame"
expect '1 4 43 1 0 19'
label=v2-literal
frame 2 1 '\365\200' > "$work/frame"
expect '1 2 40 0 1 1'
label=v2-binary-long-codes
frame 2 3 '\376\271\377\377\314' > "$work/frame"
expect '1 5 43 0 1 3'
label=v2-overlapping-match
frame 2 19 '\365\210' > "$work/frame"
expect '1 2 41 0 1 19'
label=v2-all-length-symbols
frame 2 169 '\365\211\011\212\005\042\241\130\260\054\213\102\330\270\056\213\302\370\137\210' > "$work/frame"
expect '1 20 60 0 1 169'
label=v2-window-wrap-and-maximum-distance
# 4096 copies of A followed by an 18-byte match at distance 4096.
frame 2 4114 '\365\210\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\100\201\002\004\010\020\040\130\157\376\000' > "$work/frame"
expect '1 204 245 0 1 4114'
label=mixed-and-marker-constants
{
    printf '___'
    printf '__typelisp_embedded_stdlib_lzss_v1__\000'
    printf '__typelisp_embedded_stdlib_lzss_v2__\000'
    frame 1 1 '\001A'
    frame 2 1 '\365\200'
    frame 2 4 '\365\211\000'
} > "$work/frame"
expect '3 7 121 1 2 6'

for version in 1 2; do
    label=v$version-missing-length
    frame "$version" '' '' > "$work/frame"
    reject 'malformed raw length'
    label=v$version-malformed-length
    frame "$version" 1x '' > "$work/frame"
    reject 'malformed raw length'
    label=v$version-overflow
    frame "$version" 9223372036854775808 '' > "$work/frame"
    reject 'impossible raw length'
    label=v$version-truncated-header
    printf '__typelisp_embedded_stdlib_lzss_v%s__1' "$version" > "$work/frame"
    reject 'truncated header'
done
label=v1-before-output
frame 1 3 '\000\000\000' > "$work/frame"
reject 'backreference before output'
label=v1-overrun
frame 1 2 '\001A\000\000' > "$work/frame"
reject 'token exceeds raw length'
label=v2-before-output
frame 2 3 '\022' > "$work/frame"
reject 'backreference before output'
label=v2-overrun
frame 2 2 '\365\211\000' > "$work/frame"
reject 'token exceeds raw length'
label=v2-distance-extra-bits
frame 2 19 '\365\267\377\000' > "$work/frame"
reject 'backreference before output'
label=v2-padding
frame 2 1 '\365\201' > "$work/frame"
reject 'nonzero v2 padding'

# Every proper truncation after a complete marker must fail, including flag,
# literal, reference, Huffman symbol, extra-bit and length boundaries.
for version in 1 2; do
    if [ "$version" = 1 ]; then
        frame 1 19 '\001A\000\017' > "$work/full"
    else
        frame 2 19 '\365\267\377\000' > "$work/full"
    fi
    bytes=$(wc -c < "$work/full" | tr -d ' ')
    n=36
    while [ "$n" -lt "$bytes" ]; do
        label=v$version-truncated-at-$n
        dd if="$work/full" of="$work/frame" bs=1 count="$n" 2>/dev/null
        reject 'truncated'
        n=$((n + 1))
    done
done

# Exercise declaration-derived expectations through the complete analyzer.
# A section-reader fixture lets these byte-level cases run on either host
# without linking an executable or substituting binary-derived expectations.
mkdir "$work/bin"
cat > "$work/bin/llvm-readobj" <<'EOF'
#!/usr/bin/env sh
cat <<'SECTIONS'
Format: scanner-fixture
Section {
  Name: .data
  RawDataSize: 1
  VirtualSize: 1
}
SECTIONS
EOF
chmod +x "$work/bin/llvm-readobj"
printf 'A' > "$work/payload.txt"
printf 'AAAA' > "$work/catalog.tsv"
printf '(include-str-lzss payload "payload.txt")\n' > "$work/manifest.tl"
printf '(include-str-lzss\n  catalog\n  "catalog.tsv")\n' > "$work/catalog.tl"
analyze() {
    PATH="$work/bin:$PATH" scripts/analyze-stage0-size.sh \
        --embedded-stdlib "$work/manifest.tl" \
        --compiler-sources "$work/catalog.tl" "$work/frame"
}
{
    frame 1 1 '\001A'
    frame 2 4 '\365\211\000'
} > "$work/frame"
analyze > "$work/report"
tab=$(printf '\t')
grep -Fx "embedded_stdlib_manifest_lzss_declarations${tab}1" "$work/report"
grep -Fx "other_compiler_owned_lzss_declarations${tab}1" "$work/report"
grep -Fx "lzss_payload_streams${tab}2" "$work/report"
grep -Fx "compressed_token_bytes${tab}5" "$work/report"
grep -Fx "static_payload_bytes${tab}81" "$work/report"
grep -Fx "other_compiler_owned${tab}1${tab}4" "$work/report"
grep -Fx "other_compiler_owned${tab}$work/catalog.tl${tab}$work/catalog.tsv" "$work/report"

analyze_reject() {
    if analyze > "$work/out" 2> "$work/err"; then
        echo "LZSS analyzer accepted $label" >&2
        exit 1
    fi
    grep -F "$1" "$work/err" >/dev/null || { cat "$work/err" >&2; exit 1; }
}
label=missing-outside-manifest-frame
frame 1 1 '\001A' > "$work/frame"
analyze_reject 'found 1'
label=extra-frame
{
    frame 1 1 '\001A'
    frame 2 4 '\365\211\000'
    frame 2 1 '\365\200'
} > "$work/frame"
analyze_reject 'found 3'
label=zero-frames
printf '__typelisp_embedded_stdlib_lzss_v2__\000' > "$work/frame"
analyze_reject 'found 0'
label=outside-manifest-declaration
printf '(include-str catalog "catalog.tsv")\n' > "$work/catalog.tl"
{
    frame 1 1 '\001A'
    frame 2 4 '\365\211\000'
} > "$work/frame"
analyze_reject 'expected 1 compiler-owned LZSS payloads'

# Legal layouts must never hide a declaration or let a later one overwrite it.
# Strings, comments and character delimiters must not manufacture declarations.
printf B > "$work/catalog2.tsv"
for layout in trailing-comment indented newline-after-open same-line comments-between; do
    case "$layout" in
        trailing-comment) first='(include-str-lzss catalog "catalog.tsv") ; one' ;;
        indented) first='  (include-str-lzss catalog "catalog.tsv")' ;;
        newline-after-open) first='(\n include-str-lzss catalog "catalog.tsv")' ;;
        same-line) first='(include-str-lzss catalog "catalog.tsv") ' ;;
        comments-between) first='( ; head\n include-str-lzss ; name\n catalog ; path\n "catalog.tsv" ; close\n )' ;;
    esac
    {
        printf '%b' "$first"
        [ "$layout" = same-line ] || printf '\n'
        printf '(include-str-lzss catalog2 "catalog2.tsv")\n'
        printf '; (include-str-lzss decoy "absent")\n'
        printf '(define decoy : String "(include-str-lzss x \\"absent\\")")\n'
        printf "(define open-char : char '(')\n(define close-char : char ')')\n"
    } > "$work/catalog.tl"
    {
        frame 1 1 '\001A'
        frame 1 1 '\001B'
    } > "$work/frame"
    label=$layout-missing-first-catalog
    analyze_reject 'expected 3 compiler-owned LZSS payloads'
    frame 2 4 '\365\211\000' >> "$work/frame"
    analyze > "$work/report"
    grep -Fx "other_compiler_owned_lzss_declarations${tab}2" "$work/report" >/dev/null
done
label=missing-catalog-input
# Keep the missing input outside the repository target/ even when TMPDIR is
# inside it. A target component elsewhere must not make an input generated.
printf '(include-str-lzss catalog "../stdlib/target/tl-lzss-scanner-missing-catalog.tsv")\n' > "$work/catalog.tl"
{
    frame 1 1 '\001A'
    frame 2 4 '\365\211\000'
} > "$work/frame"
analyze_reject 'payload not found'

# The same token inventory supplies the unchanged TLCH declaration/path checks.
printf '(include-str-lzss catalog "catalog.tsv")\n' > "$work/catalog.tl"
printf X > "$work/image.bin"
printf ' (\n include-bin image "image.bin.tlch") ; image\n' >> "$work/manifest.tl"
{
    printf '__typelisp_embedded_stdlib_tlch_v1__'
    printf '\001\000\000\000\000\000\000\000\001\000\000\000\000\000\000\000'
    dd if=/dev/zero bs=4369 count=1 2>/dev/null
    printf '\000'
} > "$work/tlch"
label=missing-tlch
analyze_reject 'expected 1 embedded stdlib TLCH payloads'
cat "$work/tlch" >> "$work/frame"
analyze > "$work/report"
grep -Fx "tlci_envelope_raw_bytes${tab}1" "$work/report" >/dev/null
grep -Fx "tlci_envelope_static_bytes${tab}4422" "$work/report" >/dev/null
grep -Fx "static_payload_bytes${tab}4503" "$work/report" >/dev/null
# Indexed TLCH v2 retains exact complete accounting and fails closed on a
# malformed authenticated index, frame range, identity or padding byte.
. "$ROOT/scripts/lib-stage0-tlch.sh"
u64() {
    # These are binary octets, not locale-dependent Unicode characters.
    LC_ALL=C awk -v value="$1" 'BEGIN { for (i=0;i<8;i++) { printf "%c",value%256; value=int(value/256) } }'
}
stamp_index() {
    index_hash=$(od -An -v -tu1 "$work/v2" | awk '
        BEGIN { h=1; i=0 }
        { for (f=1;f<=NF && i<4583;f++) { h=(h*131+((i>=60 && i<68)?0:$f))%2147483647; i++ } }
        END { printf "%.0f",h }')
    u64 "$index_hash" | dd of="$work/v2" bs=1 seek=60 conv=notrunc 2>/dev/null
}
write_v2() {
    {
        printf '__typelisp_embedded_stdlib_tlch_v2__'
        u64 528; u64 4583; u64 3; u64 0
        dd if=/dev/zero bs=4369 count=1 2>/dev/null
        u64 4581; u64 0; u64 4583; u64 176; u64 1; u64 0
        u64 4581; u64 1; u64 4584; u64 176; u64 1; u64 0
        u64 4582; u64 1; u64 4585; u64 176; u64 1; u64 0
        printf 'ab\000\000\000'
    } > "$work/v2"
    stamp_index
}
reject_v2() {
    if scan_stage0_tlch "$work/v2" > "$work/out" 2> "$work/err"; then
        echo "TLCH v2 scanner accepted $label" >&2
        exit 1
    fi
    grep -F "$1" "$work/err" >/dev/null || { cat "$work/err" >&2; exit 1; }
}
write_v2
actual=$(scan_stage0_tlch "$work/v2")
[ "$actual" = '1 528 3 4586' ] || {
    echo "TLCH v2 scanner: expected 1 528 3 4586, got $actual" >&2
    exit 1
}
{
    frame 1 1 '\001A'
    frame 2 4 '\365\211\000'
    cat "$work/v2"
} > "$work/frame"
analyze > "$work/report"
grep -Fx "tlci_envelope_raw_bytes	528" "$work/report" >/dev/null
grep -Fx "tlci_envelope_static_bytes	4586" "$work/report" >/dev/null
grep -Fx "static_payload_bytes	4667" "$work/report" >/dev/null
label=v2-index-hash
printf X | dd of="$work/v2" bs=1 seek=4581 conv=notrunc 2>/dev/null
reject_v2 'index hash mismatch'
label=v2-unsorted
write_v2
printf ba | dd of="$work/v2" bs=1 seek=4581 conv=notrunc 2>/dev/null
stamp_index
reject_v2 'unsorted or duplicate'
label=v2-duplicate
write_v2
printf aa | dd of="$work/v2" bs=1 seek=4581 conv=notrunc 2>/dev/null
stamp_index
reject_v2 'unsorted or duplicate'
label=v2-frame-overlap
write_v2
u64 4584 | dd of="$work/v2" bs=1 seek=4549 conv=notrunc 2>/dev/null
stamp_index
reject_v2 'invalid frame bounds'
label=v2-name-range
write_v2
u64 2 | dd of="$work/v2" bs=1 seek=4541 conv=notrunc 2>/dev/null
stamp_index
reject_v2 'invalid frame bounds'
label=v2-padding
write_v2
printf '\001' | dd of="$work/v2" bs=1 seek=4585 conv=notrunc 2>/dev/null
reject_v2 'nonzero padding'
label=v2-truncated
write_v2
dd if="$work/v2" of="$work/truncated-v2" bs=1 count=4585 2>/dev/null
cp "$work/truncated-v2" "$work/v2"
reject_v2 'invalid frame bounds'
if [ "${1:-}" != --target-tmpdir ]; then
    mkdir "$work/target"
    TMPDIR="$work/target" "$ROOT/scripts/verify-stage0-lzss-scanner.sh" --target-tmpdir
fi
echo 'stage0 LZSS/TLCH scanner formats and malformed payloads passed'
