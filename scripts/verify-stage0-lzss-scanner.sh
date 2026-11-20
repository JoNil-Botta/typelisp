#!/usr/bin/env sh
set -eu

# Fixture coverage for the two awk scanners in lib-stage0-lzss.sh (source
# frames) and lib-stage0-tlch.sh (catalog envelopes), plus the declaration
# inventory the analyzer derives from the compiler's own sources.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-stage0-lzss.sh"
. "$ROOT/scripts/lib-stage0-tlch.sh"
work=$(mktemp -d "${TMPDIR:-${TEMP:-/tmp}}/tl-lzss-scanner.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

compiler=${TYPELISP_BIN:-}
if [ -z "$compiler" ]; then
    compiler=$ROOT/target/bootstrap-fixpoint/stage2
fi
if [ ! -x "$compiler" ]; then
    echo "stage0 LZSS scanner: no compiler to build fixtures with ($compiler)" >&2
    exit 2
fi

# One payload, extracted from the assembly the compiler emits for a program
# whose only static data is the include.
payload_of() {
    mkdir -p "$work/build"
    printf '%s' "$1" > "$work/build/payload.txt"
    printf '(include-str-lzss payload "payload.txt")\n(define (main) : i64 0)\n' \
        > "$work/build/main.tl"
    "$compiler" compile "$work/build/main.tl" -o "$work/build/main.s" \
        --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" --opt-level 0 \
        >/dev/null 2>&1
    awk '
        /^[ \t]*\.byte/ {
            if (started && !inside) bad = 1
            inside = 1; started = 1
            for (i = 2; i <= NF; i++) {
                value = $i
                gsub(/,/, "", value)
                if (value == "") continue
                printf "%c", value + 0
            }
            next
        }
        { if (inside) inside = 0 }
        END { if (bad) exit 1 }
    ' "$work/build/main.s" > "$2"
    [ -s "$2" ]
}

expect() {
    actual=$(scan_stage0_lzss "$1")
    [ "$actual" = "$2" ] || {
        echo "LZSS scanner $label: expected $2, got $actual" >&2
        exit 1
    }
}
reject() {
    if scan_stage0_lzss "$1" > "$work/out" 2> "$work/err"; then
        echo "LZSS scanner accepted $label" >&2
        exit 1
    fi
    grep -F "$2" "$work/err" >/dev/null || {
        cat "$work/err" >&2
        exit 1
    }
}

# A real frame: marker, decimal raw length, token stream.
payload_of 'A' "$work/frame-a"
label=accept-one
expect "$work/frame-a" "1 $(($(wc -c < "$work/frame-a") - 38)) $(wc -c < "$work/frame-a" | tr -d ' ') 1 1"

payload_of 'hello hello hello world' "$work/frame-text"
label=accept-text
expect "$work/frame-text" \
    "1 $(($(wc -c < "$work/frame-text") - 38)) $(wc -c < "$work/frame-text" | tr -d ' ') 1 25"

# Two frames in one binary are two streams with their own raw lengths.
{ cat "$work/frame-a"; cat "$work/frame-text"; } > "$work/frame-two"
label=accept-two
expect "$work/frame-two" \
    "2 $(($(wc -c < "$work/frame-two") - 76)) $(wc -c < "$work/frame-two" | tr -d ' ') 2 26"

# Marker-only strings are not frames.
{ printf '__typelisp_embedded_stdlib_tlss_v3__\000'; cat "$work/frame-a"; } \
    > "$work/frame"
label=marker-constant
expect "$work/frame" "1 $(($(wc -c < "$work/frame-a") - 38)) $(wc -c < "$work/frame" | tr -d ' ') 1 1"

# Every proper truncation must fail rather than read past the stream.
bytes=$(wc -c < "$work/frame-text" | tr -d ' ')
n=36
while [ "$n" -lt "$bytes" ]; do
    label=truncated-at-$n
    dd if="$work/frame-text" of="$work/frame" bs=1 count="$n" 2>/dev/null
    reject "$work/frame" 'truncated'
    n=$((n + 1))
done

label=impossible-raw-length
{ printf '__typelisp_embedded_stdlib_tlss_v3__'; printf '99999999999999999999\n'; } \
    > "$work/frame"
reject "$work/frame" 'impossible raw length'

label=malformed-raw-length
{ printf '__typelisp_embedded_stdlib_tlss_v3__'; printf '12x\n'; } > "$work/frame"
reject "$work/frame" 'malformed raw length'

# A body byte that is not part of the frame fails the tail checks.
label=trailing-byte
{ cat "$work/frame-text"; printf '\000'; } > "$work/frame"
reject "$work/frame" 'trailing compressed bytes'

label=nonzero-padding
cp "$work/frame-text" "$work/frame"
size=$(wc -c < "$work/frame" | tr -d ' ')
last=$(od -An -v -tu1 -j "$((size - 1))" -N 1 "$work/frame" | tr -d ' ')
printf "\\$(printf '%03o' "$((last | 1))")" |
    dd of="$work/frame" bs=1 seek="$((size - 1))" conv=notrunc 2>/dev/null
reject "$work/frame" 'padding bits'

# Declaration inventory: the analyzer maps the found streams to the declared
# inputs and reports both sides.
mkdir -p "$work/bin"
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
payload_of 'AAAA' "$work/frame-aaaa"
analyze() {
    PATH="$work/bin:$PATH" scripts/analyze-stage0-size.sh \
        --embedded-stdlib "$work/manifest.tl" \
        --compiler-sources "$work/catalog.tl" "$work/frame"
}
analyze_reject() {
    if analyze > "$work/out" 2> "$work/err"; then
        echo "LZSS analyzer accepted $label" >&2
        exit 1
    fi
    grep -F "$1" "$work/err" >/dev/null || { cat "$work/err" >&2; exit 1; }
}
tab=$(printf '\t')
{
    cat "$work/frame-a"
    cat "$work/frame-aaaa"
} > "$work/frame"
analyze > "$work/report"
grep -Fx "embedded_stdlib_manifest_lzss_declarations${tab}1" "$work/report"
grep -Fx "other_compiler_owned_lzss_declarations${tab}1" "$work/report"
grep -Fx "lzss_payload_streams${tab}2" "$work/report"
grep -Fx "lzss_v3_streams${tab}2" "$work/report"
grep -Fx "lzss_raw_bytes${tab}5" "$work/report"
grep -Fx "other_compiler_owned${tab}1${tab}4" "$work/report"

label=missing-outside-manifest-frame
cat "$work/frame-a" > "$work/frame"
analyze_reject 'found 1'
label=extra-frame
{
    cat "$work/frame-a"
    cat "$work/frame-aaaa"
    cat "$work/frame-a"
} > "$work/frame"
analyze_reject 'found 3'
label=zero-frames
printf '__typelisp_embedded_stdlib_tlss_v3__\000' > "$work/frame"
analyze_reject 'found 0'
label=outside-manifest-declaration
printf '(include-str catalog "catalog.tsv")\n' > "$work/catalog.tl"
{
    cat "$work/frame-a"
    cat "$work/frame-aaaa"
} > "$work/frame"
analyze_reject 'expected 1 compiler-owned LZSS payloads'

# Legal layouts must never hide a declaration or let a later one overwrite it.
# Strings, comments and character delimiters must not manufacture declarations.
printf B > "$work/catalog2.tsv"
payload_of 'B' "$work/frame-b"
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
        cat "$work/frame-a"
        cat "$work/frame-b"
    } > "$work/frame"
    label=$layout-missing-first-catalog
    analyze_reject 'expected 3 compiler-owned LZSS payloads'
    cat "$work/frame-aaaa" >> "$work/frame"
    analyze > "$work/report"
    grep -Fx "other_compiler_owned_lzss_declarations${tab}2" "$work/report" >/dev/null
done
label=missing-catalog-input
# Keep the missing input outside the repository target/ even when TMPDIR is
# inside it. A target component elsewhere must not make an input generated.
printf '(include-str-lzss catalog "../stdlib/target/tl-lzss-scanner-missing-catalog.tsv")\n' > "$work/catalog.tl"
{
    cat "$work/frame-a"
    cat "$work/frame-aaaa"
} > "$work/frame"
analyze_reject 'payload not found'

# Catalog envelopes: one header, one stored model, one index and one stream.
printf '(include-str-lzss catalog "catalog.tsv")\n' > "$work/catalog.tl"
u64() {
    # These are binary octets, not locale-dependent Unicode characters.
    LC_ALL=C awk -v value="$1" 'BEGIN { for (i=0;i<8;i++) { printf "%c",value%256; value=int(value/256) } }'
}
stamp_index() {
    index_hash=$(od -An -v -tu1 "$work/v3" | awk -v end="$1" '
        BEGIN { h=1; i=0 }
        { for (f=1;f<=NF && i<end;f++) { h=(h*131+((i>=60 && i<68)?0:$f))%2147483647; i++ } }
        END { printf "%.0f",h }')
    u64 "$index_hash" | dd of="$work/v3" bs=1 seek=60 conv=notrunc 2>/dev/null
}
directory=4489
write_v3() {
    {
        printf '__typelisp_embedded_stdlib_tlci_v3__'
        u64 528; u64 "$((directory + 48 + 2))"; u64 1; u64 0; u64 1
        dd if=/dev/zero bs=4413 count=1 2>/dev/null
        u64 "$((directory + 48))"; u64 0; u64 0; u64 176; u64 0; u64 1
        printf 'ab\000'
    } > "$work/v3"
    stamp_index "$((directory + 48 + 2))"
}
reject_v3() {
    if scan_stage0_tlch "$work/v3" > "$work/out" 2> "$work/err"; then
        echo "TLCH scanner accepted $label" >&2
        exit 1
    fi
    grep -F "$1" "$work/err" >/dev/null || { cat "$work/err" >&2; exit 1; }
}
write_v3
actual=$(scan_stage0_tlch "$work/v3")
[ "$actual" = "1 528 1 $((directory + 48 + 2))" ] || {
    echo "TLCH scanner: expected 1 528 1 $((directory + 48 + 2)), got $actual" >&2
    exit 1
}
{
    cat "$work/frame-a"
    cat "$work/frame-aaaa"
    cat "$work/v3"
} > "$work/frame"
analyze > "$work/report"
grep -Fx "tlci_envelope_raw_bytes${tab}528" "$work/report" >/dev/null

label=index-hash
printf X | dd of="$work/v3" bs=1 seek="$((directory + 48))" conv=notrunc 2>/dev/null
reject_v3 'index hash mismatch'
label=frame-record
write_v3
u64 7 | dd of="$work/v3" bs=1 seek="$((directory + 32))" conv=notrunc 2>/dev/null
stamp_index "$((directory + 48 + 2))"
reject_v3 'invalid frame record'
label=frame-offset
write_v3
u64 4 | dd of="$work/v3" bs=1 seek="$((directory + 16))" conv=notrunc 2>/dev/null
stamp_index "$((directory + 48 + 2))"
reject_v3 'invalid frame bounds'
label=frame-count
write_v3
u64 0 | dd of="$work/v3" bs=1 seek=52 conv=notrunc 2>/dev/null
stamp_index "$((directory + 48 + 2))"
reject_v3 'invalid envelope'
label=stream-short
write_v3
u64 2 | dd of="$work/v3" bs=1 seek=68 conv=notrunc 2>/dev/null
stamp_index "$((directory + 48 + 2))"
reject_v3 'inconsistent index length'
label=truncated
write_v3
size=$(wc -c < "$work/v3" | tr -d ' ')
dd if="$work/v3" of="$work/short" bs=1 count="$((size - 1))" 2>/dev/null
cp "$work/short" "$work/v3"
reject_v3 'truncated envelope'
if [ "${1:-}" != --target-tmpdir ]; then
    mkdir "$work/target"
    TMPDIR="$work/target" "$ROOT/scripts/verify-stage0-lzss-scanner.sh" --target-tmpdir
fi
echo 'stage0 LZSS/TLCH scanner formats and malformed payloads passed'
