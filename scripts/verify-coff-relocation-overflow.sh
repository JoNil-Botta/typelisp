#!/usr/bin/env sh
set -eu

# Verify that LLVM treats TypeLisp's extended relocation-count sentinel as
# metadata and reports exactly the semantic COFF relocations after it.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

command -v llvm-readobj >/dev/null 2>&1 || {
    echo "COFF relocation-overflow verification requires llvm-readobj" >&2
    exit 1
}
command -v llvm-objdump >/dev/null 2>&1 || {
    echo "COFF relocation-overflow verification requires llvm-objdump" >&2
    exit 1
}

WORKDIR="$ROOT/target/coff-relocation-overflow-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

OBJECT="$WORKDIR/boundary.obj"
"$COMPILER" run src/tests/compiler_object_coff_overflow_fixture.tl \
    --cfg test \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    -- "$OBJECT"

llvm-readobj --sections --relocations "$OBJECT" > "$WORKDIR/llvm-readobj.txt"
llvm-objdump -r "$OBJECT" > "$WORKDIR/llvm-objdump.txt"

EXPECTED=131071
READOBJ_COUNT=$(grep -c 'IMAGE_REL_AMD64_ADDR64' "$WORKDIR/llvm-readobj.txt" || true)
OBJDUMP_COUNT=$(grep -c 'IMAGE_REL_AMD64_ADDR64' "$WORKDIR/llvm-objdump.txt" || true)
OVERFLOW_SECTION_COUNT=$(grep -c 'IMAGE_SCN_LNK_NRELOC_OVFL' "$WORKDIR/llvm-readobj.txt" || true)

if [ "$READOBJ_COUNT" -ne "$EXPECTED" ]; then
    echo "llvm-readobj reported $READOBJ_COUNT relocations; expected $EXPECTED" >&2
    exit 1
fi
if [ "$OBJDUMP_COUNT" -ne "$EXPECTED" ]; then
    echo "llvm-objdump reported $OBJDUMP_COUNT relocations; expected $EXPECTED" >&2
    exit 1
fi
if [ "$OVERFLOW_SECTION_COUNT" -ne 2 ]; then
    echo "llvm-readobj reported $OVERFLOW_SECTION_COUNT overflow sections; expected 2" >&2
    exit 1
fi

echo "COFF relocation-overflow verification passed: $EXPECTED semantic relocations"
