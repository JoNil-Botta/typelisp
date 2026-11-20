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
: > "$work/arg-entries"
# Keep all instructions, labels and instruction operands. Omit only assembler
# metadata/comments; CR normalization makes the same target host-independent.
awk -v output="$work" -v family="$family" '
function selected(name) {
    if (family == "gcm") return name ~ /^_tl_stdlib_crypto_(aes_core|aes128_gcm|ghash_core|stack_scrub)_/ || name ~ /^gcm_audit_(seal|open)(\$typelisp)?$/ || name ~ /^_tl_stdlib_crypto_secret_stdlib_crypto_secret_(difference_bits|wipe_words_bang)$/ || name == "main"
    return name ~ /^_tl_stdlib_crypto_(aes_core|stack_scrub)_/ || name ~ /^aes_audit_production_(128|256)(\$typelisp)?$/ || name == "main"
}
/^[[:space:]]*\.globl / {
    name = $2
    pending = selected(name) ? name : ""
    active = 0
    next
}
/^"__tl_arg_entry:[0-9]+":$/ {
    entry = substr($0, 2, length($0) - 3)
    if (entry in entry_body) exit 1
    entry_body[entry] = $0
    next
}
entry != "" && !entry_target {
    if ($0 == "    .size \"" entry "\", . - \"" entry "\"") {
        entry_target = 1
        next
    }
    entry_body[entry] = entry_body[entry] "\n" $0
    next
}
entry_target {
    if ($0 !~ /^[A-Za-z0-9_.$]+:$/) exit 1
    callee = substr($0, 1, length($0) - 1)
    entry_body[entry] = entry_body[entry] "\n" $0
    entry_callee[entry] = callee
    if (selected(callee)) entry_needed[entry] = 1
    entry = ""
    entry_target = 0
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
    if ($0 ~ /^[[:space:]]*call "__tl_arg_entry:[0-9]+"$/)
        entry_needed[substr($2, 2, length($2) - 2)] = 1
    print > file
}
END {
    if (entry != "") exit 1
    for (key in entry_needed) {
        if (!(key in entry_callee)) exit 1
        print key > (output "/symbols")
        print entry_body[key] > (output "/" key ".body")
        print "\"" key "\"", entry_callee[key] > (output "/arg-entries")
    }
}
' "$assembly"
[ -s "$work/symbols" ] || { echo 'missing AES audit roots' >&2; exit 1; }
roots='main aes_audit_production_128 aes_audit_production_256'
if [ "$family" = gcm ]; then roots='main gcm_audit_seal gcm_audit_open'; fi
for required in $roots; do
    grep -Fx "$required" "$work/symbols" >/dev/null || { echo "missing production root: $required" >&2; exit 1; }
done
if [ "$family" = gcm ]; then
    # Keep the raw bodies for hash comparison. Resolve private entry calls in
    # the open path separately so the order assertion reads the actual callee.
    for symbol in _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_open_operation \
        gcm_audit_open 'gcm_audit_open$typelisp'; do
        [ -f "$work/$symbol.body" ] || continue
        awk '
            FILENAME == ARGV[1] { callee[$1] = $2; next }
            $1 == "call" && $2 in callee { sub($2, callee[$2]) }
            { print }
        ' "$work/arg-entries" "$work/$symbol.body" > "$work/$symbol.resolved"
    done
fi
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
