#!/usr/bin/env sh
set -eu

# verify-spmd-runtime-dispatch.sh - single-binary runtime SIMD dispatch check.
#
# Builds one defdispatch program without --backend-mode, runs it once, and
# checks that the selected variant is the best runnable ISA on this host:
# avx512 when avx512f is runnable, else avx2 when avx2 is runnable, else scalar.
# The fixture encodes both the selected variant and the shared SPMD checksum in
# its exit code, so a wrong selection or wrong SIMD result fails the harness.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "spmd runtime dispatch verification is unsupported on this host" >&2
        exit 1
        ;;
esac

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

if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || {
        echo "missing assembler: as" >&2
        exit 1
    }
    command -v ld >/dev/null 2>&1 || {
        echo "missing linker: ld" >&2
        exit 1
    }
fi

PROGRAM="$ROOT/tests/spmd/runtime_dispatch_select.tl"
WORKDIR="$ROOT/target/spmd-runtime-dispatch-verify/$HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh" | tr -d '\r')

isa_available() {
    printf '%s\n' "$SIMD_ISAS" | grep -qx "$1"
}

expected_variant=scalar
expected_code=42
if isa_available avx512f; then
    expected_variant=avx512
    expected_code=170
elif isa_available avx2; then
    expected_variant=avx2
    expected_code=106
fi

ASM="$WORKDIR/runtime_dispatch_select.s"
COMPILE_OUT="$WORKDIR/compile.out"
COMPILE_ERR="$WORKDIR/compile.err"
if ! "$COMPILER" compile "$PROGRAM" -o "$ASM" > "$COMPILE_OUT" 2> "$COMPILE_ERR"; then
    echo "spmd-runtime-dispatch: compile failed" >&2
    sed 's/^/  /' "$COMPILE_ERR" >&2
    exit 1
fi
if [ -s "$COMPILE_ERR" ]; then
    echo "spmd-runtime-dispatch: compile produced stderr" >&2
    sed 's/^/  /' "$COMPILE_ERR" >&2
    exit 1
fi

assert_asm_contains() {
    if ! grep -F -- "$1" "$ASM" >/dev/null 2>&1; then
        echo "spmd-runtime-dispatch: assembly missing '$1'" >&2
        exit 1
    fi
}

assert_asm_contains "__tl_dispatch_cache_"
assert_asm_contains "dispatch_run"
assert_asm_contains "__tl_dispatch_variant_scalar_"
assert_asm_contains "dispatch_scalar"
assert_asm_contains "__tl_dispatch_variant_avx2_"
assert_asm_contains "dispatch_avx2"
assert_asm_contains "__tl_dispatch_variant_avx512_"
assert_asm_contains "dispatch_avx512"
assert_asm_contains "cpuid"
assert_asm_contains "xgetbv"
assert_asm_contains "call *"

RUN_OUT="$WORKDIR/run.out"
RUN_ERR="$WORKDIR/run.err"
: > "$RUN_OUT"
: > "$RUN_ERR"

if [ "$HOST_OS" = linux ]; then
    OBJ="$WORKDIR/runtime_dispatch_select.o"
    BIN="$WORKDIR/runtime_dispatch_select"
    if ! as "$ASM" -o "$OBJ" >> "$RUN_OUT" 2>> "$RUN_ERR"; then
        echo "spmd-runtime-dispatch: assemble failed" >&2
        sed 's/^/  /' "$RUN_ERR" >&2
        exit 1
    fi
    if ! ld "$OBJ" -o "$BIN" -static -e "$(linux_entry_symbol_for_asm "$ASM")" \
        >> "$RUN_OUT" 2>> "$RUN_ERR"; then
        echo "spmd-runtime-dispatch: link failed" >&2
        sed 's/^/  /' "$RUN_ERR" >&2
        exit 1
    fi
    set +e
    "$BIN" >> "$RUN_OUT" 2>> "$RUN_ERR"
    run_code=$?
    set -e
else
    set +e
    "$COMPILER" run "$PROGRAM" > "$RUN_OUT" 2> "$RUN_ERR"
    run_code=$?
    set -e
fi

if [ -s "$RUN_ERR" ]; then
    echo "spmd-runtime-dispatch: run produced stderr" >&2
    sed 's/^/  /' "$RUN_ERR" >&2
    exit 1
fi

if [ "$run_code" != "$expected_code" ]; then
    echo "spmd-runtime-dispatch: expected $expected_variant exit $expected_code, got $run_code" >&2
    echo "  runnable isas: $(printf '%s' "$SIMD_ISAS" | tr '\n' ' ')" >&2
    exit 1
fi

echo "spmd runtime dispatch verification passed (host=$HOST_OS, selected=$expected_variant, isas='$(printf '%s' "$SIMD_ISAS" | tr '\n' ' ')')"
