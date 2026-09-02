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

# Explicit ownership capability: a checked move into a fresh aggregate field
# is visible as StoreOwned/LoadOwned, the load starts in the loop and LICM
# moves it into the preheader, while an explicit shallow representation view
# in an otherwise identical fresh holder remains an ordinary Load. The proof
# capability forms are lowered back to ordinary IR before the backend.
OWNED_SOURCE="$ROOT/tests/golden/optimizer_owned_handle_licm.tl"
OWNED_AFTER="$WORKDIR/optimizer_owned_handle.after-owned.ir"
OWNED_LICM="$WORKDIR/optimizer_owned_handle.after-licm.ir"
OWNED_FINAL="$WORKDIR/optimizer_owned_handle.final.ir"

"$COMPILER" compile "$OWNED_SOURCE" \
    --dump-ir after-owned_handles \
    --verify-ir \
    --opt-level 2 \
    -o "$OWNED_AFTER" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/owned.stdout" 2>"$WORKDIR/owned.stderr"

"$COMPILER" compile "$OWNED_SOURCE" \
    --dump-ir after-licm \
    --verify-ir \
    --opt-level 2 \
    -o "$OWNED_LICM" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/owned_licm.stdout" 2>"$WORKDIR/owned_licm.stderr"

"$COMPILER" compile "$OWNED_SOURCE" \
    --dump-ir \
    --verify-ir \
    --opt-level 2 \
    -o "$OWNED_FINAL" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/owned_final.stdout" 2>"$WORKDIR/owned_final.stderr"

grep -F "store_owned" "$OWNED_AFTER" >/dev/null
if ! awk '
    /^function @.*owned-ir-positive/ { inside = 1; next }
    inside && /^}/ { exit !(header > 0 && owned > header) }
    inside && /while_header.*:$/ && header == 0 { header = NR }
    inside && /load_owned/ { owned = NR }
    END { if (!inside) exit 1 }
' "$OWNED_AFTER"; then
    echo "owning-handle capability was not explicit inside the positive loop" >&2
    exit 1
fi

if ! awk '
    /^function @.*owned-ir-positive/ { inside = 1; next }
    inside && /^}/ { exit !(owned > 0 && header > owned) }
    inside && /load_owned/ { owned = NR }
    inside && /while_header.*:$/ && header == 0 { header = NR }
    END { if (!inside) exit 1 }
' "$OWNED_LICM"; then
    echo "LICM did not hoist the proven owning-handle load" >&2
    exit 1
fi

if ! awk '
    /^function @.*owned-ir-shallow-negative/ { inside = 1; next }
    inside && /^}/ { exit (owned != 0) }
    inside && /load_owned/ { owned++ }
    END { if (!inside) exit 1 }
' "$OWNED_AFTER"; then
    echo "explicit shallow view incorrectly gained an ownership capability" >&2
    exit 1
fi

if grep -E "(own_root|store_owned|load_owned)" "$OWNED_FINAL" >/dev/null; then
    echo "owning-handle capability instruction survived final IR" >&2
    exit 1
fi

if "$COMPILER" run "$OWNED_SOURCE" \
    --opt-level 2 \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/owned_run.stdout" 2>"$WORKDIR/owned_run.stderr"; then
    OWNED_STATUS=0
else
    OWNED_STATUS=$?
fi
if [ "$OWNED_STATUS" -ne 49 ]; then
    echo "owning-handle runtime witness returned $OWNED_STATUS, expected 49" >&2
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

# DCE-2: `dce_late` closes the level-2 pass list, so an omission there is
# invisible unless the trace is asked for the slot by name -- the pipeline
# still reports every pass above it. A level-2 compile must observe the slot
# for every function it optimizes, and `--dump-ir after-dce_late` must answer:
# `licm_unswitch` runs unconditionally on the same level-2 path, so a function
# traced with that and without `dce_late` is a pipeline that stopped early.
LATE_TRACE="$WORKDIR/late.stderr"
LATE_IR="$WORKDIR/optimizer_fold.after-dce_late.ir"

"$COMPILER" compile "$SOURCE" \
    --dump-ir after-dce_late \
    --trace-passes \
    --verify-ir \
    --opt-level 2 \
    -o "$LATE_IR" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/late.stdout" 2>"$LATE_TRACE"

grep -F "optimizer-pass|main|dce_late|blocks=" "$LATE_TRACE" >/dev/null
grep -F "after dce_late @main" "$LATE_IR" >/dev/null

LATE_MISSING=$(awk -F'|' '
    $1 == "optimizer-pass" { seen[$3 "\t" $2] = 1 }
    END {
        for (key in seen) {
            split(key, field, "\t")
            if (field[1] == "licm_unswitch" && !(("dce_late\t" field[2]) in seen)) {
                print field[2]
            }
        }
    }
' "$LATE_TRACE")
if [ -n "$LATE_MISSING" ]; then
    echo "level-2 functions optimized without the final dce_late slot:" >&2
    printf '%s\n' "$LATE_MISSING" | sed 's/^/  /' >&2
    exit 1
fi

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

SLICE_SOURCE="$ROOT/tests/golden/slice_text_ir.tl"
SLICE_IR_FIRST="$WORKDIR/slice_text.first.ir"
SLICE_IR_SECOND="$WORKDIR/slice_text.second.ir"
SLICE_IR_FIRST_NORMALIZED="$WORKDIR/slice_text.first.normalized.ir"
SLICE_IR_SECOND_NORMALIZED="$WORKDIR/slice_text.second.normalized.ir"

for SLICE_OUTPUT in "$SLICE_IR_FIRST" "$SLICE_IR_SECOND"; do
    "$COMPILER" compile "$SLICE_SOURCE" \
        --dump-ir \
        --verify-ir \
        --opt-level 0 \
        -o "$SLICE_OUTPUT" \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        >"$WORKDIR/slice_text.stdout" 2>"$WORKDIR/slice_text.stderr"
done

tr -d '\r' <"$SLICE_IR_FIRST" >"$SLICE_IR_FIRST_NORMALIZED"
tr -d '\r' <"$SLICE_IR_SECOND" >"$SLICE_IR_SECOND_NORMALIZED"
if ! cmp -s "$SLICE_IR_FIRST_NORMALIZED" "$SLICE_IR_SECOND_NORMALIZED"; then
    echo "borrowed Slice textual IR dump is not deterministic" >&2
    diff -u "$SLICE_IR_FIRST_NORMALIZED" "$SLICE_IR_SECOND_NORMALIZED" >&2 || true
    exit 1
fi
grep -F "(& lifetime (Slice i64))" "$SLICE_IR_FIRST_NORMALIZED" >/dev/null

# Macro hygiene gives generated local bindings structural identities rather
# than pool ids. Lifetime rendering must decode that documented identity: both
# call-site borrows below come from the declaration-emitting text-buffer macro.
MACRO_LIFETIME_SOURCE="$ROOT/tests/golden/macro_hygiene_lifetime_ir.tl"
MACRO_LIFETIME_IR="$WORKDIR/macro_hygiene_lifetime.ir"

"$COMPILER" compile "$MACRO_LIFETIME_SOURCE" \
    --dump-ir \
    --verify-ir \
    --opt-level 0 \
    -o "$MACRO_LIFETIME_IR" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/macro_lifetime.stdout" 2>"$WORKDIR/macro_lifetime.stderr"

if grep -F "<id:" "$MACRO_LIFETIME_IR" >/dev/null; then
    echo "macro-hygiene lifetime dump retained an undecoded structural id" >&2
    exit 1
fi
grep -F "str-as-bytes" "$MACRO_LIFETIME_IR" | grep -F "(& chunk bytes)" >/dev/null
grep -F "str-as-bytes" "$MACRO_LIFETIME_IR" | grep -F "(& rendered bytes)" >/dev/null

# #6115 regression: a scaled dump must render with memory proportional to the
# output, not the retired quadratic recursive concatenation. 6000 tiny
# functions render ~1.5MB of IR text; the old render copied the remaining
# suffix once per element and blew past 11GB within seconds on this input, so
# a 6GB address-space cap fails fast there while the buffered render finishes
# well under 250MB. On Windows hosts the runner's commit limit bounds the old
# behavior the same way.
STRESS_SOURCE="$WORKDIR/dump_ir_stress.tl"
awk 'BEGIN {
  for (i = 0; i < 6000; i++) {
    printf "(define (f%d [x : i64]) : i64 (+ x %d))\n", i, i
  }
  print "(define (main) : i64"
  print "  (let [acc : i64 0]"
  print "    (begin"
  for (i = 0; i < 6000; i++) {
    printf "      (set! acc (+ acc (f%d 1)))\n", i
  }
  print "      acc)))"
}' >"$STRESS_SOURCE"

case "$(uname -s)" in
    Linux*)
        (
            ulimit -v 6291456
            "$COMPILER" compile "$STRESS_SOURCE" \
                --dump-ir \
                --opt-level 0 \
                -o "$WORKDIR/dump_ir_stress.ir" \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ROOT/src"
        )
        ;;
    *)
        "$COMPILER" compile "$STRESS_SOURCE" \
            --dump-ir \
            --opt-level 0 \
            -o "$WORKDIR/dump_ir_stress.ir" \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src"
        ;;
esac
test -s "$WORKDIR/dump_ir_stress.ir"
if [ "$(grep -c '^function @' "$WORKDIR/dump_ir_stress.ir")" -ne 6001 ]; then
    echo "scaled dump-ir regression: expected 6001 functions in the dump" >&2
    exit 1
fi

echo "[ir-observability] dump golden, pass trace, verifier, and scaled dump passed"
