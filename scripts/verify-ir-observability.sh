#!/usr/bin/env sh
set -eu

# Verify the compiler-developer IR dump, pass trace, and verifier surfaces.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_require_compiler

WORKDIR="$ROOT/target/ir-observability-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# Inject a verifier rejection at the CLI result handoff for every result
# carrier. Real invalid IR is intentionally not needed for this regression:
# the fixture owns advisory lists and checks rejection status without writing.
"$COMPILER" run "$ROOT/src/tests/compile_cli_verify_ir_advisories_smoke.tl" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/advisories.stdout" 2>"$WORKDIR/advisories.stderr"
test ! -s "$WORKDIR/advisories.stdout"
grep -E '^(error: |compile: IR verification failed: )' \
    "$WORKDIR/advisories.stderr" >"$WORKDIR/advisories.actual"
printf '%s\n' \
    'error: driver-first' \
    'error: driver-second' \
    'compile: IR verification failed: verify-driver-ok' \
    'error: driver-err' \
    'compile: IR verification failed: verify-driver-err' \
    'error: buffer-ok' \
    'compile: IR verification failed: verify-buffer-ok' \
    'error: buffer-err' \
    'compile: IR verification failed: verify-buffer-err' \
    'error: pic-ok' \
    'compile: IR verification failed: verify-pic-ok' \
    'error: pic-err' \
    'compile: IR verification failed: verify-pic-err' \
    'error: coff-first' \
    'error: coff-second' \
    'compile: IR verification failed: verify-coff' \
    'error: assembly' \
    'compile: IR verification failed: verify-assembly' \
    'error: windows-err' \
    'compile: IR verification failed: verify-windows-err' \
    'compile: IR verification failed: verify-empty-later-job' \
    >"$WORKDIR/advisories.expected"
if ! cmp -s "$WORKDIR/advisories.expected" "$WORKDIR/advisories.actual"; then
    echo "IR verification rejection lost or reordered advisories" >&2
    diff -u "$WORKDIR/advisories.expected" "$WORKDIR/advisories.actual" >&2 || true
    exit 1
fi

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

# The post-prune total-switch rewrite runs after the ordinary function
# pipeline. Its trace and dump must expose that later boundary, including
# unchanged IR.
"$COMPILER" compile "$SOURCE" \
    --dump-ir after-total_switch \
    --trace-passes \
    --verify-ir \
    --opt-level 2 \
    -o "$WORKDIR/optimizer_fold.after-total_switch.ir" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/total-switch.stdout" 2>"$WORKDIR/total-switch.stderr"
grep -F "optimizer-pass|main|total_switch|blocks=" "$WORKDIR/total-switch.stderr" >/dev/null
grep -F "after total_switch @main" "$WORKDIR/optimizer_fold.after-total_switch.ir" >/dev/null

"$COMPILER" compile "$SOURCE" \
    --verify-ir \
    --opt-level 2 \
    -o "$WORKDIR/optimizer_fold.s" \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    >"$WORKDIR/verify.stdout" 2>"$WORKDIR/verify.stderr"
test -s "$WORKDIR/optimizer_fold.s"

# The source-level hash loop exercises distinct, equivalent length
# operands in a widened bounds-check run. Verify both supported target routes;
# native manifests separately execute its empty/short/full-loop cases.
for HASH_TARGET in linux-x86_64 windows-x86_64; do
    "$COMPILER" compile "$ROOT/tests/integration/hash_length_chain.tl" \
        --verify-ir --opt-level 2 --target "$HASH_TARGET" \
        -o "$WORKDIR/hash-length-chain-$HASH_TARGET.s" \
        --stdlib-root "$ROOT/stdlib" \
        >"$WORKDIR/hash-length-chain-$HASH_TARGET.stdout" \
        2>"$WORKDIR/hash-length-chain-$HASH_TARGET.stderr"
    test -s "$WORKDIR/hash-length-chain-$HASH_TARGET.s"
done

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

# A scaled dump must render with memory proportional to the output, not by
# quadratic recursive concatenation. 6000 tiny functions render ~1.5MB of IR
# text; a render that copies the remaining suffix once per element blows far
# past the 6GB address-space cap on this input, so it fails fast while the
# buffered render stays well under the cap. On Windows hosts the runner's
# commit limit bounds a quadratic render the same way.
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
