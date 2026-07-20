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
# foreach lanes across i64/i32/i8/u8/f64/f32, and reductions across the scalar
# supported operator/type surface.
#
# Usage:
#   scripts/verify-spmd-simd.sh
#   TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-simd.sh
#
# On the fleet's AVX-512 Windows box (the only AVX-512 machine), run from Git
# Bash / MSYS with clang on PATH; detect-simd-isa.sh reports `avx2`+`avx512`
# there, so all three modes are exercised. A generic windows-latest or Linux CI
# runner without AVX-512 runs scalar+avx2 and skips avx512 cleanly.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

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
    # Local-development fallback: fetch the published
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
tests/spmd/foreach_bound_extremes.tl
tests/spmd/uniform_zip_i64.tl
tests/spmd/multi_output_i64.tl
tests/spmd/vector_slice_surface_i64.tl
tests/spmd/inline_helper_i64.tl
tests/spmd/inline_helper_shadow_i64.tl
tests/spmd/inline_helper_f64.tl
tests/spmd/private_helper_i64.tl
tests/spmd/private_helper_f64.tl
tests/spmd/private_helper_bool.tl
tests/spmd/private_helper_masked_load.tl
tests/spmd/private_helper_store.tl
tests/spmd/private_helper_effects.tl
tests/spmd/i8_mul_reject.tl
tests/spmd/masked_if_i64.tl
tests/spmd/masked_if_offset_i64.tl
tests/spmd/masked_if_index_value_i64.tl
tests/spmd/masked_if_index_mod_i64.tl
tests/spmd/masked_if_value_i64.tl
tests/spmd/masked_if_bitand_value_i64.tl
tests/spmd/masked_if_bitwise_value_types.tl
tests/spmd/masked_if_shift_value_types.tl
tests/spmd/masked_if_shift_inactive.tl
tests/spmd/masked_if_shift_i16_reject.tl
tests/spmd/masked_if_value_types.tl
tests/spmd/masked_if_nested_i64.tl
tests/spmd/masked_if_i16_u16.tl
tests/spmd/inline_helper_masked_if_i64.tl
tests/spmd/masked_if_match_i64.tl
tests/spmd/varying_while_i64.tl
tests/spmd/varying_while_f32_i32.tl
tests/spmd/masked_if_varying_while_i64.tl
tests/spmd/varying_while_nested_i64.tl
tests/spmd/varying_match_i64.tl
tests/spmd/varying_match_enum_payload.tl
tests/spmd/bool_lanes.tl
tests/integration/spmd_foreach.tl
tests/integration/spmd_gather_read.tl
tests/integration/spmd_reduce_scalar.tl
tests/integration/spmd_scan_scalar.tl
tests/integration/spmd_shuffle_simd.tl
tests/integration/spmd_shuffle_types.tl
tests/integration/spmd_shuffle_reduce.tl
benchmarks/ispc/perfbench_gathers/bench.tl
EOF
}

isa_available() {
    printf '%s\n' "$SIMD_ISAS" | grep -qx "$1"
}

spmd_mode_expected_compile_diagnostic() {
    _prog=$1
    _mode=$2
    case "$_prog:$_mode" in
        tests/spmd/inline_helper_shadow_i64.tl:avx2 | tests/spmd/inline_helper_shadow_i64.tl:avx512)
            printf '%s\n' "lower: SPMD foreach does not match a SIMD lowering pattern for this backend mode; use scalar or a contiguous map/zip body with supported array and uniform operands"
            ;;
        tests/spmd/i8_mul_reject.tl:avx2 | tests/spmd/i8_mul_reject.tl:avx512)
            printf '%s\n' "lower: SPMD foreach SIMD lowering does not support 8-bit lane multiplication; use scalar or widen before multiplying"
            ;;
        tests/spmd/masked_if_shift_i16_reject.tl:avx2)
            printf '%s\n' "lower: SPMD masked if does not support masked shift 'shr' for lane type i16 in AVX2 backend mode; supported lane types are i32, u32, i64, and u64"
            ;;
        tests/spmd/masked_if_shift_i16_reject.tl:avx512)
            printf '%s\n' "lower: SPMD masked if does not support masked shift 'shr' for lane type i16 in AVX-512 backend mode; supported lane types are i32, u32, i64, and u64"
            ;;
        tests/spmd/private_helper_i64.tl:avx2 | tests/spmd/private_helper_f64.tl:avx2 | tests/spmd/private_helper_bool.tl:avx2 | tests/spmd/private_helper_masked_load.tl:avx2 | tests/spmd/private_helper_store.tl:avx2 | tests/spmd/private_helper_effects.tl:avx2)
            printf '%s\n' "lower: out-of-line varying SPMD calls are not supported in AVX2 backend mode; use scalar or avx512"
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
    _opt_args=
    if [ -n "${3:-}" ]; then
        _opt_args="--opt-level $3"
    fi
    _tag=$(printf '%s' "$_prog" | sed 's#[/.]#_#g')
    mode_out="$WORKDIR/$_tag.$_mode.compile.out"
    mode_err="$WORKDIR/$_tag.$_mode.compile.err"
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    : > "$mode_out"
    : > "$mode_err"

    set +e
    "$COMPILER" compile "$_prog" --backend-mode "$_mode" $_opt_args -o "$_asm" \
        > "$mode_out" 2> "$mode_err"
    mode_code=$?
    set -e
}

verify_gather_opcodes() {
    _mode=$1
    compile_spmd_mode tests/integration/spmd_gather_read.tl "$_mode"
    _tag=tests_integration_spmd_gather_read_tl
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] gather opcode compile failed in $_mode:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/integration/spmd_gather_read.tl $_mode (opcode compile)" >> "$FAILURES"
        return
    fi
    for opcode in vpgatherqd vpgatherqq vgatherqps vgatherqpd; do
        if ! grep -F -- "$opcode" "$_asm" > /dev/null; then
            echo "[spmd-simd] gather $_mode assembly missing $opcode" >&2
            echo "tests/integration/spmd_gather_read.tl $_mode (missing $opcode)" >> "$FAILURES"
        fi
    done
    if ! grep -F -- "vpaddq" "$_asm" > /dev/null; then
        echo "[spmd-simd] computed gather $_mode assembly missing lane-offset vpaddq" >&2
        echo "tests/integration/spmd_gather_read.tl $_mode (missing lane-offset vpaddq)" >> "$FAILURES"
    fi
}

verify_gather_reduce_opcodes() {
    _mode=$1
    compile_spmd_mode benchmarks/ispc/perfbench_gathers/bench.tl "$_mode"
    _tag=benchmarks_ispc_perfbench_gathers_bench_tl
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] gather-reduce opcode compile failed in $_mode:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "benchmarks/ispc/perfbench_gathers/bench.tl $_mode (opcode compile)" >> "$FAILURES"
        return
    fi
    for opcode in vgatherqps vaddps; do
        if ! grep -F -- "$opcode" "$_asm" > /dev/null; then
            echo "[spmd-simd] gather-reduce $_mode assembly missing $opcode" >&2
            echo "benchmarks/ispc/perfbench_gathers/bench.tl $_mode (missing $opcode)" >> "$FAILURES"
        fi
    done
}

verify_shuffle_opcodes() {
    _mode=$1
    compile_spmd_mode tests/integration/spmd_shuffle_simd.tl "$_mode"
    _tag=tests_integration_spmd_shuffle_simd_tl
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] shuffle opcode compile failed in $_mode:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/integration/spmd_shuffle_simd.tl $_mode (opcode compile)" >> "$FAILURES"
        return
    fi
    if ! grep -F -- "vpermd" "$_asm" > /dev/null; then
        echo "[spmd-simd] shuffle $_mode assembly missing vpermd" >&2
        echo "tests/integration/spmd_shuffle_simd.tl $_mode (missing vpermd)" >> "$FAILURES"
    fi
    if [ "$_mode" = avx512 ] && ! grep -F -- "vpermq" "$_asm" > /dev/null; then
        echo "[spmd-simd] shuffle avx512 assembly missing vpermq" >&2
        echo "tests/integration/spmd_shuffle_simd.tl avx512 (missing vpermq)" >> "$FAILURES"
    fi
    if [ "$_mode" = avx2 ] && grep -E -- '%zmm[0-9]+|%k[0-7]' "$_asm" > /dev/null; then
        echo "[spmd-simd] shuffle AVX2 assembly uses AVX-512 registers" >&2
        echo "tests/integration/spmd_shuffle_simd.tl avx2 (AVX-512 register)" >> "$FAILURES"
    fi
}

verify_reduce_accumulator_shape() {
    _mode=$1
    compile_spmd_mode tests/integration/spmd_reduce_scalar.tl "$_mode" 2
    _tag=tests_integration_spmd_reduce_scalar_tl
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    _func="$WORKDIR/$_tag.$_mode.reduce-sum.s"
    _gang="$WORKDIR/$_tag.$_mode.reduce-sum-gang.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] reduce-accumulator shape compile failed in $_mode:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/integration/spmd_reduce_scalar.tl $_mode (accumulator compile)" >> "$FAILURES"
        return
    fi
    sed -n '/^_tl_spmd_reduce_scalar_reduce_sum:/,/^$/p' "$_asm" > "$_func"
    sed -n '/spmd_reduce_avx2_body/,/spmd_reduce_tail/p' "$_func" > "$_gang"
    _gang_adds=$(grep -c -F -- "vpaddq" "$_gang" || true)
    if [ "$_gang_adds" != 1 ]; then
        echo "[spmd-simd] reduce-accumulator $_mode gang has $_gang_adds vpaddq instructions; wanted 1" >&2
        echo "tests/integration/spmd_reduce_scalar.tl $_mode (gang vpaddq count)" >> "$FAILURES"
    fi
    if grep -E -- 'vextract|vpsrldq' "$_gang" > /dev/null; then
        echo "[spmd-simd] reduce-accumulator $_mode gang still performs a horizontal reduction" >&2
        echo "tests/integration/spmd_reduce_scalar.tl $_mode (horizontal reduce in gang)" >> "$FAILURES"
    fi
    if ! grep -E -- 'vextract|vpsrldq' "$_func" > /dev/null; then
        echo "[spmd-simd] reduce-accumulator $_mode function lacks the post-loop horizontal reduction" >&2
        echo "tests/integration/spmd_reduce_scalar.tl $_mode (missing post-loop horizontal reduce)" >> "$FAILURES"
    fi
}

verify_avx2_scan_prefix_shape() {
    compile_spmd_mode tests/integration/spmd_scan_scalar.tl avx2 2
    _tag=tests_integration_spmd_scan_scalar_tl
    _asm="$WORKDIR/$_tag.avx2.compile.s"
    _func="$WORKDIR/$_tag.avx2.scan-sum.s"
    _gang="$WORKDIR/$_tag.avx2.scan-sum-gang.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] scan-prefix AVX2 shape compile failed:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/integration/spmd_scan_scalar.tl avx2 (prefix compile)" >> "$FAILURES"
        return
    fi
    sed -n '/^_tl_spmd_scan_scalar_scan_sum_i64:/,/^$/p' "$_asm" > "$_func"
    sed -n '/spmd_scan_avx2_body/,/spmd_scan_tail_header/p' "$_func" > "$_gang"
    for shape in \
        spmd_scan_avx2_body \
        vpslldq \
        vperm2i128 \
        vpaddq \
        vpaddd \
        vpminsd \
        vpmaxsd \
        vpcmpgtq \
        vpbroadcastb
    do
        if ! grep -F -- "$shape" "$_asm" > /dev/null; then
            echo "[spmd-simd] scan-prefix AVX2 assembly missing $shape" >&2
            echo "tests/integration/spmd_scan_scalar.tl avx2 (missing $shape)" >> "$FAILURES"
        fi
    done
    for shape in vpslldq vperm2i128 vpaddq; do
        if ! grep -F -- "$shape" "$_gang" > /dev/null; then
            echo "[spmd-simd] scan-prefix AVX2 i64 sum gang missing $shape" >&2
            echo "tests/integration/spmd_scan_scalar.tl avx2 (sum gang missing $shape)" >> "$FAILURES"
        fi
    done
    if grep -E -- '%zmm[0-9]+|%k[0-7]' "$_asm" > /dev/null; then
        echo "[spmd-simd] scan-prefix AVX2 assembly uses AVX-512 registers" >&2
        echo "tests/integration/spmd_scan_scalar.tl avx2 (AVX-512 register)" >> "$FAILURES"
    fi
}

verify_avx512_scan_prefix_shape() {
    compile_spmd_mode tests/integration/spmd_scan_scalar.tl avx512 2
    _tag=tests_integration_spmd_scan_scalar_tl
    _asm="$WORKDIR/$_tag.avx512.compile.s"
    _func="$WORKDIR/$_tag.avx512.scan-sum.s"
    _gang="$WORKDIR/$_tag.avx512.scan-sum-gang.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] scan-prefix AVX-512 shape compile failed:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/integration/spmd_scan_scalar.tl avx512 (prefix compile)" >> "$FAILURES"
        return
    fi
    sed -n '/^_tl_spmd_scan_scalar_scan_sum_i64:/,/^$/p' "$_asm" > "$_func"
    sed -n '/spmd_scan_avx512_body/,/spmd_scan_tail_header/p' "$_func" > "$_gang"
    for shape in \
        spmd_scan_avx512_body \
        valignd \
        valignq \
        vpaddd \
        vpaddq \
        vpminsd \
        vpminsq \
        vpmaxsd \
        vpmaxsq \
        kmovq \
        'shlq $32'
    do
        if ! grep -F -- "$shape" "$_asm" > /dev/null; then
            echo "[spmd-simd] scan-prefix AVX-512 assembly missing $shape" >&2
            echo "tests/integration/spmd_scan_scalar.tl avx512 (missing $shape)" >> "$FAILURES"
        fi
    done
    for shape in valignq vpaddq; do
        if ! grep -F -- "$shape" "$_gang" > /dev/null; then
            echo "[spmd-simd] scan-prefix AVX-512 i64 sum gang missing $shape" >&2
            echo "tests/integration/spmd_scan_scalar.tl avx512 (sum gang missing $shape)" >> "$FAILURES"
        fi
    done
    if grep -F -- spmd_scan_avx2_body "$_asm" > /dev/null; then
        echo "[spmd-simd] scan-prefix AVX-512 assembly uses the AVX2 scan label" >&2
        echo "tests/integration/spmd_scan_scalar.tl avx512 (AVX2 scan label)" >> "$FAILURES"
    fi
}

verify_avx2_varying_while_shape() {
    compile_spmd_mode tests/spmd/varying_while_i64.tl avx2
    _tag=tests_spmd_varying_while_i64_tl
    _asm="$WORKDIR/$_tag.avx2.compile.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] varying-while AVX2 shape compile failed:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/spmd/varying_while_i64.tl avx2 (shape compile)" >> "$FAILURES"
        return
    fi
    for shape in spmd_vwhile_header vpand vpmovmskb avx2_mask_spmd_vwhile_header avx2_mask_spmd_vwhile_body; do
        if ! grep -F -- "$shape" "$_asm" > /dev/null; then
            echo "[spmd-simd] varying-while AVX2 assembly missing $shape" >&2
            echo "tests/spmd/varying_while_i64.tl avx2 (missing $shape)" >> "$FAILURES"
        fi
    done
    if grep -E -- '%k[0-7]|%zmm[0-9]+' "$_asm" > /dev/null; then
        echo "[spmd-simd] varying-while AVX2 assembly uses AVX-512 registers" >&2
        echo "tests/spmd/varying_while_i64.tl avx2 (AVX-512 register)" >> "$FAILURES"
    fi
}

verify_avx2_varying_enum_match_shape() {
    compile_spmd_mode tests/spmd/varying_match_enum_payload.tl avx2
    _tag=tests_spmd_varying_match_enum_payload_tl
    _asm="$WORKDIR/$_tag.avx2.compile.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] varying-enum-match AVX2 shape compile failed:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/spmd/varying_match_enum_payload.tl avx2 (shape compile)" >> "$FAILURES"
        return
    fi
    for shape in spmd_match_lane_load vpmovmskb ymm; do
        if ! grep -F -- "$shape" "$_asm" > /dev/null; then
            echo "[spmd-simd] varying-enum-match AVX2 assembly missing $shape" >&2
            echo "tests/spmd/varying_match_enum_payload.tl avx2 (missing $shape)" >> "$FAILURES"
        fi
    done
    if grep -E -- '%k[0-7]|%zmm[0-9]+' "$_asm" > /dev/null; then
        echo "[spmd-simd] varying-enum-match AVX2 assembly uses AVX-512 registers" >&2
        echo "tests/spmd/varying_match_enum_payload.tl avx2 (AVX-512 register)" >> "$FAILURES"
    fi
}

verify_masked_bitwise_shape() {
    _mode=$1
    compile_spmd_mode tests/spmd/masked_if_bitwise_value_types.tl "$_mode"
    _tag=tests_spmd_masked_if_bitwise_value_types_tl
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] masked-bitwise $_mode shape compile failed:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/spmd/masked_if_bitwise_value_types.tl $_mode (shape compile)" >> "$FAILURES"
        return
    fi
    for lane in i8 u8 i16 u16 i32 u32 i64 u64; do
        _func="$WORKDIR/$_tag.$_mode.$lane.s"
        sed -n \
            "/^_tl_masked_if_bitwise_value_types_case_$lane:/,/^$/p" \
            "$_asm" > "$_func"
        if [ ! -s "$_func" ]; then
            echo "[spmd-simd] masked-bitwise $_mode missing case-$lane body" >&2
            echo "tests/spmd/masked_if_bitwise_value_types.tl $_mode (missing case-$lane)" >> "$FAILURES"
            continue
        fi
        if [ "$_mode" = avx2 ]; then
            _or_opcode=vpor
            _xor_opcode=vpxor
        else
            case "$lane" in
                i64 | u64)
                    _or_opcode=vporq
                    _xor_opcode=vpxorq
                    ;;
                *)
                    _or_opcode=vpord
                    _xor_opcode=vpxord
                    ;;
            esac
        fi
        for opcode in "$_or_opcode" "$_xor_opcode"; do
            if ! grep -F -- "$opcode" "$_func" > /dev/null; then
                echo "[spmd-simd] masked-bitwise $_mode case-$lane missing $opcode" >&2
                echo "tests/spmd/masked_if_bitwise_value_types.tl $_mode case-$lane (missing $opcode)" >> "$FAILURES"
            fi
        done
        if [ "$_mode" = avx2 ] &&
            ! grep -F -- "%ymm" "$_func" > /dev/null; then
            echo "[spmd-simd] masked-bitwise AVX2 case-$lane lacks vector code" >&2
            echo "tests/spmd/masked_if_bitwise_value_types.tl avx2 case-$lane (scalar fallback)" >> "$FAILURES"
        fi
        if [ "$_mode" = avx512 ] &&
            ! grep -E -- '%zmm[0-9]+.*\{%k[0-7]\}' "$_func" > /dev/null; then
            echo "[spmd-simd] masked-bitwise AVX-512 case-$lane lacks predication" >&2
            echo "tests/spmd/masked_if_bitwise_value_types.tl avx512 case-$lane (scalar fallback)" >> "$FAILURES"
        fi
    done
}

verify_masked_shift_shape() {
    _mode=$1
    compile_spmd_mode tests/spmd/masked_if_shift_value_types.tl "$_mode"
    _tag=tests_spmd_masked_if_shift_value_types_tl
    _asm="$WORKDIR/$_tag.$_mode.compile.s"
    if [ "$mode_code" != 0 ]; then
        echo "[spmd-simd] masked-shift $_mode shape compile failed:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/spmd/masked_if_shift_value_types.tl $_mode (shape compile)" >> "$FAILURES"
        return
    fi
    for lane in i32 u32 i64 u64; do
        _func="$WORKDIR/$_tag.$_mode.$lane.s"
        sed -n \
            "/^_tl_masked_if_shift_value_types_case_$lane:/,/^$/p" \
            "$_asm" > "$_func"
        if [ ! -s "$_func" ]; then
            echo "[spmd-simd] masked-shift $_mode missing case-$lane body" >&2
            echo "tests/spmd/masked_if_shift_value_types.tl $_mode (missing case-$lane)" >> "$FAILURES"
            continue
        fi
        if [ "$lane" = i32 ]; then
            _right=vpsravd
        elif [ "$lane" = u32 ]; then
            _right=vpsrlvd
        elif [ "$lane" = i64 ] && [ "$_mode" = avx512 ]; then
            _right=vpsravq
        else
            _right=vpsrlvq
        fi
        for opcode in vpsllv "$_right"; do
            if ! grep -F -- "$opcode" "$_func" > /dev/null; then
                echo "[spmd-simd] masked-shift $_mode case-$lane missing $opcode" >&2
                echo "tests/spmd/masked_if_shift_value_types.tl $_mode case-$lane (missing $opcode)" >> "$FAILURES"
            fi
        done
        if ! grep -F -- "call tl_shift_abort" "$_func" > /dev/null; then
            echo "[spmd-simd] masked-shift $_mode case-$lane lacks active-lane trap guard" >&2
            echo "tests/spmd/masked_if_shift_value_types.tl $_mode case-$lane (missing trap guard)" >> "$FAILURES"
        fi
        if [ "$_mode" = avx2 ]; then
            _reduce=vpmovmskb
        else
            _reduce=kortest
        fi
        if ! grep -F -- "$_reduce" "$_func" > /dev/null; then
            echo "[spmd-simd] masked-shift $_mode case-$lane lacks a reduced invalid-lane mask" >&2
            echo "tests/spmd/masked_if_shift_value_types.tl $_mode case-$lane (missing mask reduction)" >> "$FAILURES"
        fi
        if [ "$_mode" = avx2 ] && [ "$lane" = i64 ]; then
            for opcode in vpcmpgtq vpsllvq vpsrlvq vpor; do
                if ! grep -F -- "$opcode" "$_func" > /dev/null; then
                    echo "[spmd-simd] masked-shift AVX2 signed-i64 expansion missing $opcode" >&2
                    echo "tests/spmd/masked_if_shift_value_types.tl avx2 case-i64 (missing $opcode)" >> "$FAILURES"
                fi
            done
        fi
        if [ "$_mode" = avx2 ] &&
            ! grep -F -- "%ymm" "$_func" > /dev/null; then
            echo "[spmd-simd] masked-shift AVX2 case-$lane lacks vector code" >&2
            echo "tests/spmd/masked_if_shift_value_types.tl avx2 case-$lane (scalar fallback)" >> "$FAILURES"
        fi
        if [ "$_mode" = avx512 ] &&
            ! grep -E -- '%zmm[0-9]+|%k[0-7]' "$_func" > /dev/null; then
            echo "[spmd-simd] masked-shift AVX-512 case-$lane lacks vector code" >&2
            echo "tests/spmd/masked_if_shift_value_types.tl avx512 case-$lane (scalar fallback)" >> "$FAILURES"
        fi
    done
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

    for pair in "avx2 avx2" "avx512 avx512"; do
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

for mode in avx2 avx512; do
    # Code-shape checks do not execute SIMD instructions, so run them on every
    # host even when that ISA is unavailable for the execution corpus below.
    verify_gather_opcodes "$mode"
    verify_gather_reduce_opcodes "$mode"
    verify_shuffle_opcodes "$mode"
    verify_reduce_accumulator_shape "$mode"
done

verify_avx2_varying_while_shape
verify_avx2_varying_enum_match_shape
verify_masked_bitwise_shape avx2
verify_masked_bitwise_shape avx512
verify_masked_shift_shape avx2
verify_masked_shift_shape avx512
verify_avx2_scan_prefix_shape
verify_avx512_scan_prefix_shape

# Gather safety is a runtime property, not a same-exit result. Exercise a full
# gang with multiple invalid active lanes in every runnable mode. The lowering
# emits logical-lane checks before the hardware gather, so every mode must take
# the ordinary bounds abort path.
for gather_oob in tests/integration/spmd_gather_oob.tl tests/integration/spmd_gather_lane_offset_oob.tl; do
    for pair in "scalar scalar" "avx2 avx2" "avx512 avx512"; do
        mode=${pair%% *}
        isa=${pair##* }
        if [ "$mode" != scalar ] && ! isa_available "$isa"; then
            echo "[spmd-simd]   skip gather-oob $gather_oob $mode ($isa not runnable on this $HOST_OS host)"
            continue
        fi
        run_spmd_mode "$gather_oob" "$mode"
        if [ "$mode_code" != 134 ] || ! grep -F -- "tl: array index out of bounds" "$mode_err" > /dev/null; then
            echo "[spmd-simd] gather-oob $gather_oob $mode did not take the bounds abort path:" >&2
            sed 's/^/    /' "$mode_err" >&2
            echo "$gather_oob $mode (expected bounds abort 134, got $mode_code)" >> "$FAILURES"
        else
            echo "[spmd-simd] gather-oob $gather_oob $mode -> bounds abort OK"
        fi
    done
done

# Active invalid counts retain scalar trap semantics. The two fixtures cover a
# signed negative qword count and an unsigned count equal to the dword width.
for shift_trap in \
    tests/spmd/masked_if_shift_negative_trap.tl \
    tests/spmd/masked_if_shift_large_trap.tl
do
    for pair in "scalar scalar" "avx2 avx2" "avx512 avx512"; do
        mode=${pair%% *}
        isa=${pair##* }
        if [ "$mode" != scalar ] && ! isa_available "$isa"; then
            echo "[spmd-simd]   skip $shift_trap $mode ($isa not runnable)"
            continue
        fi
        run_spmd_mode "$shift_trap" "$mode"
        if [ "$mode_code" != 129 ] ||
            ! grep -F -- "tl: shift count out of range" "$mode_err" > /dev/null; then
            echo "[spmd-simd] $shift_trap $mode did not take the shift abort path:" >&2
            sed 's/^/    /' "$mode_err" >&2
            echo "$shift_trap $mode (expected shift abort 129, got $mode_code)" >> "$FAILURES"
        else
            echo "[spmd-simd] $shift_trap $mode -> shift abort OK"
        fi
    done
done

# Scan range and destination checks remain scalar-observable even when full
# gangs use vector prefixes. The short-output fixture completes one i64 gang
# before the scalar tail reaches the first invalid destination index.
for scan_oob in \
    tests/integration/spmd_scan_negative_start_trap.tl \
    tests/integration/spmd_scan_short_output_trap.tl
do
    for pair in "scalar scalar" "avx2 avx2" "avx512 avx512"; do
        mode=${pair%% *}
        isa=${pair##* }
        if [ "$mode" != scalar ] && ! isa_available "$isa"; then
            echo "[spmd-simd]   skip scan-oob $scan_oob $mode ($isa not runnable)"
            continue
        fi
        run_spmd_mode "$scan_oob" "$mode"
        if [ "$mode_code" != 134 ] ||
            ! grep -F -- "tl: array index out of bounds" "$mode_err" > /dev/null; then
            echo "[spmd-simd] scan-oob $scan_oob $mode did not preserve the bounds abort:" >&2
            sed 's/^/    /' "$mode_err" >&2
            echo "$scan_oob $mode (expected bounds abort 134, got $mode_code)" >> "$FAILURES"
        else
            echo "[spmd-simd] scan-oob $scan_oob $mode -> bounds abort OK"
        fi
    done
done

# A three-lane partial gang uses exactly-sized value and selector arrays.
# Execute it only in SIMD modes: scalar mode intentionally has one-lane gangs
# and therefore gives the varying selector a different source contract.
for pair in "avx2 avx2" "avx512 avx512"; do
    mode=${pair%% *}
    isa=${pair##* }
    if ! isa_available "$isa"; then
        echo "[spmd-simd]   skip shuffle-tail-selector $mode ($isa not runnable)"
        continue
    fi
    run_spmd_mode tests/integration/spmd_shuffle_tail_selector.tl "$mode"
    if [ "$mode_code" != 42 ] || [ -s "$mode_err" ]; then
        echo "[spmd-simd] shuffle tail selector $mode failed:" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/integration/spmd_shuffle_tail_selector.tl $mode (expected 42, got $mode_code)" >> "$FAILURES"
    else
        echo "[spmd-simd] shuffle tail selector $mode -> 42 OK"
    fi
done

# Invalid, negative, and inactive-tail selectors use the ordinary bounds abort
# in every mode. The tail fixture also proves a uniform value does not make
# selector evaluation/validation disappear.
for shuffle_oob in \
    tests/integration/spmd_shuffle_lane1_trap.tl \
    tests/integration/spmd_shuffle_negative_trap.tl \
    tests/integration/spmd_shuffle_tail_oob.tl
do
    for pair in "scalar scalar" "avx2 avx2" "avx512 avx512"; do
        mode=${pair%% *}
        isa=${pair##* }
        if [ "$mode" != scalar ] && ! isa_available "$isa"; then
            echo "[spmd-simd]   skip $shuffle_oob $mode ($isa not runnable)"
            continue
        fi
        run_spmd_mode "$shuffle_oob" "$mode"
        if [ "$mode_code" != 134 ] || ! grep -F -- "tl: array index out of bounds" "$mode_err" > /dev/null; then
            echo "[spmd-simd] $shuffle_oob $mode did not take the bounds abort path:" >&2
            sed 's/^/    /' "$mode_err" >&2
            echo "$shuffle_oob $mode (expected bounds abort 134, got $mode_code)" >> "$FAILURES"
        else
            echo "[spmd-simd] $shuffle_oob $mode -> bounds abort OK"
        fi
    done
done

# Every source and destination participates in the fused safety proof. A short
# second destination must therefore leave the SIMD path and preserve the scalar
# bounds trap instead of issuing a masked/full-width out-of-bounds store.
for pair in "scalar scalar" "avx2 avx2" "avx512 avx512"; do
    mode=${pair%% *}
    isa=${pair##* }
    if [ "$mode" != scalar ] && ! isa_available "$isa"; then
        echo "[spmd-simd]   skip multi-output bounds $mode ($isa not runnable)"
        continue
    fi
    run_spmd_mode tests/spmd/multi_output_bounds_trap.tl "$mode"
    if [ "$mode_code" != 134 ] ||
        ! grep -F -- "tl: array index out of bounds" "$mode_err" > /dev/null; then
        echo "[spmd-simd] multi-output bounds $mode did not preserve the trap:" >&2
        echo "    exit=$mode_code" >&2
        sed 's/^/    /' "$mode_err" >&2
        echo "tests/spmd/multi_output_bounds_trap.tl $mode" >> "$FAILURES"
    else
        echo "[spmd-simd] multi-output bounds $mode -> expected trap OK"
    fi
done

if [ -s "$FAILURES" ]; then
    echo "spmd-simd verification FAILED:" >&2
    sed 's/^/  /' "$FAILURES" >&2
    exit 1
fi

echo "spmd-simd verification passed (host=$HOST_OS, isas='$(printf '%s' "$SIMD_ISAS" | tr '\n' ' ')')"
