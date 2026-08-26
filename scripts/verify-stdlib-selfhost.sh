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
        stdlib/tests/comptime_string_literal_reject.tl)
            printf 'expr-string-value expects a string literal Expr' ;;
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
        stdlib/tests/core_macros_for_missing_protocol.tl)
            printf 'is missing protocol function into-iterator' ;;
        stdlib/tests/format_nonliteral_template_reject.tl)
            printf 'format: template must be a string literal' ;;
        stdlib/tests/format_bare_capture_reject.tl)
            printf "format: bare '_' is not a captured identifier" ;;
        stdlib/tests/format_duplicate_named_reject.tl)
            printf 'format: duplicate named argument name' ;;
        stdlib/tests/format_dynamic_precision_integer_type_reject.tl)
            printf 'format: dynamic precision argument must have exact type i64' ;;
        stdlib/tests/format_dynamic_precision_index_reject.tl)
            printf 'format: dynamic precision argument index is out of range: 2' ;;
        stdlib/tests/format_dynamic_precision_type_reject.tl)
            printf 'format: dynamic precision argument must have exact type i64' ;;
        stdlib/tests/format_dynamic_width_index_reject.tl)
            printf 'format: dynamic width argument index is out of range: 2' ;;
        stdlib/tests/format_dynamic_width_type_reject.tl)
            printf 'format: dynamic width argument must have exact type i64' ;;
        stdlib/tests/format_index_out_of_range_reject.tl)
            printf 'format: positional argument index is out of range: 2' ;;
        stdlib/tests/format_index_overflow_reject.tl)
            printf 'format: positional argument index overflow' ;;
        stdlib/tests/format_inner_whitespace_reject.tl)
            printf "format: whitespace is only allowed immediately before '}'" ;;
        stdlib/tests/format_malformed_capture_reject.tl)
            printf 'format: malformed captured argument identifier' ;;
        stdlib/tests/format_malformed_index_reject.tl)
            printf 'format: malformed positional argument index' ;;
        stdlib/tests/format_multibyte_fill_reject.tl)
            printf 'format: fill must be exactly one TypeLisp byte before alignment' ;;
        stdlib/tests/format_named_nonidentifier_reject.tl)
            printf 'format: named argument name must be an identifier' ;;
        stdlib/tests/format_non_ascii_whitespace_reject.tl)
            printf 'format: placeholder names and whitespace are ASCII-only' ;;
        stdlib/tests/format_owner_ambiguous_reject.tl)
            printf 'format: ambiguous owner hooks for' ;;
        stdlib/tests/format_owner_missing_reject.tl)
            printf 'format: unsupported nominal type' ;;
        stdlib/tests/format_owner_wrong_signature_reject.tl)
            printf 'format: owner hook has wrong signature for' ;;
        stdlib/tests/format_positional_after_named_reject.tl)
            printf 'format: positional argument follows named argument' ;;
        stdlib/tests/format_precision_duplicate_dollar_reject.tl)
            printf 'format: malformed, duplicated, or out-of-order format specifier' ;;
        stdlib/tests/format_precision_duplicate_star_reject.tl)
            printf 'format: malformed, duplicated, or out-of-order format specifier' ;;
        stdlib/tests/format_precision_missing_reject.tl)
            printf "format: precision requires a count or '*'" ;;
        stdlib/tests/format_precision_negative_literal_reject.tl)
            printf 'format: malformed precision count' ;;
        stdlib/tests/format_precision_overflow_reject.tl)
            printf 'format: precision integer overflow' ;;
        stdlib/tests/format_precision_unknown_capture_reject.tl)
            printf 'typecheck: unbound name missing' ;;
        stdlib/tests/format_plus_nonnumeric_reject.tl)
            printf "format: '+' sign requires a numeric argument" ;;
        stdlib/tests/format_raw_capture_reject.tl)
            printf "format: Rust raw identifiers use the TypeLisp spelling without 'r#'" ;;
        stdlib/tests/format_specifier_order_reject.tl)
            printf 'format: malformed, duplicated, or out-of-order format specifier' ;;
        stdlib/tests/format_specifier_reject.tl)
            printf 'format: type selector is parsed but not supported yet: x' ;;
        stdlib/tests/format_star_precision_too_few_reject.tl)
            printf 'format: not enough arguments for placeholders' ;;
        stdlib/tests/format_too_few_args_reject.tl)
            printf 'format: not enough arguments for placeholders' ;;
        stdlib/tests/format_too_many_args_reject.tl)
            printf 'format: not enough placeholders for arguments' ;;
        stdlib/tests/format_unknown_capture_reject.tl)
            printf 'typecheck: unbound name missing' ;;
        stdlib/tests/format_unused_named_reject.tl)
            printf 'format: unused named argument unused' ;;
        stdlib/tests/format_width_overflow_reject.tl)
            printf 'format: width integer overflow' ;;
        stdlib/tests/io_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/math_sqrt_non_float_reject.tl)
            printf 'math.sqrt: expected f64 or f32, found i64' ;;
        stdlib/tests/math_exp_non_float_reject.tl)
            printf 'math.exp: expected f64 or f32, found i64' ;;
        stdlib/tests/math_log_non_float_reject.tl)
            printf 'math.log: expected f64 or f32, found i64' ;;
        stdlib/tests/math_pow_non_float_reject.tl)
            printf 'math.pow: expected f64 or f32, found i64' ;;
        stdlib/tests/math_pow_mismatched_types_reject.tl)
            printf 'math.pow: exponent type must match base type f64, found f32' ;;
        stdlib/tests/hashmap_value_borrow_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/hashmap_value_borrow_insert_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_remove_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_put_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_resize_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_borrow_insert_or_update_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_double_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_put_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_resize_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_value_borrow_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_macro_value_borrow_insert_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_macro_mut_entry_insert_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `m`' ;;
        stdlib/tests/process_borrowed_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/string_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/vector_native_slice_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/vector_native_slice_grow_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `items`' ;;
        stdlib/tests/vector_native_slice_split_grow_live.tl)
            printf 'typecheck: cannot read mutably borrowed place `items`' ;;
        stdlib/tests/vector_native_slice_alias_reject.tl)
            printf 'typecheck: cannot read mutably borrowed place `items`' ;;
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
