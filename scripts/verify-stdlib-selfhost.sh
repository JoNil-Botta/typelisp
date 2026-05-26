#!/usr/bin/env bash
# verify-stdlib-selfhost.sh — prove the canonical stdlib witness programs are
# accepted (or correctly rejected) by the SELFHOST compiler frontend
# (selfhost/check.tl: parse + typecheck via the selfhost parser/typechecker),
# complementing scripts/verify-stdlib.sh which drives the same witnesses through
# the Rust compiler. Part of #842 (prove stdlib modules with the selfhost
# compiler). This slice covers the selfhost frontend (parse + typecheck);
# selfhost compile+run of witnesses remains future work on #842.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${TYPELISP_BIN:-target/release/typelisp}"
HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
esac
case "$COMPILER" in
    *.exe) ;;
    *) [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe" ;;
esac
TARGET="$HOST_OS-x86_64"

# Negative witnesses: the selfhost typechecker must REJECT these with the given
# diagnostic substring (arena/region escape policy). Every other witness must be
# accepted (parse + typecheck clean). Keep this list in sync with the
# `expect-fail` rows of scripts/verify-stdlib.sh.
reject_diag() {
    case "$1" in
        stdlib/tests/arena_policy_escape_string.tl | stdlib/tests/arena_policy_escape_text_buf.tl)
            printf 'region-tagged value cannot escape with-arena' ;;
        *) printf '' ;;
    esac
}

fail=0
checked=0
for witness in stdlib/tests/*.tl; do
    checked=$((checked + 1))
    expect="$(reject_diag "$witness")"
    if out="$("$COMPILER" run selfhost/check.tl --target "$TARGET" -- "$witness" --stdlib-root stdlib 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    if [ -n "$expect" ]; then
        if [ "$rc" -eq 0 ]; then
            echo "FAIL: $witness expected selfhost rejection but it passed" >&2
            fail=1
        elif printf '%s' "$out" | grep -qF "$expect"; then
            echo "  ok (reject): $witness"
        else
            echo "FAIL: $witness rejected without expected diagnostic '$expect'" >&2
            printf '  got: %s\n' "$out" >&2
            fail=1
        fi
    elif [ "$rc" -eq 0 ]; then
        echo "  ok: $witness"
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
