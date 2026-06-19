#!/usr/bin/env sh
set -eu

# Backend-observable SPMD lane identity verification (#2761).
#
# `(program-index)` and `(program-count)` intentionally observe the current
# backend gang width, so these fixtures stay separate from the scalar-vs-SIMD
# same-exit corpus.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "spmd lane identity verification is unsupported on this host" >&2
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
WORKDIR="$ROOT/target/spmd-lane-identity-verify"
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
        echo "[spmd-lane-identity] $_prog $_mode stderr:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "$_prog $_mode stderr" >> "$FAILURES"
    elif [ "$mode_code" != "$_want" ]; then
        echo "[spmd-lane-identity] $_prog $_mode -> $mode_code, want $_want" >&2
        echo "$_prog $_mode code $mode_code want $_want" >> "$FAILURES"
    else
        echo "[spmd-lane-identity] $_prog $_mode -> $mode_code OK"
    fi
}

expect_exit tests/spmd/lane_identity_i64.tl scalar 130
expect_exit tests/spmd/lane_identity_reduce_i64.tl scalar 13

if isa_available avx2; then
    expect_exit tests/spmd/lane_identity_i64.tl avx2 26
    expect_exit tests/spmd/lane_identity_reduce_i64.tl avx2 70
else
    echo "[spmd-lane-identity] skip avx2 (not runnable on this $HOST_OS host)"
fi

if isa_available avx512bw; then
    expect_exit tests/spmd/lane_identity_i64.tl avx512 54
    expect_exit tests/spmd/lane_identity_reduce_i64.tl avx512 142
else
    echo "[spmd-lane-identity] skip avx512 (avx512bw not runnable on this $HOST_OS host)"
fi

if [ -s "$FAILURES" ]; then
    echo "spmd lane identity verification FAILED:" >&2
    sed 's/^/  /' "$FAILURES" >&2
    exit 1
fi

echo "spmd lane identity verification passed (host=$HOST_OS, isas='$(printf '%s' "$SIMD_ISAS" | tr '\n' ' ')')"
