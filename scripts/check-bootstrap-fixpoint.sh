#!/usr/bin/env sh
set -eu

# check-bootstrap-fixpoint.sh - selfhost compiler stage2/stage3 fixpoint gate.
#
# The Rust stage0 compiler builds the TypeLisp selfhost compiler to stage1.
# stage1 then compiles the same selfhost source to stage2.s, stage2 repeats that
# compile to stage3.s, and the selfhost-emitted stage2/stage3 assembly must be
# byte-identical.
#
# refs #47.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "bootstrap fixpoint check is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

command -v as >/dev/null 2>&1 || {
    echo "bootstrap fixpoint check requires 'as'" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "bootstrap fixpoint check requires 'ld'" >&2
    exit 1
}

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [typelisp-binary]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    COMPILER=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/bootstrap-fixpoint"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.o"
STAGE1_BIN="$WORKDIR/stage1"
STAGE2_ASM="$WORKDIR/stage2.s"
STAGE2_OBJ="$WORKDIR/stage2.o"
STAGE2_BIN="$WORKDIR/stage2"
STAGE3_ASM="$WORKDIR/stage3.s"

echo "[bootstrap] stage0 -> stage1.s"
"$COMPILER" compile selfhost/compile.tl -o "$STAGE1_ASM"

echo "[bootstrap] link stage1"
as "$STAGE1_ASM" -o "$STAGE1_OBJ"
ld "$STAGE1_OBJ" -o "$STAGE1_BIN"

echo "[bootstrap] stage1 -> stage2.s"
"$STAGE1_BIN" selfhost/compile.tl -o "$STAGE2_ASM"

echo "[bootstrap] link stage2"
as "$STAGE2_ASM" -o "$STAGE2_OBJ"
ld "$STAGE2_OBJ" -o "$STAGE2_BIN"

echo "[bootstrap] stage2 -> stage3.s"
"$STAGE2_BIN" selfhost/compile.tl -o "$STAGE3_ASM"

echo "[bootstrap] compare stage2.s and stage3.s"
if ! cmp -s "$STAGE2_ASM" "$STAGE3_ASM"; then
    echo "bootstrap fixpoint mismatch: stage2.s and stage3.s differ" >&2
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$STAGE2_ASM" "$STAGE3_ASM" >&2 || true
    fi
    wc -l "$STAGE2_ASM" "$STAGE3_ASM" >&2 || true
    if command -v diff >/dev/null 2>&1; then
        diff -u "$STAGE2_ASM" "$STAGE3_ASM" | sed -n '1,200p' >&2 || true
    else
        cmp -l "$STAGE2_ASM" "$STAGE3_ASM" | sed -n '1,80p' >&2 || true
    fi
    exit 1
fi

wc -l "$STAGE2_ASM" "$STAGE3_ASM"
echo "bootstrap fixpoint check passed"
