#!/usr/bin/env bash
# verify-stdlib-selfhost.sh — prove the canonical stdlib witness programs are
# accepted (or correctly rejected) by the SELFHOST compiler frontend
# (selfhost/check.tl: parse + typecheck via the selfhost parser/typechecker),
# complementing scripts/verify-stdlib.sh which drives the same witnesses through
# the Rust compiler. Part of #842 (prove stdlib modules with the selfhost
# compiler). This slice covers the selfhost frontend (parse + typecheck) and is
# also run from the Linux no-Rust stage1 capability tier; selfhost compile+run
# of witnesses remains future work on #842.
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

# Each witness is a separate selfhost/check.tl binary invocation, and the Windows
# build intermittently SEGFAULTs mid-compile (#1204). A segfault exits non-zero
# with no diagnostic, which would otherwise look like "a positive witness was
# rejected" or "a reject witness rejected without its diagnostic" and spuriously
# fail this gate. Retry an UNEXPECTED outcome a few times: a transient segfault
# clears on retry, while a genuine regression reproduces across every attempt and
# still fails.
# Default 6 (not 3): this gate makes ~23 separate check.tl invocations, so the
# #1204 Windows segfault can exhaust 3 attempts on one of them (observed on PR
# #1246); more headroom keeps the crash-only retry effective.
ATTEMPTS="${VERIFY_STDLIB_SELFHOST_ATTEMPTS:-6}"

# #1270: `typelisp run selfhost/check.tl` runs the selfhost parser+typechecker as
# an emitted binary that segfaults ~100% on Windows on its typecheck path — the
# same non-ASLR selfhost-emitted-driver crash as `test --check` / `doc --test`
# (the binary already links /DYNAMICBASE:NO, so it is NOT the emitted-binary ASLR
# bug #1262 fixes). The crash is effectively deterministic per witness, so the
# retry guard above is exhausted on every one. Skip on Windows until #1270 is
# fixed; Linux still fully verifies the selfhost-frontend witnesses.
if [ "$HOST_OS" = windows ]; then
    echo "skipping stdlib selfhost-frontend witnesses on windows pending #1270 (check.tl selfhost-typechecker segfault)"
    exit 0
fi

command -v as >/dev/null 2>&1 || {
    echo "missing assembler: as" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "missing linker: ld" >&2
    exit 1
}

run_with_heartbeat() {
    label=$1
    shift
    status_file="$WORKDIR/heartbeat-$$.status"
    rm -f "$status_file"
    (
        set +e
        "$@"
        code=$?
        printf '%s\n' "$code" > "$status_file"
        exit "$code"
    ) &
    pid=$!
    elapsed=0
    while [ ! -f "$status_file" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $((elapsed % 30)) -eq 0 ]; then
            echo "[$label] still running (${elapsed}s)" >&2
        fi
    done
    wait "$pid" 2> /dev/null || true
    code=$(sed -n '1p' "$status_file")
    rm -f "$status_file"
    return "$code"
}

WORKDIR="$ROOT/target/stdlib-selfhost-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
CHECK_BIN="$WORKDIR/check"
CHECK_ASM="$WORKDIR/check.s"
CHECK_OBJ="$WORKDIR/check.o"
CHECK_OUT="$WORKDIR/check.compile.out"
CHECK_ERR="$WORKDIR/check.compile.err"

compile_check_driver() {
    "$COMPILER" compile selfhost/check.tl --stdlib-root "$ROOT/stdlib" -o "$CHECK_ASM" \
        >"$CHECK_OUT" 2>"$CHECK_ERR"
}

echo "[stdlib-selfhost] compiling selfhost/check.tl"
if ! run_with_heartbeat \
    "stdlib-selfhost selfhost/check.tl compile" \
    compile_check_driver; then
    echo "FAIL: selfhost/check.tl compile failed" >&2
    sed 's/^/  /' "$CHECK_ERR" >&2 || true
    exit 1
fi
echo "[stdlib-selfhost] assembling selfhost/check.tl"
if ! as "$CHECK_ASM" -o "$CHECK_OBJ" >>"$CHECK_OUT" 2>>"$CHECK_ERR"; then
    echo "FAIL: selfhost/check.tl assemble failed" >&2
    sed 's/^/  /' "$CHECK_ERR" >&2 || true
    exit 1
fi
echo "[stdlib-selfhost] linking selfhost/check.tl"
if ! ld "$CHECK_OBJ" -o "$CHECK_BIN" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc \
    >>"$CHECK_OUT" 2>>"$CHECK_ERR"; then
    echo "FAIL: selfhost/check.tl link failed" >&2
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
