# lib-linux-entry.sh - helpers for direct GNU ld links of TypeLisp assembly.
#
# Source it (not exec): `. "$ROOT/scripts/lib-linux-entry.sh"`. POSIX sh only.

linux_entry_symbol_for_asm() {
    _tle_asm=$1
    if grep -q '^_tl_start:$' "$_tle_asm"; then
        printf '%s\n' _tl_start
    elif grep -q '^_start:$' "$_tle_asm"; then
        printf '%s\n' _start
    else
        printf '%s\n' _tl_start
    fi
}
