#!/usr/bin/env sh
set -eu

# An unused depth-40 binary inline type must stay a shared declaration graph
# through admission, move classification and lowering, at every opt level.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-gate.sh"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
[ -x "$COMPILER" ] || fail "inline aggregate compiler is unavailable: $COMPILER"
mkdir -p "$ROOT/target/exp/inline-aggregate-scaling"
WORKDIR=$(mktemp -d "$ROOT/target/exp/inline-aggregate-scaling/run.XXXXXX")
. "$ROOT/scripts/lib-fixture-inventory.sh"
fixture_inventory_load tests/inline-aggregate-scaling.fixtures.cases "$WORKDIR/fixtures.tsv"
while IFS="$(printf '\t')" read -r label source; do
    scripts/run-memory-bounded.sh --limit-mib 512 --timeout-seconds 120 \
        --report "$WORKDIR/$label-check.memory" -- env -u BASH_ENV \
        "$COMPILER" check "$source" $(native_target_cfg_args) \
        --stdlib-root stdlib --stdlib-root src > "$WORKDIR/$label-check.log" 2>&1 || {
        cat "$WORKDIR/$label-check.log" >&2
        fail "inline aggregate check exceeded its resource bound: $label"
    }
    for opt in 0 1 2; do
        scripts/run-memory-bounded.sh --limit-mib 512 --timeout-seconds 120 \
            --report "$WORKDIR/$label-opt$opt.memory" -- env -u BASH_ENV \
            "$COMPILER" compile "$source" --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src \
            --opt-level "$opt" -o "$WORKDIR/$label-opt$opt.s" \
            > "$WORKDIR/$label-opt$opt.log" 2>&1 || {
            cat "$WORKDIR/$label-opt$opt.log" >&2
            fail "inline aggregate compile exceeded its resource bound: $label opt$opt"
        }
        [ -s "$WORKDIR/$label-opt$opt.s" ] || fail "empty inline aggregate assembly"
    done
done < "$WORKDIR/fixtures.tsv"
echo "[inline-aggregate-scaling] depth 40 check and opt0/1/2 compile passed: $WORKDIR"
