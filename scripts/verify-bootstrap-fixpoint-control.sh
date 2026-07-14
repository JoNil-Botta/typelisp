#!/usr/bin/env sh
set -eu

# Fast control-flow coverage for the adaptive bootstrap fixpoint gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-bootstrap-fixpoint-control.sh"

WORKDIR="$ROOT/target/bootstrap-fixpoint-control-test"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

STAGE2_ASM="$WORKDIR/stage2.s"
STAGE3_ASM="$WORKDIR/stage3.s"
STAGE3_BIN="$WORKDIR/stage3"
STAGE4_ASM="$WORKDIR/stage4.s"
STAGE4_BIN="$WORKDIR/stage4"
STAGE4_SOURCE="$WORKDIR/stage4-source.s"
STAGE4_BUILD_MARKER="$WORKDIR/stage4-built"

bootstrap_build_stage4() {
    cp "$STAGE4_SOURCE" "$STAGE4_ASM"
    : > "$STAGE4_BIN"
    : > "$STAGE4_BUILD_MARKER"
}

assert_equal() {
    expected=$1
    actual=$2
    label=$3
    if [ "$actual" != "$expected" ]; then
        echo "$label: expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

printf 'converged\n' > "$STAGE2_ASM"
cp "$STAGE2_ASM" "$STAGE3_ASM"
: > "$STAGE3_BIN"
printf 'must not be built\n' > "$STAGE4_SOURCE"
bootstrap_resolve_fixpoint
assert_equal stage3 "$BOOTSTRAP_COMPILER_STAGE" "early fixpoint stage"
assert_equal "$STAGE3_BIN" "$BOOTSTRAP_COMPILER_BIN" "early fixpoint compiler"
if [ -e "$STAGE4_BUILD_MARKER" ] || [ -e "$STAGE4_ASM" ]; then
    echo "early fixpoint unexpectedly built stage4" >&2
    exit 1
fi

printf 'not converged\n' > "$STAGE2_ASM"
printf 'converged\n' > "$STAGE3_ASM"
cp "$STAGE3_ASM" "$STAGE4_SOURCE"
bootstrap_resolve_fixpoint
assert_equal stage4 "$BOOTSTRAP_COMPILER_STAGE" "fallback fixpoint stage"
assert_equal "$STAGE4_BIN" "$BOOTSTRAP_COMPILER_BIN" "fallback fixpoint compiler"
if [ ! -e "$STAGE4_BUILD_MARKER" ] || ! cmp -s "$STAGE3_ASM" "$STAGE4_ASM"; then
    echo "fallback fixpoint did not build and prove stage4" >&2
    exit 1
fi

echo "bootstrap adaptive fixpoint control-flow tests passed"
