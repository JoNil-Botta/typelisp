#!/usr/bin/env sh
# Checked metadata-only projection of the existing .cases format. Callers must
# check load success before reading rows and pass the source column unchanged.
# Inventories use only case/source/do-none; matrices remain in owning harnesses.
fixture_inventory_load() {
    case "$1" in tests/*.fixtures.cases) ;; *) echo "unsupported fixture inventory: $1" >&2; return 1 ;; esac
    "$ROOT/scripts/verify-codegen-cases.sh" --list-fixtures "$ROOT/$1" > "$2"
}

# For consumers that transform or otherwise choose a runtime primary path,
# require membership immediately before use. Direct row consumers need no call.
fixture_inventory_require() {
    awk -F '\t' -v source="$2" '$2 == source {found=1} END {exit !found}' "$1" && return 0
    echo "undeclared runtime primary: $2" >&2
    return 1
}
