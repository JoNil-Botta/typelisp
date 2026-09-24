# codegen-cases-plugins.sh - plugins for scripts/verify-codegen-cases.sh.
#
# Sourced by the runner. `check NAME ARGS...` calls plugin_NAME (hyphens become
# underscores) with the expanded ARGS; `setup NAME ARGS...` does the same before
# the case's action. A plugin prints why it failed to stderr and returns 1.
#
# Plugins see the variant's state: ROOT, COMPILER, CC_WORK (the case file's work
# directory), CV_DIR, CV_TARGET, CV_OPT, CV_MODE, CV_ASM, CV_SUBJECT (the current
# subject) and CC_ANALYZERS (scripts/codegen-cases-analyzers.awk).

# asm-equals OTHER-ASM SED-EXPR: the variant's assembly equals OTHER-ASM after
# SED-EXPR (e.g. a module-name rename).
plugin_asm_equals() {
    [ -f "$1" ] || {
        echo "  asm-equals: missing $1" >&2
        return 1
    }
    sed "$2" "$1" > "$CV_DIR/asm-equals.expected.s"
    cmp -s "$CV_DIR/asm-equals.expected.s" "$CV_ASM" && return 0
    diff -u "$CV_DIR/asm-equals.expected.s" "$CV_ASM" | sed -n '1,40p' >&2 || :
    return 1
}

# same-metric OTHER-ASM LABEL ANALYZER: ANALYZER over function LABEL gives the
# same value in this variant's assembly and in OTHER-ASM.
plugin_same_metric() {
    _psm_mine=$(awk -v label="$2:" '
        $0 == label { f = 1; print; next }
        f && /^\.globl[[:space:]]/ { exit }
        f && /^[[:space:]]*\.size[[:space:]]/ { exit }
        f { print }
    ' "$CV_ASM" | awk -v analyzer="$3" -f "$CC_ANALYZERS")
    _psm_other=$(awk -v label="$2:" '
        $0 == label { f = 1; print; next }
        f && /^\.globl[[:space:]]/ { exit }
        f && /^[[:space:]]*\.size[[:space:]]/ { exit }
        f { print }
    ' "$1" | awk -v analyzer="$3" -f "$CC_ANALYZERS")
    [ "$_psm_mine" = "$_psm_other" ] && return 0
    echo "  same-metric $3 of $2: $_psm_mine here, $_psm_other in $1" >&2
    return 1
}

# git-grep-absent ERE PATH...: no tracked file under PATH matches ERE.
plugin_git_grep_absent() {
    _pgg_re=$1
    shift
    if git -C "$ROOT" grep -n -E "$_pgg_re" -- "$@" >/dev/null 2>&1; then
        git -C "$ROOT" grep -n -E "$_pgg_re" -- "$@" >&2 || :
        return 1
    fi
    return 0
}

# for-copy-mutation DIR: copy the scalar `for` source transformer from
# stdlib/core_macros.tl into DIR/for_copy_macros.tl, renamed `for-copy` with its
# body byte-for-byte identical. Only the declaration is copied: loading the
# whole implicit-prelude module twice would test module identity instead.
plugin_for_copy_mutation() {
    mkdir -p "$1"
    {
        printf '%s\n\n' '(import stdlib.comptime)'
        awk '
            /^\(defmacro \(for / { copying = 1 }
            copying && /^\(cfg$/ { exit }
            copying { print }
        ' "$ROOT/stdlib/core_macros.tl" |
            sed '0,/(defmacro (for /s//(defmacro (for-copy /'
    } > "$1/for_copy_macros.tl"
}
