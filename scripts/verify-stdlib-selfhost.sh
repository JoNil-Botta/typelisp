#!/usr/bin/env bash
# verify-stdlib-selfhost.sh — prove the canonical stdlib witness programs are
# accepted (or correctly rejected) by the SELFHOST compiler frontend
# (selfhost cli `check`: parse + typecheck via the selfhost
# parser/typechecker), complementing scripts/verify-stdlib.sh which drives the
# same witnesses through the full self-hosted compiler. Part of #842 (prove
# stdlib modules with the selfhost
# compiler). This slice covers the selfhost frontend (parse + typecheck);
# selfhost compile+run of witnesses remains future work on #842.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
esac
if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER="$TYPELISP_BIN"
else
    # Local-development fallback: fetch the published self-hosted
    # stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER="$(resolve_stage0_compiler "$ROOT")" || exit 1
fi
case "$COMPILER" in
    *.exe) ;;
    *) [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe" ;;
esac
# Negative witnesses: the selfhost typechecker must REJECT these with the given
# diagnostic substring. Every other witness must be accepted (parse + typecheck
# clean). Keep this list in sync with the `expect-fail` rows of
# scripts/verify-stdlib.sh.
reject_diag() {
    case "$1" in
        stdlib/tests/arena_policy_escape_string.tl | stdlib/tests/arena_policy_escape_text_buf.tl)
            printf 'region-tagged value cannot escape with-arena' ;;
        stdlib/tests/arena_policy_escape_text_buf_borrowed.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/core_macros_cond_flat_reject.tl)
            printf 'typecheck: ExprClause macro operand expects bracket syntax' ;;
        stdlib/tests/core_macros_cond_missing_else.tl)
            printf 'core-cond-missing-else' ;;
        stdlib/tests/core_macros_cond_else_not_final.tl)
            printf 'core-cond-else-must-be-final' ;;
        stdlib/tests/core_macros_cond_branch_mismatch.tl)
            printf 'typecheck: if branches must match' ;;
        stdlib/tests/core_macros_cond_non_bool.tl)
            printf 'typecheck: if condition must be bool' ;;
        stdlib/tests/io_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/hashmap_value_borrow_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/hashmap_value_borrow_insert_live.tl)
            printf 'typecheck: cannot assign to borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_remove_live.tl)
            printf 'typecheck: cannot assign to borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_put_live.tl)
            printf 'typecheck: cannot assign to borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_resize_live.tl)
            printf 'typecheck: cannot assign to borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_borrow_insert_or_update_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_double_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m.slots`' ;;
        stdlib/tests/hashmap_mut_entry_put_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_resize_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_value_borrow_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m.slots`' ;;
        stdlib/tests/process_borrowed_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/string_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/vector_slice_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        *) printf '' ;;
    esac
}

# Each witness is a separate selfhost cli `check` invocation, run exactly once.
# The Windows build has historically SEGFAULTed mid-compile (#1204); that is a
# real compiler bug, not a flake — do not retry it (see the no-retry policy in
# scripts/ci-verify.sh).

WORKDIR="$ROOT/target/stdlib-selfhost-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
CHECK_BIN="$WORKDIR/check"
[ "$HOST_OS" = windows ] && CHECK_BIN="$WORKDIR/check.exe"
CHECK_OUT="$WORKDIR/check.compile.out"
CHECK_ERR="$WORKDIR/check.compile.err"
BUILD_TARGET=linux-x86_64
[ "$HOST_OS" = windows ] && BUILD_TARGET=windows-x86_64

if ! "$COMPILER" build src/main.tl --target "$BUILD_TARGET" \
    --stdlib-root stdlib -o "$CHECK_BIN" >"$CHECK_OUT" 2>"$CHECK_ERR"; then
    echo "FAIL: src/main.tl build failed" >&2
    sed 's/^/  /' "$CHECK_ERR" >&2 || true
    exit 1
fi

# Sets the global `expected` to 1 when the (rc,out) pair matches the witness
# expectation: a reject witness ($2 non-empty) must fail AND carry the diagnostic
# substring; a positive witness must pass cleanly.
witness_expected() {
    expected=0
    if [ -n "$2" ]; then
        if [ "$1" -ne 0 ] && printf '%s' "$3" | grep -qF "$2"; then expected=1; fi
    elif [ "$1" -eq 0 ]; then
        expected=1
    fi
}

fail=0
checked=0
for witness in stdlib/tests/*.tl; do
    checked=$((checked + 1))
    expect="$(reject_diag "$witness")"
    if out="$("$CHECK_BIN" check "$witness" --stdlib-root stdlib 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    witness_expected "$rc" "$expect" "$out"
    if [ "$expected" -eq 1 ]; then
        if [ -n "$expect" ]; then echo "  ok (reject): $witness"; else echo "  ok: $witness"; fi
    elif [ -n "$expect" ]; then
        if [ "$rc" -eq 0 ]; then
            echo "FAIL: $witness expected selfhost rejection but it passed" >&2
        else
            echo "FAIL: $witness rejected without expected diagnostic '$expect'" >&2
        fi
        printf '  got: %s\n' "$out" >&2
        fail=1
    else
        echo "FAIL: $witness expected to pass the selfhost frontend but was rejected (rc=$rc)" >&2
        printf '  got: %s\n' "$out" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "verify-stdlib-selfhost: FAILED" >&2
    exit 1
fi
echo "verify-stdlib-selfhost: $checked stdlib witnesses verified through the selfhost frontend"
