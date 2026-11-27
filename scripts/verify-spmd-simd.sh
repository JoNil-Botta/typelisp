#!/usr/bin/env sh
set -eu

# verify-spmd-simd.sh - scalar-vs-SIMD execution-comparison harness.
#
# Builds each SPMD corpus program at `scalar`, `avx2`, and `avx512`, runs every
# available variant, and asserts they produce IDENTICAL exit codes (with empty
# stderr). Staged unsupported mode/program pairs are compiled and must fail with
# an explicit diagnostic. `scalar` is always the reference; a SIMD mode is only
# run natively when the host supports it, or under pinned Intel SDE for
# AVX-512. CI requires one of those execution routes. This is the
# comparison the SPMD acceptance criteria need: proving SIMD lowering --
# including the masked `foreach` tail and `spmd-reduce` folds -- matches scalar
# semantics, not merely that a mode runs on a trivial full-width program.
#
# The corpus deliberately includes non-power-of-two lengths (the SIMD tail),
# foreach lanes across i64/i32/i8/u8/f64/f32, and reductions across the scalar
# supported operator/type surface. The per-program assembly shapes and the
# trap-path programs (bounds, shift and selector traps in every mode) are
# tests/spmd/simd.d, run afterwards by scripts/verify-codegen-cases.sh.
#
# A forced-SDE duplicate run (TYPELISP_SIMD_MODE_FILTER=avx512, set by
# scripts/ci-verify.sh) repeats only the AVX-512 route: every other mode
# compiles and executes exactly as the ordinary gate already did. It builds and
# runs only the selected modes, takes the scalar reference from the ordinary
# run's workdir (TYPELISP_SPMD_SIMD_NATIVE_ROOT), and fails closed when that
# reference is missing or the filter selects no case.
#
# Usage:
#   scripts/verify-spmd-simd.sh
#   TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-simd.sh
#

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

. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_require_compiler
BOUNDED_POOL_LABEL=spmd-simd
. "$ROOT/scripts/lib-bounded-pool.sh"

SPMD_SIMD_WORKERS=${TYPELISP_SPMD_SIMD_WORKERS:-4}
case "$SPMD_SIMD_WORKERS" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8) ;;
    *)
        echo "invalid TYPELISP_SPMD_SIMD_WORKERS: $SPMD_SIMD_WORKERS (expected 1-8)" >&2
        exit 2
        ;;
esac

# Windows uses the host-default native toolchain (clang/lld-link); Linux uses
# TypeLisp assembly and GNU ld.
if [ "$HOST_OS" = linux ]; then
    command -v ld >/dev/null 2>&1 || {
        echo "missing linker: ld" >&2
        exit 1
    }
fi

. "$ROOT/scripts/lib-simd-execution.sh"
simd_execution_init

spmd_short_tail_shape_fail() {
    echo "[spmd-simd] spmd_short_tail benchmark shape: $*" >&2
    exit 1
}

spmd_short_tail_typelisp_length() {
    sed -n '
        /^[[:space:]]*[(]define[[:space:]][[:space:]]*array-len[[:space:]]*:[[:space:]]*i64[[:space:]]*$/ {
            n
            s/^[[:space:]]*\([0-9][0-9]*\)[)][[:space:]]*$/\1/p
        }
    ' "$ROOT/benchmarks/spmd_short_tail/bench.tl"
}

spmd_short_tail_c_length() {
    sed -n 's/^#define ARRAY_LEN \([0-9][0-9]*\)$/\1/p' \
        "$ROOT/benchmarks/spmd_short_tail/baseline.c"
}

verify_spmd_short_tail_benchmark_shape() {
    _tl_len=$(spmd_short_tail_typelisp_length) ||
        spmd_short_tail_shape_fail "could not read the TypeLisp array-len literal"
    _c_len=$(spmd_short_tail_c_length) ||
        spmd_short_tail_shape_fail "could not read the C ARRAY_LEN literal"
    case "$_tl_len" in
        "" | *[!0-9]*)
            spmd_short_tail_shape_fail \
                "expected one literal TypeLisp array length, got '$_tl_len'"
            ;;
    esac
    case "$_c_len" in
        "" | *[!0-9]*)
            spmd_short_tail_shape_fail \
                "expected one literal C array length, got '$_c_len'"
            ;;
    esac
    [ "$_tl_len" = "$_c_len" ] ||
        spmd_short_tail_shape_fail \
            "paired lengths differ: TypeLisp=$_tl_len C=$_c_len"

    _avx2_tail=$((_tl_len % 4))
    _avx512_tail=$((_tl_len % 8))
    [ "$_avx2_tail" -ne 0 ] ||
        spmd_short_tail_shape_fail \
            "length $_tl_len executes zero i64 AVX2 tail lanes"
    [ "$_avx512_tail" -ne 0 ] ||
        spmd_short_tail_shape_fail \
            "length $_tl_len executes zero i64 AVX-512 tail lanes"

    echo "[spmd-simd] spmd_short_tail length $_tl_len: AVX2 tail $_avx2_tail lane(s), AVX-512 tail $_avx512_tail lane(s)"
}

verify_spmd_short_tail_benchmark_shape

WORKDIR=${TYPELISP_SPMD_SIMD_WORKDIR:-$ROOT/target/spmd-simd-verify}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
WORKDIR=$(CDPATH= cd -- "$WORKDIR" && pwd)

# A filtered run selects only the modes whose route differs under the forced
# policy, so its scalar reference is the ordinary run's native receipt.
NATIVE_WORKDIR=${TYPELISP_SPMD_SIMD_NATIVE_ROOT:-$ROOT/target/spmd-simd-verify}
if [ -n "${SIMD_MODE_FILTER:-}" ]; then
    [ -d "$NATIVE_WORKDIR" ] || {
        echo "spmd-simd: the ordinary run's workdir is missing: $NATIVE_WORKDIR" >&2
        exit 1
    }
    NATIVE_WORKDIR=$(CDPATH= cd -- "$NATIVE_WORKDIR" && pwd)
    [ "$NATIVE_WORKDIR" != "$WORKDIR" ] || {
        echo "spmd-simd: the filtered run's workdir must differ from the ordinary run's: $WORKDIR" >&2
        exit 1
    }
fi


# SPMD corpus: each program's exit code is computed by a SIMD-lowered `foreach`
# or `spmd-reduce`, so a wrong SIMD result (especially in the tail) changes it.
# Each program documents its shape and result in its header comment.
spmd_corpus() {
    cat <<'EOF'
tests/spmd/tail_i64_add.tl
tests/spmd/predicated_map_tail_fault_suppression.tl
tests/spmd/tail_i32_add.tl
tests/spmd/foreach_bound_extremes.tl
tests/spmd/foreach_2d_row_major.tl
tests/spmd/foreach_2d_native.tl
tests/spmd/uniform_zip_i64.tl
tests/integration/spmd_uniform_index_write.tl
tests/spmd/multi_output_i64.tl
tests/spmd/store_alias_i64.tl
tests/spmd/native_slice_surface_i64.tl
tests/spmd/native_slice_multi_output_i64.tl
tests/spmd/inline_helper_i64.tl
tests/spmd/inline_helper_shadow_i64.tl
tests/spmd/inline_helper_f64.tl
tests/spmd/stdlib_math_abs.tl
tests/spmd/stdlib_math_sqrt.tl
tests/integration/spmd_inline_helper_composition.tl
tests/spmd/private_helper_i64.tl
tests/spmd/private_helper_f64.tl
tests/spmd/private_helper_bool.tl
tests/spmd/private_helper_mask_arg.tl
tests/spmd/private_helper_entry_uniform_float.tl
tests/spmd/private_uniform_call_clamp.tl
tests/spmd/private_uniform_call_float.tl
tests/spmd/private_uniform_call_numeric.tl
tests/spmd/private_helper_uniform_stack.tl
tests/spmd/private_helper_uniform_stack_f64.tl
tests/spmd/private_helper_uniform_stack_f64_wide.tl
tests/spmd/private_helper_masked_load.tl
tests/spmd/private_helper_store.tl
tests/spmd/private_helper_effects.tl
tests/spmd/empty_private_params.tl
tests/spmd/byte_mul_value_types.tl
tests/spmd/full_gang_all_active_i64.tl
tests/spmd/masked_if_i64.tl
tests/spmd/masked_if_offset_i64.tl
tests/spmd/masked_if_index_value_i64.tl
tests/spmd/masked_if_index_mod_i64.tl
tests/spmd/masked_if_value_i64.tl
tests/spmd/masked_if_bitand_value_i64.tl
tests/spmd/masked_if_bitwise_value_types.tl
tests/spmd/masked_if_shift_value_types.tl
tests/spmd/masked_if_shift_inactive.tl
tests/spmd/map_shift_value_types.tl
tests/spmd/byte_shift_value_types.tl
tests/spmd/byte_shift_inactive_invalid.tl
tests/spmd/word_shift_value_types.tl
tests/spmd/word_shift_inactive_invalid.tl
tests/spmd/masked_if_value_types.tl
tests/spmd/masked_cast_i32_f32_reject.tl
tests/spmd/masked_cast_f32_i32_reject.tl
tests/spmd/masked_cast_u32_f32_reject.tl
tests/spmd/masked_cast_f32_u32_reject.tl
tests/spmd/masked_move_fault_suppression.tl
tests/spmd/masked_load_cache_fault_suppression.tl
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
tests/spmd/varying_match_enum_helper_reject.tl
tests/spmd/foreach_active_simd_reject.tl
tests/spmd/bool_lanes.tl
tests/spmd/map_compare_surface.tl
tests/spmd/map_fused_reduce_i64.tl
tests/spmd/fixed_array_sources.tl
tests/spmd/fixed_array_whole_use_keeps_array.tl
tests/integration/spmd_foreach.tl
tests/integration/spmd_compact_scalar.tl
tests/integration/spmd_gather_read.tl
tests/integration/spmd_loop_carried_copy_shape.tl
tests/integration/spmd_reduce_scalar.tl
tests/integration/spmd_scan_scalar.tl
tests/integration/spmd_shuffle_simd.tl
tests/integration/spmd_shuffle_types.tl
tests/integration/spmd_shuffle_reduce.tl
benchmarks/ispc/perfbench_gathers/bench.tl
EOF
}

isa_available() {
    simd_execution_mode "$1"
}

spmd_mode_expected_compile_diagnostic() {
    _prog=$1
    _mode=$2
    case "$_prog:$_mode" in
        tests/spmd/inline_helper_shadow_i64.tl:avx2 | tests/spmd/inline_helper_shadow_i64.tl:avx512)
            printf '%s\n' "lower: SPMD foreach does not match a SIMD lowering pattern for this backend mode; use scalar or a contiguous map/zip body with supported array and uniform operands"
            ;;
        tests/spmd/varying_match_enum_helper_reject.tl:avx2 | tests/spmd/varying_match_enum_helper_reject.tl:avx512)
            printf '%s\n' "lower: SPMD masked if does not support a SIMD varying enum match source outside a contiguous array lane"
            ;;
        tests/spmd/private_helper_uniform_stack_f64_wide.tl:avx512)
            printf '%s\n' "backend: private AVX-512 SPMD call supports at most 8 varying value arguments"
            ;;
        tests/spmd/foreach_active_simd_reject.tl:avx2)
            printf '%s\n' "lower: foreach-active is not yet lowered for AVX2"
            ;;
        tests/spmd/foreach_active_simd_reject.tl:avx512)
            printf '%s\n' "lower: foreach-active is not yet lowered for AVX-512"
            ;;
        tests/spmd/fixed_array_whole_use_keeps_array.tl:avx2 | tests/spmd/fixed_array_whole_use_keeps_array.tl:avx512)
            printf '%s\n' "lower: SPMD foreach does not match a SIMD lowering pattern for this backend mode; use scalar or a contiguous map/zip body with supported array and uniform operands"
            ;;
        tests/spmd/masked_cast_*_reject.tl:avx2 | tests/spmd/masked_cast_*_reject.tl:avx512)
            # masked_cast_<source>_<destination>_reject.tl: masked conversions
            # reject at the cast until #7162 implements them (#7306).
            _row=${_prog#tests/spmd/masked_cast_}
            _row=${_row%_reject.tl}
            _backend=AVX2
            [ "$_mode" = avx2 ] || _backend=AVX-512
            printf '%s\n' "lower: SPMD numeric conversion from ${_row%_*} to ${_row#*_} is unsupported in masked control context for $_backend backend; SIMD cross-lane conversion has no implemented strategy; use scalar backend"
            ;;
        *) return 1 ;;
    esac
}

spmd_mode_compile_only_reason() {
    _prog=$1
    _mode=$2
    case "$_prog:$_mode" in
        tests/integration/spmd_gather_read.tl:sse2 | benchmarks/ispc/perfbench_gathers/bench.tl:sse2)
            # Both fixtures compare (program-index) across a vectorized loop and
            # a GatherLoad loop; SSE2 intentionally falls back GatherLoad to
            # scalar (width 1) while plain (program-index) loops vectorize.
            printf '%s\n' "gather falls back to scalar in SSE2 while lane-id probes vectorize"
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
    mode_exit="$WORKDIR/$_tag.$_mode.exit"
    : > "$mode_out"
    : > "$mode_err"
    mode_execution="$WORKDIR/$_tag.$_mode.execution"
    rm -f "$mode_exit" "$mode_execution"

    if [ "$HOST_OS" = linux ]; then
        _asm="$WORKDIR/$_tag.$_mode.s"
        _obj="$WORKDIR/$_tag.$_mode.o"
        _bin="$WORKDIR/$_tag.$_mode"
        if ! "$COMPILER" compile "$_prog" --backend-mode "$_mode" -o "$_asm" > "$mode_out" 2> "$mode_err"; then
            mode_code=1
            return
        fi
        if ! "$COMPILER" assemble "$_asm" -o "$_obj" >> "$mode_out" 2>> "$mode_err"; then
            mode_code=1
            return
        fi
        _entry=$(linux_entry_symbol_for_asm "$_asm") || exit $?
        _stdlib_archive=$(linux_stdlib_archive_for_asm "$_asm" "${COMPILER:-}")
        if [ -n "$_stdlib_archive" ]; then
            set -- -z noexecstack --gc-sections -z start-stop-gc --start-group "$_stdlib_archive" --end-group
        else
            set --
        fi
        if ! ld "$_obj" -o "$_bin" -static "$@" -e "$_entry" \
            >> "$mode_out" 2>> "$mode_err"; then
            mode_code=1
            return
        fi
        simd_execution_record "$_prog" "$_mode"
        printf '%s\n' "$SIMDEX_MODE" > "$mode_execution"
        set +e
        simd_execute "$_mode" "$_bin" >> "$mode_out" 2>> "$mode_err"
        mode_code=$?
        set -e
    else
        simd_execution_mode "$_mode" || return 1
        _bin="$WORKDIR/$_tag.$_mode.exe"
        if ! "$COMPILER" build "$_prog" --backend-mode "$_mode" -o "$_bin" \
            > "$mode_out" 2> "$mode_err"; then
            mode_code=1
            return
        fi
        simd_execution_record "$_prog" "$_mode"
        printf '%s\n' "$SIMDEX_MODE" > "$mode_execution"
        set +e
        simd_execute "$_mode" "$_bin" > "$mode_out" 2> "$mode_err"
        mode_code=$?
        set -e
    fi
    printf '%s\n' "$mode_code" > "$mode_exit"
}

# Print the scalar exit status the ordinary run recorded for $1. A filtered
# run repeats only the modes whose route differs, so the reference is read
# rather than rebuilt; a missing, malformed or failed receipt fails closed
# instead of comparing against nothing.
spmd_scalar_reference() {
    _sr_tag=$(printf '%s' "$1" | sed 's#[/.]#_#g')
    _sr_exit="$NATIVE_WORKDIR/$_sr_tag.scalar.exit"
    _sr_err="$NATIVE_WORKDIR/$_sr_tag.scalar.err"
    [ -f "$_sr_exit" ] && [ -f "$_sr_err" ] || {
        echo "spmd-simd: the ordinary run recorded no scalar reference for $1 ($_sr_exit)" >&2
        return 1
    }
    [ ! -s "$_sr_err" ] || {
        echo "spmd-simd: the ordinary run's scalar reference for $1 wrote stderr: $_sr_err" >&2
        return 1
    }
    _sr_code=$(tr -d '\r\n' < "$_sr_exit")
    case "$_sr_code" in
        '' | *[!0-9]*)
            echo "spmd-simd: the ordinary run's scalar exit for $1 is not a status: '$_sr_code'" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$_sr_code"
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

POOL_DIR="$WORKDIR/pool"
POOL_JOBS_DIR="$WORKDIR/pool-jobs"
POOL_QUEUE="$WORKDIR/pool.queue"
mkdir -p "$POOL_JOBS_DIR"
: > "$POOL_QUEUE"

corpus_idx=0
while IFS= read -r prog; do
    [ -n "$prog" ] || continue
    corpus_idx=$((corpus_idx + 1))
    job_id=$(printf 'prog-%03d' "$corpus_idx")
    printf '%s\n' "$prog" > "$POOL_JOBS_DIR/$job_id.prog"
    printf '%s|1\n' "$job_id" >> "$POOL_QUEUE"
done < "$CORPUS"

run_spmd_corpus_job() {
    _job=$1
    _prog=$(cat "$POOL_JOBS_DIR/$_job.prog")
    _job_out="$POOL_JOBS_DIR/$_job.stdout"
    _job_err="$POOL_JOBS_DIR/$_job.stderr"
    _job_fail="$POOL_JOBS_DIR/$_job.failures"
    _job_selected=0
    SIMDEX_NATIVE=0
    SIMDEX_EMULATED=0
    SIMDEX_SKIPPED=0
    : > "$_job_out"
    : > "$_job_err"
    : > "$_job_fail"

    if [ ! -f "$_prog" ]; then
        echo "spmd-simd: corpus program not found: $_prog" >> "$_job_err"
        echo "$_prog (missing)" >> "$_job_fail"
        printf '%s\n' "$_job_selected" > "$POOL_JOBS_DIR/$_job.selected"
        printf '%s %s %s\n' "$SIMDEX_NATIVE" "$SIMDEX_EMULATED" "$SIMDEX_SKIPPED" > "$POOL_JOBS_DIR/$_job.simdex"
        return 0
    fi

    if simd_mode_selected scalar; then
        _job_selected=$((_job_selected + 1))
        # scalar is the always-run reference.
        run_spmd_mode "$_prog" scalar >> "$_job_out" 2>> "$_job_err"
        scalar_code=$mode_code
        if [ -s "$mode_err" ]; then
            {
                echo "[spmd-simd] $_prog scalar build/run error:"
                sed 's/^/    /' "$mode_err"
            } >> "$_job_err"
            echo "$_prog scalar" >> "$_job_fail"
            printf '%s\n' "$_job_selected" > "$POOL_JOBS_DIR/$_job.selected"
            printf '%s %s %s\n' "$SIMDEX_NATIVE" "$SIMDEX_EMULATED" "$SIMDEX_SKIPPED" > "$POOL_JOBS_DIR/$_job.simdex"
            return 0
        fi
        echo "[spmd-simd] $_prog scalar -> $scalar_code" >> "$_job_out"
    else
        if ! scalar_code=$(spmd_scalar_reference "$_prog" 2>> "$_job_err"); then
            printf '1\n' > "$POOL_JOBS_DIR/$_job.fatal"
            return 1
        fi
        echo "[spmd-simd] $_prog scalar -> $scalar_code (ordinary run reference)" >> "$_job_out"
    fi

    for pair in "sse2 sse2" "avx2 avx2" "avx512 avx512"; do
        mode=${pair%% *}
        isa=${pair##* }
        if ! simd_mode_selected "$mode"; then
            continue
        fi
        _job_selected=$((_job_selected + 1))
        if expected_diag=$(spmd_mode_expected_compile_diagnostic "$_prog" "$mode"); then
            compile_spmd_mode "$_prog" "$mode"
            if [ "$mode_code" = 0 ]; then
                {
                    echo "[spmd-simd]   $mode unexpectedly compiled; wanted diagnostic:"
                    echo "    $expected_diag"
                } >> "$_job_err"
                echo "$_prog $mode (missing diagnostic)" >> "$_job_fail"
            elif ! grep -F -- "$expected_diag" "$mode_err" > /dev/null; then
                {
                    echo "[spmd-simd]   $mode diagnostic mismatch:"
                    sed 's/^/    /' "$mode_err"
                } >> "$_job_err"
                echo "$_prog $mode (wrong diagnostic)" >> "$_job_fail"
            else
                echo "[spmd-simd]   $mode -> expected diagnostic OK" >> "$_job_out"
            fi
            continue
        fi
        if compile_only_reason=$(spmd_mode_compile_only_reason "$_prog" "$mode"); then
            compile_spmd_mode "$_prog" "$mode"
            if [ "$mode_code" != 0 ] || [ -s "$mode_err" ]; then
                {
                    echo "[spmd-simd]   $mode compile error:"
                    sed 's/^/    /' "$mode_err"
                } >> "$_job_err"
                echo "$_prog $mode (compile failed)" >> "$_job_fail"
            else
                echo "[spmd-simd]   $mode -> compiled OK ($compile_only_reason)" >> "$_job_out"
            fi
            continue
        fi
        if ! isa_available "$isa"; then
            simd_execution_record "$_prog" "$mode" >> "$_job_out" 2>> "$_job_err"
            echo "[spmd-simd]   skip $mode ($isa not runnable on this $HOST_OS host)" >> "$_job_out"
            continue
        fi
        run_spmd_mode "$_prog" "$mode" >> "$_job_out" 2>> "$_job_err"
        if [ -s "$mode_err" ]; then
            {
                echo "[spmd-simd]   $mode build/run error:"
                sed 's/^/    /' "$mode_err"
            } >> "$_job_err"
            echo "$_prog $mode" >> "$_job_fail"
        elif [ "$mode_code" != "$scalar_code" ]; then
            echo "[spmd-simd]   $mode -> $mode_code MISMATCH (scalar=$scalar_code)" >> "$_job_err"
            echo "$_prog $mode ($mode_code vs scalar $scalar_code)" >> "$_job_fail"
        else
            echo "[spmd-simd]   $mode -> $mode_code OK" >> "$_job_out"
        fi
    done

    printf '%s\n' "$_job_selected" > "$POOL_JOBS_DIR/$_job.selected"
    printf '%s %s %s\n' "$SIMDEX_NATIVE" "$SIMDEX_EMULATED" "$SIMDEX_SKIPPED" > "$POOL_JOBS_DIR/$_job.simdex"
    return 0
}

bounded_pool_run_job() {
    run_spmd_corpus_job "$1"
}

echo "[spmd-simd] running $corpus_idx corpus program(s) with $SPMD_SIMD_WORKERS worker(s)"
bounded_pool_init "$POOL_DIR" "$SPMD_SIMD_WORKERS" "$POOL_QUEUE" || exit 1
bounded_pool_start "$POOL_DIR" "$SPMD_SIMD_WORKERS"
pool_status=0
bounded_pool_join "$POOL_DIR" || pool_status=$?

SIMD_MODE_SELECTED=0
SIMDEX_NATIVE=0
SIMDEX_EMULATED=0
SIMDEX_SKIPPED=0
fatal_error=0
replay_idx=0
while [ "$replay_idx" -lt "$corpus_idx" ]; do
    replay_idx=$((replay_idx + 1))
    job_id=$(printf 'prog-%03d' "$replay_idx")
    [ ! -s "$POOL_JOBS_DIR/$job_id.stdout" ] || cat "$POOL_JOBS_DIR/$job_id.stdout"
    [ ! -s "$POOL_JOBS_DIR/$job_id.stderr" ] || cat "$POOL_JOBS_DIR/$job_id.stderr" >&2
    [ ! -s "$POOL_JOBS_DIR/$job_id.failures" ] || cat "$POOL_JOBS_DIR/$job_id.failures" >> "$FAILURES"
    [ ! -f "$POOL_JOBS_DIR/$job_id.fatal" ] || fatal_error=1
    if [ -f "$POOL_JOBS_DIR/$job_id.selected" ]; then
        read -r _s < "$POOL_JOBS_DIR/$job_id.selected"
        SIMD_MODE_SELECTED=$((SIMD_MODE_SELECTED + _s))
    fi
    if [ -f "$POOL_JOBS_DIR/$job_id.simdex" ]; then
        read -r _n _e _k < "$POOL_JOBS_DIR/$job_id.simdex"
        SIMDEX_NATIVE=$((SIMDEX_NATIVE + _n))
        SIMDEX_EMULATED=$((SIMDEX_EMULATED + _e))
        SIMDEX_SKIPPED=$((SIMDEX_SKIPPED + _k))
    fi
done

if [ "$fatal_error" -ne 0 ] || [ "$pool_status" -ne 0 ]; then
    exit 1
fi

if [ -n "${SIMD_MODE_FILTER:-}" ] && [ "$SIMD_MODE_SELECTED" -eq 0 ]; then
    echo "spmd-simd: TYPELISP_SIMD_MODE_FILTER=$SIMD_MODE_FILTER selected no corpus mode" >&2
    exit 1
fi

# Codegen shapes and trap paths: tests/spmd/simd.d.
if ! TYPELISP_BIN=$COMPILER CODEGEN_CASES_WORKDIR="$WORKDIR/cases" \
    sh "$ROOT/scripts/verify-codegen-cases.sh" tests/spmd/simd.d; then
    echo "tests/spmd/simd.d" >> "$FAILURES"
fi

if [ -s "$FAILURES" ]; then
    echo "spmd-simd verification FAILED:" >&2
    sed 's/^/  /' "$FAILURES" >&2
    exit 1
fi

simd_execution_summary spmd-simd
echo "spmd-simd verification passed (host=$HOST_OS, native-isas='$(printf '%s' "$SIMDEX_NATIVE_ISAS" | tr '\n' ' ')')"
