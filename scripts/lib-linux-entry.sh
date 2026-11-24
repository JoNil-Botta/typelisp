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

# Print the sysroot static stdlib archive path when `$1` (assembly) references
# prebuilt stdlib/archive-runtime symbols and the matching sysroot archive
# exists beside `$2` (compiler binary, defaulting to $COMPILER). Returns empty
# without running grep when no archive is present, preserving entry-caller
# test traces.
#
# Callers that link the archive also pass `-z noexecstack`: the archive's
# members carry .note.GNU-stack, while `compile` assembly put through a bare
# `as` does not, and GNU ld (as on the Ubuntu CI runners) warns about the
# note-less object when the inputs disagree. `typelisp build` appends that
# note to Linux assembly.
stdlib_archive_for_asm_triple() {
    _ls_asm=$1
    _ls_triple=$2
    _ls_compiler=${3:-${COMPILER:-}}
    [ "${TYPELISP_SYSROOT:-}" = "none" ] && return 0
    _ls_archive=""
    if [ -n "${TYPELISP_SYSROOT:-}" ] && [ -f "$TYPELISP_SYSROOT/lib/$_ls_triple/libstdlib.a" ]; then
        _ls_archive="$TYPELISP_SYSROOT/lib/$_ls_triple/libstdlib.a"
    elif [ -n "$_ls_compiler" ]; then
        _ls_cdir=$(CDPATH= cd -- "$(dirname -- "$_ls_compiler")" 2>/dev/null && pwd)
        if [ -n "$_ls_cdir" ] && [ -f "$_ls_cdir/lib/$_ls_triple/libstdlib.a" ]; then
            _ls_archive="$_ls_cdir/lib/$_ls_triple/libstdlib.a"
        fi
    fi
    [ -n "$_ls_archive" ] || return 0
    [ -n "$_ls_asm" ] && [ -f "$_ls_asm" ] || return 0
    if ! grep -q '^tl_oom_abort:$' "$_ls_asm" 2>/dev/null && \
        grep -qE '(^|[[:space:]])(tl_oom_abort|tl_region_abort|tl_oob_abort|tl_oob_abort_at|tl_c_fn_null_abort|tl_panic_at|_tl_stdlib_|_tl___tl_mod_init_stdlib_)' "$_ls_asm" 2>/dev/null; then
        printf '%s\n' "$_ls_archive"
    fi
    return 0
}

linux_stdlib_archive_for_asm() {
    stdlib_archive_for_asm_triple "$1" "x86_64-unknown-linux-gnu" "${2:-${COMPILER:-}}"
}

windows_stdlib_archive_for_asm() {
    stdlib_archive_for_asm_triple "$1" "x86_64-pc-windows-msvc" "${2:-${COMPILER:-}}"
}
