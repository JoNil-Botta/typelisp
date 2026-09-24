#!/usr/bin/env sh

# lib-gate.sh - boilerplate shared by gate scripts.
#
# Source it (not exec) after setting ROOT: `. "$ROOT/scripts/lib-gate.sh"`.
# POSIX sh only.

# fail MESSAGE...
#   Print GATE_FAIL_PREFIX (set it before sourcing; empty by default) and
#   MESSAGE to stderr, then exit 1.
fail() {
    printf '%s%s\n' "${GATE_FAIL_PREFIX-}" "$*" >&2
    exit 1
}

# gate_compiler
#   Set COMPILER to TYPELISP_BIN. Local runs that leave it unset fetch the
#   published stage0 (CI always passes the compiler under test).
gate_compiler() {
    if [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi
}

# gate_compiler_absolute
#   Resolve a relative COMPILER against ROOT.
gate_compiler_absolute() {
    case "$COMPILER" in
        /* | [A-Za-z]:[/\\]*) ;;
        *) COMPILER="$ROOT/$COMPILER" ;;
    esac
}

# gate_require_compiler
#   Exit unless COMPILER is executable.
gate_require_compiler() {
    if [ ! -x "$COMPILER" ]; then
        echo "typelisp compiler is not executable: $COMPILER" >&2
        exit 1
    fi
}
