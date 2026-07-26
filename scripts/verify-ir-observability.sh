#!/usr/bin/env sh
set -eu

# Verify the compiler-developer IR dump, pass trace, and verifier surfaces.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/ir-observability-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SOURCE="$ROOT/tests/golden/optimizer_fold.tl"
EXPECTED="$ROOT/tests/golden/optimizer_fold.after-fold.ir"
ACTUAL="$WORKDIR/optimizer_fold.after-fold.ir"
EXPECTED_NORMALIZED="$WORKDIR/optimizer_fold.expected.normalized.ir"
ACTUAL_NORMALIZED="$WORKDIR/optimizer_fold.actual.normalized.ir"
TRACE="$WORKDIR/trace.stderr"

"$COMPILER" compile "$SOURCE" \
    --dump-ir after-fold \
    --verify-ir \
    --opt-level 1 \
    -o "$ACTUAL" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/fold.stdout" 2>"$WORKDIR/fold.stderr"

tr -d '\r' <"$EXPECTED" >"$EXPECTED_NORMALIZED"
tr -d '\r' <"$ACTUAL" >"$ACTUAL_NORMALIZED"
if ! cmp -s "$EXPECTED_NORMALIZED" "$ACTUAL_NORMALIZED"; then
    echo "optimizer fold IR golden mismatch" >&2
    diff -u "$EXPECTED_NORMALIZED" "$ACTUAL_NORMALIZED" >&2 || true
    exit 1
fi

# Cross-block load GVN across a fresh allocation: the parameter's length field
# is loaded once and the second read is forwarded over tl_alloc, tl_array_zero,
# and the new descriptor's header stores.
GVN_SOURCE="$ROOT/tests/golden/optimizer_load_fresh_alloc.tl"
GVN_EXPECTED="$ROOT/tests/golden/optimizer_load_fresh_alloc.after-gvn.ir"
GVN_ACTUAL="$WORKDIR/optimizer_load_fresh_alloc.after-gvn.ir"
GVN_EXPECTED_NORMALIZED="$WORKDIR/optimizer_load_fresh_alloc.expected.normalized.ir"
GVN_ACTUAL_NORMALIZED="$WORKDIR/optimizer_load_fresh_alloc.actual.normalized.ir"

"$COMPILER" compile "$GVN_SOURCE" \
    --dump-ir after-gvn \
    --verify-ir \
    --opt-level 2 \
    -o "$GVN_ACTUAL" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/gvn.stdout" 2>"$WORKDIR/gvn.stderr"

tr -d '\r' <"$GVN_EXPECTED" >"$GVN_EXPECTED_NORMALIZED"
tr -d '\r' <"$GVN_ACTUAL" >"$GVN_ACTUAL_NORMALIZED"
if ! cmp -s "$GVN_EXPECTED_NORMALIZED" "$GVN_ACTUAL_NORMALIZED"; then
    echo "optimizer load-GVN fresh-allocation IR golden mismatch" >&2
    diff -u "$GVN_EXPECTED_NORMALIZED" "$GVN_ACTUAL_NORMALIZED" >&2 || true
    exit 1
fi

"$COMPILER" compile "$SOURCE" \
    --dump-ir \
    --verify-ir \
    --opt-level 2 \
    -o "$WORKDIR/optimizer_fold.final.ir" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/final.stdout" 2>"$WORKDIR/final.stderr"
grep -F "typelisp-ir v1" "$WORKDIR/optimizer_fold.final.ir" >/dev/null
grep -F "function @main()" "$WORKDIR/optimizer_fold.final.ir" >/dev/null

"$COMPILER" compile "$SOURCE" \
    --dump-ir after-licm \
    --trace-passes \
    --verify-ir \
    --opt-level 2 \
    -o "$WORKDIR/optimizer_fold.after-licm.ir" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/trace.stdout" 2>"$TRACE"

grep -F "optimizer-pass|main|licm|blocks=" "$TRACE" >/dev/null
grep -F "after licm @main" "$WORKDIR/optimizer_fold.after-licm.ir" >/dev/null

"$COMPILER" compile "$SOURCE" \
    --verify-ir \
    --opt-level 2 \
    -o "$WORKDIR/optimizer_fold.s" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/verify.stdout" 2>"$WORKDIR/verify.stderr"
test -s "$WORKDIR/optimizer_fold.s"

if "$COMPILER" compile "$SOURCE" \
    --dump-ir after-no-such-pass \
    --opt-level 2 \
    -o "$WORKDIR/should-not-exist.ir" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/missing.stdout" 2>"$WORKDIR/missing.stderr"; then
    echo "unknown IR pass unexpectedly succeeded" >&2
    exit 1
fi
grep -F "optimizer pass 'no-such-pass' did not run" "$WORKDIR/missing.stderr" >/dev/null
test ! -e "$WORKDIR/should-not-exist.ir"

echo "[ir-observability] dump golden, pass trace, and verifier passed"
