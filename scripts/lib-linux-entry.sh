# lib-linux-entry.sh - helpers for direct GNU ld links of TypeLisp assembly.
#
# Source it (not exec): `. "$ROOT/scripts/lib-linux-entry.sh"`. POSIX sh only.

linux_entry_symbol_for_asm() {
    _tle_asm=$1
    for _tle_symbol in _tl_start _start; do
        if grep -q "^${_tle_symbol}:$" "$_tle_asm"; then
            printf '%s\n' "$_tle_symbol"
            return $?
        else
            _tle_status=$?
            # No match keeps the legacy/default fallback; read/tool errors
            # must stop the dependent link, including when errexit is off.
            [ "$_tle_status" -eq 1 ] || return "$_tle_status"
        fi
    done
    printf '%s\n' _tl_start
}
