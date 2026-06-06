#!/usr/bin/env bash
# verify-stdlib-selfhost.sh — prove the canonical stdlib witness programs are
# accepted (or correctly rejected) by the SELFHOST compiler frontend
# (retained selfhost/check.tl wrapper: parse + typecheck via the selfhost
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
    # No-Rust fallback for local development: fetch the published self-hosted
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
        stdlib/tests/io_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/process_borrowed_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/string_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/vector_slice_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        *) printf '' ;;
    esac
}

# Each witness is a separate retained selfhost/check.tl binary invocation, and
# the Windows build intermittently SEGFAULTs mid-compile (#1204). A segfault
# exits non-zero with no diagnostic, which would otherwise look like "a
# positive witness was rejected" or "a reject witness rejected without its
# diagnostic" and spuriously fail this gate. Retry an UNEXPECTED outcome a few
# times: a transient segfault
# clears on retry, while a genuine regression reproduces across every attempt and
# still fails.
# Default 6 (not 3): this gate makes ~23 separate check.tl invocations, so the
# #1204 Windows segfault can exhaust 3 attempts on one of them (observed on PR
# #1246); more headroom keeps the crash-only retry effective.
ATTEMPTS="${VERIFY_STDLIB_SELFHOST_ATTEMPTS:-6}"

WORKDIR="$ROOT/target/stdlib-selfhost-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
CHECK_BIN="$WORKDIR/check"
[ "$HOST_OS" = windows ] && CHECK_BIN="$WORKDIR/check.exe"
CHECK_OUT="$WORKDIR/check.compile.out"
CHECK_ERR="$WORKDIR/check.compile.err"
BUILD_TARGET=linux-x86_64
[ "$HOST_OS" = windows ] && BUILD_TARGET=windows-x86_64

if ! "$COMPILER" build selfhost/check.tl --target "$BUILD_TARGET" \
    --stdlib-root "$ROOT/stdlib" -o "$CHECK_BIN" >"$CHECK_OUT" 2>"$CHECK_ERR"; then
    echo "FAIL: selfhost/check.tl build failed" >&2
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
    attempt=0
    while [ "$attempt" -lt "$ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        if out="$("$CHECK_BIN" "$witness" --stdlib-root stdlib 2>&1)"; then
            rc=0
        else
            rc=$?
        fi
        witness_expected "$rc" "$expect" "$out"
        [ "$expected" -eq 1 ] && break
        if [ "$attempt" -lt "$ATTEMPTS" ]; then
            echo "  retry ($attempt/$ATTEMPTS): $witness unexpected (rc=$rc) — likely transient (#1204)" >&2
        fi
    done
    if [ "$expected" -eq 1 ]; then
        if [ -n "$expect" ]; then echo "  ok (reject): $witness"; else echo "  ok: $witness"; fi
    elif [ -n "$expect" ]; then
        if [ "$rc" -eq 0 ]; then
            echo "FAIL: $witness expected selfhost rejection but it passed" >&2
        else
            echo "FAIL: $witness rejected without expected diagnostic '$expect' (after $ATTEMPTS attempts)" >&2
        fi
        printf '  got: %s\n' "$out" >&2
        fail=1
    else
        echo "FAIL: $witness expected to pass the selfhost frontend but was rejected (rc=$rc, after $ATTEMPTS attempts)" >&2
        printf '  got: %s\n' "$out" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "verify-stdlib-selfhost: FAILED" >&2
    exit 1
fi
echo "verify-stdlib-selfhost: $checked stdlib witnesses verified through the selfhost frontend"
