#!/usr/bin/env sh
set -eu
# Extract complete retained/inlined AES bodies, then compare reviewed hashes.
# No update/bless mode: changing these pins requires a new assembly review.
[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || { echo 'usage: check-crypto-aes-shape.sh <assembly> <fresh-output-dir> <reviewed-pins> [gcm]' >&2; exit 2; }
assembly=$1
work=$2
pins=$3
family=${4:-aes}
case "$family" in aes|gcm) ;; *) echo 'unknown crypto audit family' >&2; exit 2 ;; esac
mkdir -p "$work"
: > "$work/symbols"
# Keep all instructions, labels and instruction operands. Omit only assembler
# metadata/comments; CR normalization makes the same target host-independent.
awk -v output="$work" -v family="$family" '
function selected(name) {
    if (family == "gcm") return name ~ /^_tl_stdlib_crypto_(aes_core|aes128_gcm|ghash_core)_/ || name ~ /^gcm_audit_(seal|open)(\$typelisp)?$/ || name ~ /^_tl_stdlib_crypto_secret_stdlib_crypto_secret_(difference_bits|wipe_words_bang)$/ || name == "main"
    return name ~ /^_tl_stdlib_crypto_aes_core_/ || name ~ /^aes_audit_production_(128|256)(\$typelisp)?$/ || name == "main"
}
/^[[:space:]]*\.globl / {
    name = $2
    pending = selected(name) ? name : ""
    active = 0
    next
}
/^[A-Za-z0-9_$]+:$/ && $0 == pending ":" {
    name = pending
    if (defined[name]++) exit 1
    file = output "/" name ".body"
    print name > (output "/symbols")
    pending = ""
    active = 1
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
roots='main aes_audit_production_128 aes_audit_production_256'
if [ "$family" = gcm ]; then roots='main gcm_audit_seal gcm_audit_open'; fi
for required in $roots; do
    grep -Fx "$required" "$work/symbols" >/dev/null || { echo "missing production root: $required" >&2; exit 1; }
done
: > "$work/actual.sha256"
LC_ALL=C sort "$work/symbols" > "$work/sorted-symbols"
while IFS= read -r symbol; do
    sha256sum "$work/$symbol.body" > "$work/hash-output"
    read -r shape_hash shape_path < "$work/hash-output"
    printf '%s  %s\n' "$shape_hash" "$symbol" >> "$work/actual.sha256"
done < "$work/sorted-symbols"
if [ ! -f "$pins" ]; then
    echo "missing reviewed AES shape pins: $pins" >&2
    exit 1
fi
awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || seen[$2]++ { exit 1 }' "$pins" \
    || { echo 'malformed AES shape pins' >&2; exit 1; }
diff -u "$pins" "$work/actual.sha256"
