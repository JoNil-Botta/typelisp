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

# Resolve the sysroot static stdlib archive for triple `$1` beside compiler `$2`
# (defaulting to $COMPILER) into STDLIB_ARCHIVE_PATH, empty when none exists.
# The answer is cached per triple, compiler and TYPELISP_SYSROOT, so a script
# that resolves once in its own shell pays the directory probe once per run;
# command-substitution callers then inherit the cached answer.
stdlib_archive_resolve_triple() {
    _ls_triple=$1
    _ls_compiler=${2:-${COMPILER:-}}
    _ls_key="$_ls_triple|$_ls_compiler|${TYPELISP_SYSROOT:-}"
    if [ "$_ls_key" = "${_LS_ARCHIVE_KEY_1:-}" ]; then
        STDLIB_ARCHIVE_PATH=$_LS_ARCHIVE_PATH_1
        return 0
    fi
    if [ "$_ls_key" = "${_LS_ARCHIVE_KEY_2:-}" ]; then
        STDLIB_ARCHIVE_PATH=$_LS_ARCHIVE_PATH_2
        return 0
    fi
    STDLIB_ARCHIVE_PATH=""
    if [ "${TYPELISP_SYSROOT:-}" = "none" ]; then
        :
    elif [ -n "${TYPELISP_SYSROOT:-}" ] && [ -f "$TYPELISP_SYSROOT/lib/$_ls_triple/libstdlib.a" ]; then
        STDLIB_ARCHIVE_PATH="$TYPELISP_SYSROOT/lib/$_ls_triple/libstdlib.a"
    elif [ -n "$_ls_compiler" ]; then
        case $_ls_compiler in
            */*) _ls_cdir=${_ls_compiler%/*} ;;
            *) _ls_cdir=. ;;
        esac
        _ls_cdir=$(CDPATH= cd -- "${_ls_cdir:-/}" 2>/dev/null && pwd) || _ls_cdir=""
        if [ -n "$_ls_cdir" ] && [ -f "$_ls_cdir/lib/$_ls_triple/libstdlib.a" ]; then
            STDLIB_ARCHIVE_PATH="$_ls_cdir/lib/$_ls_triple/libstdlib.a"
        fi
    fi
    _LS_ARCHIVE_KEY_2=${_LS_ARCHIVE_KEY_1:-}
    _LS_ARCHIVE_PATH_2=${_LS_ARCHIVE_PATH_1:-}
    _LS_ARCHIVE_KEY_1=$_ls_key
    _LS_ARCHIVE_PATH_1=$STDLIB_ARCHIVE_PATH
    return 0
}

# Print the sysroot static stdlib archive path when `$1` (assembly) references
# prebuilt stdlib/archive-runtime symbols and the matching sysroot archive
# exists for triple `$2` beside `$3` (compiler binary, defaulting to
# $COMPILER). Returns empty without running grep when no archive is present,
# preserving entry-caller test traces.
#
# Callers that link the archive also pass `-z noexecstack`: the archive's
# members carry .note.GNU-stack, while `compile` assembly put through a bare
# `as` does not, and GNU ld (as on the Ubuntu CI runners) warns about the
# note-less object when the inputs disagree. `typelisp build` appends that
# note to Linux assembly.
stdlib_archive_for_asm_triple() {
    _ls_asm=$1
    [ "${TYPELISP_SYSROOT:-}" = "none" ] && return 0
    stdlib_archive_resolve_triple "$2" "${3:-${COMPILER:-}}"
    [ -n "$STDLIB_ARCHIVE_PATH" ] || return 0
    [ -n "$_ls_asm" ] && [ -f "$_ls_asm" ] || return 0
    if ! grep -q '^tl_oom_abort:$' "$_ls_asm" 2>/dev/null && \
        grep -qE '(^|[[:space:]])(tl_oom_abort|tl_region_abort|tl_oob_abort|tl_oob_abort_at|tl_c_fn_null_abort|tl_panic_at|_tl_stdlib_|_tl___tl_mod_init_stdlib_)' "$_ls_asm" 2>/dev/null; then
        printf '%s\n' "$STDLIB_ARCHIVE_PATH"
    fi
    return 0
}

linux_stdlib_archive_for_asm() {
    stdlib_archive_for_asm_triple "$1" "x86_64-unknown-linux-gnu" "${2:-${COMPILER:-}}"
}

windows_stdlib_archive_for_asm() {
    stdlib_archive_for_asm_triple "$1" "x86_64-pc-windows-msvc" "${2:-${COMPILER:-}}"
}
