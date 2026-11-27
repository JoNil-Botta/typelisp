#!/usr/bin/env sh
set -eu

# verify-spmd-simd.sh - scalar-vs-SIMD execution-comparison harness.
#
# Batches the execution corpus at O0/O1/O2 in scalar, SSE2, AVX2 and AVX-512.
# Every runnable row must match the O1 scalar exit status and leave stderr
# empty. Check staged diagnostics individually since compile --batch stops
# on the first failure. The assembly shapes and traps run in simd.d.
# The forced-SDE gate selects AVX-512 and reuses the ordinary O1 scalar
# receipts. O1 retains the original receipt names for cross-mode differential.
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
gate_compiler_absolute
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

SPMD_STEP_SECONDS=${TYPELISP_SPMD_SIMD_STEP_SECONDS:-30}
SPMD_BATCH_SECONDS=${TYPELISP_SPMD_SIMD_BATCH_SECONDS:-120}
for limit in "$SPMD_STEP_SECONDS" "$SPMD_BATCH_SECONDS"; do
    case "$limit" in
        "" | 0* | *[!0-9]*) fail "SPMD time limits must be positive integer seconds" ;;
    esac
done
command -v timeout >/dev/null 2>&1 || fail "missing coreutils timeout"

if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || fail "missing assembler: as"
    command -v ld >/dev/null 2>&1 || fail "missing linker: ld"
    TRIPLE=x86_64-unknown-linux-gnu
    BIN_EXT=
else
    . "$ROOT/scripts/lib-native-link.sh"
    native_link_detect_host
    configure_toolchain
    TRIPLE=x86_64-pc-windows-msvc
    BIN_EXT=.exe
fi
TARGET="$HOST_OS-x86_64"

# The CI bootstrap installs the matching sysroot beside the compiler. Use
# the same resolved root for the interface and archive, including overrides.
SYSROOT=${TYPELISP_SYSROOT:-}
if [ -z "$SYSROOT" ]; then
    SYSROOT=${COMPILER%/*}
    [ -f "$SYSROOT/lib/$TRIPLE/stdlib.tli" ] || SYSROOT=$(dirname -- "$SYSROOT")
fi
[ -s "$SYSROOT/lib/$TRIPLE/stdlib.tli" ] &&
    [ -s "$SYSROOT/lib/$TRIPLE/libstdlib.a" ] ||
    fail "missing prebuilt stdlib for $TRIPLE in $SYSROOT"
SYSROOT=$(CDPATH= cd -- "$SYSROOT" && pwd)
TYPELISP_SYSROOT=$SYSROOT
[ "$HOST_OS" != windows ] || TYPELISP_SYSROOT=$(cygpath -am "$SYSROOT")
export TYPELISP_SYSROOT
stdlib_archive_resolve_triple "$TRIPLE" "$COMPILER"

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


spmd_mode_expected_compile_diagnostic() {
    _prog=$1
    _mode=$2
    case "$_prog:$_mode:$3" in
        tests/spmd/inline_helper_shadow_i64.tl:avx2:[012] | tests/spmd/inline_helper_shadow_i64.tl:avx512:[012])
            printf '%s\n' "lower: SPMD foreach does not match a SIMD lowering pattern for this backend mode; use scalar or a contiguous map/zip body with supported array and uniform operands"
            ;;
        tests/spmd/varying_match_enum_helper_reject.tl:avx2:[012] | tests/spmd/varying_match_enum_helper_reject.tl:avx512:[012])
            printf '%s\n' "lower: SPMD masked if does not support a SIMD varying enum match source outside a contiguous array lane"
            ;;
        tests/spmd/private_helper_uniform_stack_f64_wide.tl:avx512:[012])
            printf '%s\n' "backend: private AVX-512 SPMD call supports at most 8 varying value arguments"
            ;;
        # #8307 owns the transition of these AVX rejections to runtime rows.
        tests/spmd/foreach_active_simd_reject.tl:avx2:[012])
            printf '%s\n' "lower: foreach-active is not yet lowered for AVX2"
            ;;
        tests/spmd/foreach_active_simd_reject.tl:avx512:[012])
            printf '%s\n' "lower: foreach-active is not yet lowered for AVX-512"
            ;;
        tests/spmd/fixed_array_whole_use_keeps_array.tl:avx2:[012] | tests/spmd/fixed_array_whole_use_keeps_array.tl:avx512:[012])
            printf '%s\n' "lower: SPMD foreach does not match a SIMD lowering pattern for this backend mode; use scalar or a contiguous map/zip body with supported array and uniform operands"
            ;;
        tests/spmd/masked_cast_*_reject.tl:avx2:[012] | tests/spmd/masked_cast_*_reject.tl:avx512:[012])
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

# A program can exit with status 124 or 137 itself. Require the watchdog's
# signal notice, and leave the captured stderr available to the row checks.
spmd_invoke() {
    _si_limit=$1
    _si_stem=$2
    shift 2
    spmd_status=0
    spmd_watchdog_failure=
    LC_ALL=C timeout --verbose --kill-after=2 "$_si_limit" "$@" \
        < /dev/null > "$_si_stem.out" 2> "$_si_stem.err" || spmd_status=$?
    case "$spmd_status" in
        124 | 137)
            if grep -Fq 'timeout: sending signal ' "$_si_stem.err"; then
                spmd_watchdog_failure="timeout after ${_si_limit}s"
                return 1
            fi
            ;;
        125 | 126 | 127)
            if grep -q '^timeout: ' "$_si_stem.err"; then
                cat "$_si_stem.err" >&2
                spmd_watchdog_failure="watchdog failed (status $spmd_status)"
                return 1
            fi
            ;;
    esac
}

spmd_assemble_link() {
    _asm=$1.s
    _obj=$1.o
    _bin=$1$BIN_EXT
    if [ "$HOST_OS" = linux ]; then
        if ! spmd_invoke "$SPMD_STEP_SECONDS" "$1.assemble" as "$_asm" -o "$_obj" ||
            [ "$spmd_status" -ne 0 ] || [ -s "$1.assemble.err" ]; then
            return 1
        fi
        _entry=$(linux_entry_symbol_for_asm "$_asm") || exit $?
        _stdlib_archive=$(linux_stdlib_archive_for_asm "$_asm" "${COMPILER:-}")
        _link_base=${_asm%.s}
        if [ -n "$_stdlib_archive" ]; then
            set -- -z noexecstack --gc-sections -z start-stop-gc --start-group "$_stdlib_archive" --end-group
        else
            set --
        fi
        if ! spmd_invoke "$SPMD_STEP_SECONDS" "$_link_base.link" ld "$_obj" -o "$_bin" -static "$@" -e "$_entry" ||
            [ "$spmd_status" -ne 0 ] || [ -s "$_link_base.link.err" ]; then
            return 1
        fi
        return 0
    else
        spmd_invoke "$SPMD_STEP_SECONDS" "$1.assemble" "$TYPELISP_WINDOWS_CLANG_POSIX" \
            --target=x86_64-pc-windows-msvc -c "$_asm" -o "$_obj" || return 1
        [ "$spmd_status" -eq 0 ] && [ ! -s "$1.assemble.err" ] || return 1
        _windows_archive=
        if [ -n "$(windows_stdlib_archive_for_asm "$_asm" "$COMPILER")" ]; then
            _windows_archive=$WINDOWS_ARCHIVE
        fi
        MSYS2_ARG_CONV_EXCL='*' spmd_invoke "$SPMD_STEP_SECONDS" "$1.link" "$TYPELISP_WINDOWS_LINK_POSIX" \
            /NOLOGO /Brepro /OPT:REF "$(cygpath -aw "$_obj")" ${_windows_archive:+"$_windows_archive"} \
            "/OUT:$(cygpath -aw "$_bin")" /SUBSYSTEM:CONSOLE /ENTRY:_tl_start /NODEFAULTLIB \
            /DYNAMICBASE:NO "/STACK:$NL_WINDOWS_STACK_RESERVE" kernel32.lib ntdll.lib || return 1
    fi
    [ "$spmd_status" -eq 0 ] && [ ! -s "$1.link.err" ]
}

spmd_row_base() {
    case "$3" in
        1) base="$WORKDIR/$1.$2" ;;
        *) base="$WORKDIR/$1.$2.O$3" ;;
    esac
}

spmd_row_failure() {
    echo "[spmd-simd] FAIL $prog $mode O$opt ($*)" >&2
    printf '%s %s O%s (%s)\n' "$prog" "$mode" "$opt" "$*" >> "$job_dir/failures"
}

spmd_compile_one() {
    compiler_invocations=$((compiler_invocations + 1))
    spmd_invoke "$SPMD_STEP_SECONDS" "$base.compile" \
        "$COMPILER" compile "$prog" --target "$TARGET" --backend-mode "$mode" --opt-level "$opt" -o "$base.s"
}

spmd_run_row() {
    if ! spmd_assemble_link "$base"; then
        spmd_row_failure "assembly/link failed${spmd_watchdog_failure:+: $spmd_watchdog_failure}"
        for build_stream in "$base.assemble.err" "$base.link.err"; do
            [ ! -s "$build_stream" ] || cat "$build_stream" >&2
        done
        return
    fi
    simd_execution_record "$prog O$opt" "$mode"
    if [ "$SIMDEX_MODE" = sde ]; then
        set -- "$SIMDEX_SDE_BIN" -spr -- "$base$BIN_EXT"
    else
        set -- "$base$BIN_EXT"
    fi
    if ! spmd_invoke "$SPMD_STEP_SECONDS" "$base" "$@"; then
        spmd_row_failure "run $spmd_watchdog_failure"
    elif [ -s "$base.err" ]; then
        spmd_row_failure "runtime stderr"
        cat "$base.err" >&2
    else
        printf '%s\n' "$spmd_status" > "$base.exit"
        printf '%s\n' "$SIMDEX_MODE" > "$base.execution"
        echo "[spmd-simd] $prog $mode O$opt -> $spmd_status"
    fi
}

bounded_pool_run_job() {
    mode=${1%-*}
    opt=${1##*-}
    job_dir="$WORKDIR/jobs/$1"
    mkdir -p "$job_dir"
    spmd_matrix_job > "$job_dir/stdout" 2> "$job_dir/stderr"
}

spmd_matrix_job() {
    : > "$job_dir/failures"
    : > "$job_dir/batch.list"
    : > "$job_dir/rows"
    compiler_invocations=0
    diagnostics=0
    compile_only=0
    runs=0
    SIMDEX_NATIVE=0
    SIMDEX_EMULATED=0
    SIMDEX_SKIPPED=0
    while IFS='|' read -r prog tag; do
        spmd_row_base "$tag" "$mode" "$opt"
        if ! expected_diag=$(spmd_mode_expected_compile_diagnostic "$prog" "$mode" "$opt"); then
            # The compiler does not receive MSYS path translation for the
            # contents of a batch list. Use repo-relative input paths and a
            # native output root on Windows.
            printf '%s|%s%s.s\n' "$prog" "$BATCH_OUTPUT_ROOT" "${base#"$WORKDIR"}" >> "$job_dir/batch.list"
        fi
        printf '%s|%s|%s\n' "$prog" "$base" "$expected_diag" >> "$job_dir/rows"
    done < "$CORPUS"

    batch_failed=0
    batch_interrupted=
    if [ -s "$job_dir/batch.list" ]; then
        compiler_invocations=$((compiler_invocations + 1))
        if ! spmd_invoke "$SPMD_BATCH_SECONDS" "$job_dir/batch" \
            "$COMPILER" compile --batch "$job_dir/batch.list" --target "$TARGET" \
            --backend-mode "$mode" --opt-level "$opt"; then
            batch_interrupted=$spmd_watchdog_failure
        fi
        if [ -n "$batch_interrupted" ] || [ "$spmd_status" -ne 0 ] || [ -s "$job_dir/batch.err" ]; then
            batch_failed=1
            batch_failure=${batch_interrupted:-"failed, status $spmd_status"}
            echo "[spmd-simd] FAIL $mode O$opt batch compile ($batch_failure)" >&2
            printf '%s O%s (batch compile %s)\n' "$mode" "$opt" "$batch_failure" >> "$job_dir/failures"
            [ ! -s "$job_dir/batch.err" ] || cat "$job_dir/batch.err" >&2
        fi
    fi

    while IFS='|' read -r prog base expected_diag; do
        if [ -n "$expected_diag" ]; then
            if ! spmd_compile_one; then
                spmd_row_failure "diagnostic compile $spmd_watchdog_failure"
            elif [ "$spmd_status" -eq 0 ] || ! grep -Fq -- "$expected_diag" "$base.compile.err"; then
                spmd_row_failure "expected diagnostic: $expected_diag"
                cat "$base.compile.err" >&2
            else
                diagnostics=$((diagnostics + 1))
                echo "[spmd-simd] $prog $mode O$opt -> expected diagnostic OK"
            fi
            continue
        fi
        if [ ! -s "$base.s" ]; then
            if [ -n "$batch_interrupted" ]; then
                spmd_row_failure "no assembly after batch compile $batch_interrupted"
                continue
            fi
            # The batch stops at its first error. Check the remaining rows
            # individually for coverage while retaining the batch failure.
            if [ "$batch_failed" -eq 0 ]; then
                spmd_row_failure "batch omitted assembly"
            fi
            if ! spmd_compile_one; then
                spmd_row_failure "compile $spmd_watchdog_failure"
                continue
            fi
            if [ "$spmd_status" -ne 0 ] || [ -s "$base.compile.err" ] || [ ! -s "$base.s" ]; then
                spmd_row_failure "compile failed"
                cat "$base.compile.err" >&2
                continue
            fi
        fi
        if reason=$(spmd_mode_compile_only_reason "$prog" "$mode"); then
            compile_only=$((compile_only + 1))
            echo "[spmd-simd] $prog $mode O$opt -> compiled only ($reason)"
        elif ! simd_execution_mode "$mode"; then
            simd_execution_record "$prog O$opt" "$mode"
            compile_only=$((compile_only + 1))
            echo "[spmd-simd] $prog $mode O$opt -> compiled only ($mode unavailable on $HOST_OS)"
        else
            spmd_run_row
            [ ! -f "$base.exit" ] || runs=$((runs + 1))
        fi
    done < "$job_dir/rows"
    printf '%s %s %s\n' "$SIMDEX_NATIVE" "$SIMDEX_EMULATED" "$SIMDEX_SKIPPED" > "$job_dir/simd"
    printf '%s %s %s %s\n' "$compiler_invocations" "$runs" "$diagnostics" "$compile_only" > "$job_dir/counts"
}

. "$ROOT/scripts/lib-manifest.sh"
CORPUS="$WORKDIR/corpus.txt"
manifest_concat_dir "$ROOT/tests/spmd/corpus.d" > "$WORKDIR/corpus.raw"
awk '
    /^[[:space:]]*(#|$)/ {next}
    {
        tag = $0
        gsub(/[\/.]/, "_", tag)
        if ($0 !~ /^[A-Za-z0-9_\/.\-]+[.]tl$/ || seen[tag]++) {
            print "invalid or duplicate SPMD corpus row: " $0 > "/dev/stderr"
            bad = 1
        }
        print $0 "|" tag
    }
    END {exit bad || !length(seen)}
' "$WORKDIR/corpus.raw" > "$CORPUS"
while IFS='|' read -r prog tag; do
    [ -f "$prog" ] || fail "spmd-simd: corpus program not found: $prog"
done < "$CORPUS"
corpus_count=$(wc -l < "$CORPUS" | tr -d ' ')

BATCH_OUTPUT_ROOT=$WORKDIR
if [ "$HOST_OS" = windows ]; then
    BATCH_OUTPUT_ROOT=$(cygpath -am "$WORKDIR")
    WINDOWS_ARCHIVE=$(cygpath -aw "$STDLIB_ARCHIVE_PATH")
fi
POOL_DIR="$WORKDIR/pool"
POOL_QUEUE="$WORKDIR/pool.queue"
: > "$POOL_QUEUE"
for opt in 1 0 2; do
    for mode in scalar sse2 avx2 avx512; do
        if simd_mode_selected "$mode"; then
            printf '%s-%s|1\n' "$mode" "$opt" >> "$POOL_QUEUE"
        fi
    done
done
[ -s "$POOL_QUEUE" ] || fail "spmd-simd: TYPELISP_SIMD_MODE_FILTER=$SIMD_MODE_FILTER selected no corpus mode"

echo "[spmd-simd] running $corpus_count corpus program(s) per matrix cell with $SPMD_SIMD_WORKERS worker(s)"
bounded_pool_init "$POOL_DIR" "$SPMD_SIMD_WORKERS" "$POOL_QUEUE"
bounded_pool_start "$POOL_DIR" "$SPMD_SIMD_WORKERS"
pool_status=0
bounded_pool_join "$POOL_DIR" || pool_status=$?

FAILURES="$WORKDIR/failures.txt"
: > "$FAILURES"
: > "$WORKDIR/counts.tsv"
while IFS='|' read -r job unused; do
    job_dir="$WORKDIR/jobs/$job"
    [ ! -s "$job_dir/stdout" ] || cat "$job_dir/stdout"
    [ ! -s "$job_dir/stderr" ] || cat "$job_dir/stderr" >&2
    [ ! -s "$job_dir/failures" ] || cat "$job_dir/failures" >> "$FAILURES"
    [ -s "$job_dir/counts" ] || continue
    read -r n e k < "$job_dir/simd"
    SIMDEX_NATIVE=$((SIMDEX_NATIVE + n))
    SIMDEX_EMULATED=$((SIMDEX_EMULATED + e))
    SIMDEX_SKIPPED=$((SIMDEX_SKIPPED + k))
    read -r invocations runs diagnostics compile_only < "$job_dir/counts"
    accounted=$((runs + diagnostics + compile_only))
    echo "[spmd-simd] $job rows=$corpus_count ran=$runs diagnostics=$diagnostics compile-only=$compile_only failed=$((corpus_count - accounted)) compiler-invocations=$invocations"
    printf '%s\t%s\n' "$job" "$invocations" >> "$WORKDIR/counts.tsv"
    if [ "$accounted" -ne "$corpus_count" ]; then
        printf '%s (accounted for %s of %s rows)\n' "$job" "$accounted" "$corpus_count" >> "$FAILURES"
    fi
done < "$POOL_QUEUE"

# Scalar O1 is the default-level reference for every mode and level.
if simd_mode_selected scalar; then
    NATIVE_WORKDIR=$WORKDIR
fi
while IFS='|' read -r prog tag; do
    reference="$NATIVE_WORKDIR/$tag.scalar"
    scalar_code=
    if [ -s "$reference.exit" ] && [ -f "$reference.err" ] && [ ! -s "$reference.err" ]; then
        IFS= read -r scalar_code < "$reference.exit"
    fi
    case "$scalar_code" in
        "" | *[!0-9]*)
            printf '%s (missing or invalid O1 scalar reference)\n' "$prog" >> "$FAILURES"
            continue
            ;;
    esac
    while IFS='|' read -r job unused; do
        mode=${job%-*}
        opt=${job##*-}
        spmd_row_base "$tag" "$mode" "$opt"
        [ -f "$base.exit" ] || continue
        IFS= read -r mode_code < "$base.exit"
        if [ "$mode_code" != "$scalar_code" ]; then
            printf '%s %s O%s (exit %s vs O1 scalar %s)\n' \
                "$prog" "$mode" "$opt" "$mode_code" "$scalar_code" >> "$FAILURES"
        fi
    done < "$POOL_QUEUE"
done < "$CORPUS"

if ! TYPELISP_BIN=$COMPILER CODEGEN_CASES_WORKDIR="$WORKDIR/cases" \
    sh "$ROOT/scripts/verify-codegen-cases.sh" tests/spmd/simd.d; then
    echo "tests/spmd/simd.d" >> "$FAILURES"
fi

simd_execution_summary spmd-simd
if [ "$pool_status" -ne 0 ] || [ -s "$FAILURES" ]; then
    echo "spmd-simd verification FAILED:" >&2
    sed 's/^/  /' "$FAILURES" >&2
    exit 1
fi
echo "spmd-simd verification passed (host=$HOST_OS, native-isas='$(printf '%s' "$SIMDEX_NATIVE_ISAS" | tr '\n' ' ')')"
