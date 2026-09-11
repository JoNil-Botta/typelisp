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

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "COFF relocation-overflow verification is unsupported on this host" >&2
        exit 1
        ;;
esac

WORKDIR="$ROOT/target/coff-relocation-overflow-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

OBJECT="$WORKDIR/boundary.obj"
"$COMPILER" run src/tests/compiler_object_coff_overflow_fixture.tl \
    --cfg test \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    -- "$OBJECT"

EXPECTED=131071

verify_llvm() {
    llvm-readobj --sections --relocations "$OBJECT" > "$WORKDIR/llvm-readobj.txt"
    llvm-objdump -r "$OBJECT" > "$WORKDIR/llvm-objdump.txt"

    _readobj_count=$(grep -c 'IMAGE_REL_AMD64_ADDR64' "$WORKDIR/llvm-readobj.txt" || true)
    _objdump_count=$(grep -c 'IMAGE_REL_AMD64_ADDR64' "$WORKDIR/llvm-objdump.txt" || true)
    _overflow_section_count=$(grep -c 'IMAGE_SCN_LNK_NRELOC_OVFL' "$WORKDIR/llvm-readobj.txt" || true)

    if [ "$_readobj_count" -ne "$EXPECTED" ]; then
        echo "llvm-readobj reported $_readobj_count relocations; expected $EXPECTED" >&2
        return 1
    fi
    if [ "$_objdump_count" -ne "$EXPECTED" ]; then
        echo "llvm-objdump reported $_objdump_count relocations; expected $EXPECTED" >&2
        return 1
    fi
    if [ "$_overflow_section_count" -ne 2 ]; then
        echo "llvm-readobj reported $_overflow_section_count overflow sections; expected 2" >&2
        return 1
    fi
    echo "COFF relocation-overflow LLVM verification passed: $EXPECTED semantic relocations"
}

verify_gnu_objdump() {
    command -v objdump >/dev/null 2>&1 || {
        echo "COFF relocation-overflow verification requires GNU objdump on Linux" >&2
        return 1
    }
    objdump -r "$OBJECT" > "$WORKDIR/gnu-objdump.txt"
    _objdump_count=$(grep -c 'IMAGE_REL_AMD64_ADDR64' "$WORKDIR/gnu-objdump.txt" || true)
    if [ "$_objdump_count" -ne "$EXPECTED" ]; then
        echo "GNU objdump reported $_objdump_count relocations; expected $EXPECTED" >&2
        return 1
    fi
    echo "COFF relocation-overflow GNU verification passed: $EXPECTED semantic relocations"
}

ORACLE=${TYPELISP_COFF_RELOCATION_ORACLE:-auto}
case "$ORACLE" in
    llvm)
        command -v llvm-readobj >/dev/null 2>&1 \
            && command -v llvm-objdump >/dev/null 2>&1 \
            || {
                echo "COFF relocation-overflow LLVM oracle requires llvm-readobj and llvm-objdump" >&2
                exit 1
            }
        verify_llvm
        ;;
    gnu)
        [ "$HOST_OS" = linux ] || {
            echo "COFF relocation-overflow GNU oracle is Linux-only" >&2
            exit 1
        }
        verify_gnu_objdump
        ;;
    auto)
        if command -v llvm-readobj >/dev/null 2>&1 \
            && command -v llvm-objdump >/dev/null 2>&1; then
            verify_llvm
        elif [ "$HOST_OS" = linux ]; then
            verify_gnu_objdump
        else
            echo "COFF relocation-overflow verification requires llvm-readobj and llvm-objdump on Windows" >&2
            exit 1
        fi
        ;;
    *)
        echo "unknown TYPELISP_COFF_RELOCATION_ORACLE: $ORACLE" >&2
        exit 1
        ;;
esac
