#!/usr/bin/env sh
set -eu

# Backend-observable SPMD broadcast verification (#2883).
#
# Unlike verify-spmd-simd.sh, these fixtures intentionally have different
# scalar/AVX2/AVX-512 results because `spmd-broadcast` observes the current gang
# width and selected source lane.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "spmd-broadcast verification is unsupported on this host" >&2
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

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")
WORKDIR="$ROOT/target/spmd-broadcast-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
FAILURES="$WORKDIR/failures.txt"
: > "$FAILURES"

isa_available() {
    printf '%s\n' "$SIMD_ISAS" | grep -qx "$1"
}

run_spmd_mode() {
    _prog=$1
    _mode=$2
    _tag=$(printf '%s' "$_prog" | sed 's#[/.]#_#g')
    mode_out="$WORKDIR/$_tag.$_mode.out"
    mode_err="$WORKDIR/$_tag.$_mode.err"
    : > "$mode_out"
    : > "$mode_err"

    if [ "$HOST_OS" = linux ]; then
        _asm="$WORKDIR/$_tag.$_mode.s"
        _obj="$WORKDIR/$_tag.$_mode.o"
        _bin="$WORKDIR/$_tag.$_mode"
        if ! "$COMPILER" compile "$_prog" --backend-mode "$_mode" -o "$_asm" > "$mode_out" 2> "$mode_err"; then
            mode_code=1
            return
        fi
        if ! as "$_asm" -o "$_obj" >> "$mode_out" 2>> "$mode_err"; then
            mode_code=1
            return
        fi
        if ! ld "$_obj" -o "$_bin" -static -e "$(linux_entry_symbol_for_asm "$_asm")" \
            >> "$mode_out" 2>> "$mode_err"; then
            mode_code=1
            return
        fi
        set +e
        "$_bin" >> "$mode_out" 2>> "$mode_err"
        mode_code=$?
        set -e
    else
        set +e
        "$COMPILER" run "$_prog" --backend-mode "$_mode" > "$mode_out" 2> "$mode_err"
        mode_code=$?
        set -e
    fi
}

expect_exit() {
    _prog=$1
    _mode=$2
    _want=$3
    run_spmd_mode "$_prog" "$_mode"
    if [ -s "$mode_err" ]; then
        echo "[spmd-broadcast] $_prog $_mode stderr:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "$_prog $_mode stderr" >> "$FAILURES"
    elif [ "$mode_code" != "$_want" ]; then
        echo "[spmd-broadcast] $_prog $_mode -> $mode_code, want $_want" >&2
        echo "$_prog $_mode code $mode_code want $_want" >> "$FAILURES"
    else
        echo "[spmd-broadcast] $_prog $_mode -> $mode_code OK"
    fi
}

expect_trap() {
    _prog=$1
    _mode=$2
    run_spmd_mode "$_prog" "$_mode"
    if [ "$mode_code" = 0 ]; then
        echo "[spmd-broadcast] $_prog $_mode unexpectedly exited 0" >&2
        echo "$_prog $_mode missing trap" >> "$FAILURES"
    elif ! grep -F -- "tl: array index out of bounds" "$mode_err" >/dev/null; then
        echo "[spmd-broadcast] $_prog $_mode trap diagnostic mismatch:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "$_prog $_mode wrong trap" >> "$FAILURES"
    else
        echo "[spmd-broadcast] $_prog $_mode -> trap OK"
    fi
}

expect_exit tests/spmd/broadcast_lane0_i64.tl scalar 105
expect_trap tests/spmd/broadcast_lane1_i64.tl scalar

if isa_available avx2; then
    expect_exit tests/spmd/broadcast_lane0_i64.tl avx2 86
    expect_exit tests/spmd/broadcast_lane1_i64.tl avx2 32
else
    echo "[spmd-broadcast] skip avx2 (not runnable on this $HOST_OS host)"
fi

if isa_available avx512f; then
    expect_exit tests/spmd/broadcast_lane0_i64.tl avx512 62
    expect_exit tests/spmd/broadcast_lane1_i64.tl avx512 16
else
    echo "[spmd-broadcast] skip avx512 (avx512f not runnable on this $HOST_OS host)"
fi

if [ -s "$FAILURES" ]; then
    echo "spmd-broadcast verification FAILED:" >&2
    sed 's/^/  /' "$FAILURES" >&2
    exit 1
fi

echo "spmd-broadcast verification passed (host=$HOST_OS, isas='$(printf '%s' "$SIMD_ISAS" | tr '\n' ' ')')"
