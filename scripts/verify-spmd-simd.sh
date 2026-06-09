#!/usr/bin/env sh
set -eu

# verify-spmd-simd.sh - scalar-vs-SIMD execution-comparison harness (#1149).
#
# Builds each SPMD corpus program at `scalar`, `avx2`, and `avx512`, runs every
# available variant, and asserts they produce IDENTICAL exit codes (with empty
# stderr). Staged unsupported mode/program pairs are compiled and must fail with
# an explicit diagnostic. `scalar` is always the reference; a SIMD mode is only
# run when the host CPU can actually execute that ISA (via
# scripts/detect-simd-isa.sh), and is skipped cleanly otherwise. This is the
# comparison the SPMD acceptance criteria need (#1011-#1014): proving SIMD
# lowering -- including the masked `foreach` tail (#1014) and `spmd-reduce`
# folds -- matches scalar semantics, not merely that a mode runs on a trivial
# program (cf. #1148, full-width only).
#
# The corpus deliberately includes non-power-of-two lengths (the SIMD tail),
# foreach lanes across i64/i32/f64/f32, and reductions across the scalar
# supported operator/type surface.
#
# Usage:
#   scripts/verify-spmd-simd.sh
#   TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-simd.sh
#
# On the fleet's AVX-512 Windows box (the only AVX-512 machine), run from Git
# Bash / MSYS with clang on PATH; detect-simd-isa.sh reports `avx2`+`avx512f`
# there, so all three modes are exercised. A generic windows-latest or Linux CI
# runner without AVX-512 runs scalar+avx2 and skips avx512 cleanly.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "spmd-simd verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # No-Rust fallback for local development: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

# Windows uses the host-default native toolchain (clang/lld-link); Linux uses
# the default GNU pipeline.
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

# Runnable SIMD ISAs on THIS host (CPUID feature bit + OS XSAVE), not host OS.
SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")

WORKDIR="$ROOT/target/spmd-simd-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# SPMD corpus: each program's exit code is computed by a SIMD-lowered `foreach`
# or `spmd-reduce`, so a wrong SIMD result (especially in the tail) changes it.
# Keep this list in sync with tests/spmd/README.md.
spmd_corpus() {
    cat <<'EOF'
tests/spmd/tail_i64_add.tl
tests/spmd/tail_i32_add.tl
tests/spmd/masked_if_i64.tl
tests/spmd/masked_if_offset_i64.tl
tests/integration/spmd_foreach.tl
tests/integration/spmd_reduce_scalar.tl
EOF
}

isa_available() {
    printf '%s\n' "$SIMD_ISAS" | grep -qx "$1"
}

spmd_mode_expected_compile_diagnostic() {
    _prog=$1
    _mode=$2
    case "$_prog:$_mode" in
        tests/spmd/masked_if_i64.tl:avx2)
            printf '%s\n' "lower: SPMD masked if is not supported in AVX2 backend mode; use scalar or avx512"
            ;;
        tests/spmd/masked_if_offset_i64.tl:avx2)
            printf '%s\n' "lower: SPMD masked if is not supported in AVX2 backend mode; use scalar or avx512"
            ;;
        *) return 1 ;;
    esac
}

CORPUS="$WORKDIR/corpus.txt"
FAILURES="$WORKDIR/failures.txt"
spmd_corpus > "$CORPUS"
: > "$FAILURES"

# Build+run $1 at backend mode $2; sets `mode_code` to the exit status and
# writes stdout/stderr to <tag>.<mode>.{out,err} under WORKDIR.
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
        if ! ld "$_obj" -o "$_bin" -static \
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
        "$COMPILER" run "$_prog" --backend-mode "$_mode" \
            > "$mode_out" 2> "$mode_err"
        mode_code=$?
        set -e
    fi
}

# Compile $1 at backend mode $2; sets `mode_code` to the compiler exit status
# and writes stdout/stderr to <tag>.<mode>.compile.{out,err} under WORKDIR.
compile_spmd_mode() {
    _prog=$1
    _mode=$2
    _tag=$(printf '%s' "$_prog" | sed 's#[/.]#_#g')
    mode_out="$WORKDIR/$_tag.$_mode.compile.out"
    mode_err="$WORKDIR/$_tag.$_mode.compile.err"
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    : > "$mode_out"
    : > "$mode_err"

    set +e
    "$COMPILER" compile "$_prog" --backend-mode "$_mode" -o "$_asm" \
        > "$mode_out" 2> "$mode_err"
    mode_code=$?
    set -e
}

while IFS= read -r prog; do
    [ -n "$prog" ] || continue
    if [ ! -f "$prog" ]; then
        echo "spmd-simd: corpus program not found: $prog" >&2
        echo "$prog (missing)" >> "$FAILURES"
        continue
    fi

    # scalar is the always-run reference.
    run_spmd_mode "$prog" scalar
    scalar_code=$mode_code
    if [ -s "$mode_err" ]; then
        echo "[spmd-simd] $prog scalar build/run error:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "$prog scalar" >> "$FAILURES"
        continue
    fi
    echo "[spmd-simd] $prog scalar -> $scalar_code"

    for pair in "avx2 avx2" "avx512 avx512f"; do
        mode=${pair%% *}
        isa=${pair##* }
        if expected_diag=$(spmd_mode_expected_compile_diagnostic "$prog" "$mode"); then
            compile_spmd_mode "$prog" "$mode"
            if [ "$mode_code" = 0 ]; then
                echo "[spmd-simd]   $mode unexpectedly compiled; wanted diagnostic:" >&2
                echo "    $expected_diag" >&2
                echo "$prog $mode (missing diagnostic)" >> "$FAILURES"
            elif ! grep -F -- "$expected_diag" "$mode_err" > /dev/null; then
                echo "[spmd-simd]   $mode diagnostic mismatch:" >&2
                sed 's/^/    /' "$mode_err" >&2
                echo "$prog $mode (wrong diagnostic)" >> "$FAILURES"
            else
                echo "[spmd-simd]   $mode -> expected diagnostic OK"
            fi
            continue
        fi
        if ! isa_available "$isa"; then
            echo "[spmd-simd]   skip $mode ($isa not runnable on this $HOST_OS host)"
            continue
        fi
        run_spmd_mode "$prog" "$mode"
        if [ -s "$mode_err" ]; then
            echo "[spmd-simd]   $mode build/run error:" >&2
            sed 's/^/    /' "$mode_err" >&2
            echo "$prog $mode" >> "$FAILURES"
        elif [ "$mode_code" != "$scalar_code" ]; then
            echo "[spmd-simd]   $mode -> $mode_code MISMATCH (scalar=$scalar_code)" >&2
            echo "$prog $mode ($mode_code vs scalar $scalar_code)" >> "$FAILURES"
        else
            echo "[spmd-simd]   $mode -> $mode_code OK"
        fi
    done
done < "$CORPUS"

if [ -s "$FAILURES" ]; then
    echo "spmd-simd verification FAILED:" >&2
    sed 's/^/  /' "$FAILURES" >&2
    exit 1
fi

echo "spmd-simd verification passed (host=$HOST_OS, isas='$(printf '%s' "$SIMD_ISAS" | tr '\n' ' ')')"
