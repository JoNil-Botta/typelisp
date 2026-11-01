#!/usr/bin/env sh
set -eu
# Extract complete retained/inlined AES bodies, then compare reviewed hashes.
# No update/bless mode: changing these pins requires a new assembly review.
[ "$#" -eq 3 ] || { echo 'usage: check-crypto-aes-shape.sh <assembly> <fresh-output-dir> <reviewed-pins>' >&2; exit 2; }
assembly=$1
work=$2
pins=$3
mkdir -p "$work"
: > "$work/symbols"
# Keep all instructions, labels and instruction operands. Omit only assembler
# metadata/comments; CR normalization makes the same target host-independent.
awk -v output="$work" '
function selected(name) {
    return name ~ /^_tl_stdlib_crypto_aes_core_/ || name ~ /^aes_audit_production_(128|256)(\$typelisp)?$/ || name == "main"
}
/^[[:space:]]*\.globl / {
    name = $2
    active = selected(name)
    if (active) { file = output "/" name ".body"; print name > (output "/symbols") }
    next
}
/^[[:space:]]*\.(size|section)[[:space:]]/ { active = 0; next }
active {
    sub(/\r$/, "")
    if ($0 ~ /^[[:space:]]*\./ && $0 !~ /^[^[:space:]]+:$/) next
    if ($0 ~ /^[[:space:]]*(#|;|$)/) next
    print > file
}
' "$assembly"
[ -s "$work/symbols" ] || { echo 'missing AES audit roots' >&2; exit 1; }
for required in main aes_audit_production_128 aes_audit_production_256; do
    grep -Fx "$required" "$work/symbols" >/dev/null || { echo "missing production root: $required" >&2; exit 1; }
done
: > "$work/actual.sha256"
LC_ALL=C sort "$work/symbols" > "$work/sorted-symbols"
while IFS= read -r symbol; do
    hash=$(sha256sum "$work/$symbol.body")
    hash=
    printf '%s  %s\n' "$hash" "$symbol" >> "$work/actual.sha256"
done < "$work/sorted-symbols"
if [ ! -f "$pins" ]; then
    echo "missing reviewed AES shape pins: $pins" >&2
    exit 1
fi
diff -u "$pins" "$work/actual.sha256"
