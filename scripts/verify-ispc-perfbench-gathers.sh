#!/usr/bin/env sh
set -eu

# Required TypeLisp/C-oracle correctness and optional real ISPC comparison for
# benchmarks/ispc/perfbench_gathers (#4974).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

CASE_DIR="$ROOT/benchmarks/ispc/perfbench_gathers"
METADATA="$CASE_DIR/case.tsv"
WORKDIR="$ROOT/target/ispc-perfbench-gathers-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

for required in bench.tl bounds.tl kernel.ispc driver.c case.tsv LICENSE.BSD-3-Clause; do
    [ -f "$CASE_DIR/$required" ] || {
        echo "perfbench_gathers: missing $required" >&2
        exit 1
    }
done

awk -F '\t' '
BEGIN {
    expected_header = "schema\tcase\tmode\ttypelisp_status\ttypelisp_diagnostic\tispc_status\tispc_diagnostic\tispc_target\tgang_width\tlane_type\ttypelisp_source\ttypelisp_symbol\tispc_source\tispc_symbol\tdriver\targuments\trepetitions\texpected_exit\tupstream_tag\tupstream_commit\tupstream_path\tupstream_function\tlicense"
    scalar_diag = "ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4"
    commit = "c6adb4f86f5678ce6c41951b1e2b59f727455697"
}
NR == 1 {
    if ($0 != expected_header) exit 1
    next
}
{
    if (NF != 23 || $1 != "typelisp-ispc-case-v1" ||
        $2 != "perfbench_gathers" || $4 != "supported" || $5 != "" ||
        $10 != "f32" || $11 != "bench.tl" || $12 != "gathers" ||
        $13 != "kernel.ispc" || $14 != "gathers" || $15 != "driver.c" ||
        $16 != "array:f32[];count:i32;zeros:f32[];result:f32[1]" ||
        $17 != "100" || $18 != "42" || $19 != "v1.31.0" ||
        $20 != commit || $21 != "examples/cpu/perfbench/perfbench.ispc" ||
        $22 != "gathers" || $23 != "BSD-3-Clause") exit 1
    if ($3 == "scalar" && ($6 != "unsupported" ||
        $7 != scalar_diag || $8 != "none" || $9 != "1")) exit 1
    if ($3 == "avx2" && ($6 != "supported" || $7 != "" ||
        $8 != "avx2-i32x8" || $9 != "8")) exit 1
    if ($3 == "avx512" && ($6 != "supported" || $7 != "" ||
        $8 != "avx512skx-x16" || $9 != "16")) exit 1
    seen[$3]++
}
END {
    if (NR != 4 || seen["scalar"] != 1 || seen["avx2"] != 1 ||
        seen["avx512"] != 1) exit 1
}
' "$METADATA" || {
    echo "perfbench_gathers: invalid case.tsv" >&2
    exit 1
}

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in /* | [A-Za-z]:[\\/]*) ;; *) COMPILER="$ROOT/$COMPILER" ;; esac
[ -x "$COMPILER" ] || {
    echo "perfbench_gathers: TypeLisp compiler is not executable: $COMPILER" >&2
    exit 1
}

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) echo "perfbench_gathers: unsupported host" >&2; exit 1 ;;
esac
if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || { echo "perfbench_gathers: missing as" >&2; exit 1; }
    command -v ld >/dev/null 2>&1 || { echo "perfbench_gathers: missing ld" >&2; exit 1; }
fi

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")
mode_runnable() {
    case "$1" in
        scalar) return 0 ;;
        avx2) printf '%s\n' "$SIMD_ISAS" | grep -qx avx2 ;;
        avx512) printf '%s\n' "$SIMD_ISAS" | grep -qx avx512 ;;
        *) return 1 ;;
    esac
}

run_typelisp() {
    source=$1
    mode=$2
    tag=$3
    stdout="$WORKDIR/$tag-$mode.run.stdout"
    stderr="$WORKDIR/$tag-$mode.run.stderr"
    if [ "$HOST_OS" = linux ]; then
        asm="$WORKDIR/$tag-$mode.run.s"
        obj="$WORKDIR/$tag-$mode.run.o"
        bin="$WORKDIR/$tag-$mode.run"
        tool_stdout="$WORKDIR/$tag-$mode.run.tool.stdout"
        tool_stderr="$WORKDIR/$tag-$mode.run.tool.stderr"
        "$COMPILER" compile "$source" --backend-mode "$mode" --opt-level 2 \
            --stdlib-root "$ROOT/stdlib" -o "$asm" \
            > "$tool_stdout" 2> "$tool_stderr"
        as "$asm" -o "$obj" >> "$tool_stdout" 2>> "$tool_stderr"
        ld "$obj" -o "$bin" -static -e "$(linux_entry_symbol_for_asm "$asm")" \
            >> "$tool_stdout" 2>> "$tool_stderr"
        : > "$stdout"
        : > "$stderr"
        set +e
        "$bin" > "$stdout" 2> "$stderr"
        status=$?
        set -e
    else
        set +e
        "$COMPILER" run "$source" --backend-mode "$mode" --opt-level 2 \
            --stdlib-root "$ROOT/stdlib" > "$stdout" 2> "$stderr"
        status=$?
        set -e
    fi
}

for mode in scalar avx2 avx512; do
    asm="$WORKDIR/typelisp-$mode.s"
    stderr="$WORKDIR/typelisp-$mode.compile.stderr"
    "$COMPILER" compile "$CASE_DIR/bench.tl" --backend-mode "$mode" \
        --opt-level 2 --stdlib-root "$ROOT/stdlib" -o "$asm" \
        > "$WORKDIR/typelisp-$mode.compile.stdout" 2> "$stderr" || {
        sed 's/^/  /' "$stderr" >&2 || true
        echo "perfbench_gathers: TypeLisp $mode compile failed" >&2
        exit 1
    }
    case "$mode" in
        scalar)
            grep -q 'addss' "$asm" || { echo "perfbench_gathers: scalar lacks f32 add" >&2; exit 1; }
            if grep -q 'vgather' "$asm"; then
                echo "perfbench_gathers: scalar unexpectedly contains hardware gather" >&2
                exit 1
            fi
            ;;
        avx2)
            grep -q 'vgatherqps' "$asm" || { echo "perfbench_gathers: AVX2 lacks vgatherqps" >&2; exit 1; }
            grep -q 'vpaddq' "$asm" || { echo "perfbench_gathers: AVX2 lacks direct lane-offset indexes" >&2; exit 1; }
            grep -q 'vaddps' "$asm" || { echo "perfbench_gathers: AVX2 lacks f32 reduction" >&2; exit 1; }
            ;;
        avx512)
            grep -q 'vgatherqps' "$asm" || { echo "perfbench_gathers: AVX-512 lacks vgatherqps" >&2; exit 1; }
            grep -q 'vpaddq' "$asm" || { echo "perfbench_gathers: AVX-512 lacks direct lane-offset indexes" >&2; exit 1; }
            grep -q 'vextractf32x8' "$asm" || { echo "perfbench_gathers: AVX-512 lacks f32 reduction" >&2; exit 1; }
            ;;
    esac
    if mode_runnable "$mode"; then
        run_typelisp "$CASE_DIR/bench.tl" "$mode" typelisp
        if [ "$status" -ne 42 ] || [ -s "$stdout" ] || [ -s "$stderr" ]; then
            echo "perfbench_gathers: TypeLisp $mode correctness failed (exit $status)" >&2
            sed 's/^/  /' "$stdout" >&2 || true
            sed 's/^/  /' "$stderr" >&2 || true
            exit 1
        fi
        echo "perfbench_gathers TypeLisp $mode correctness passed"

        run_typelisp "$CASE_DIR/bounds.tl" "$mode" gather-reduce-oob
        if [ "$status" -ne 134 ] ||
            ! grep -F -- "tl: array index out of bounds" "$stderr" >/dev/null; then
            echo "perfbench_gathers: TypeLisp $mode gather bounds trap failed (exit $status)" >&2
            sed 's/^/  /' "$stderr" >&2 || true
            exit 1
        fi
        echo "perfbench_gathers TypeLisp $mode bounds trap passed"
    else
        echo "perfbench_gathers TypeLisp $mode execution skipped (host ISA unavailable)"
    fi
done

scatter_stderr="$WORKDIR/scatter-reject.stderr"
if "$COMPILER" check "$ROOT/tests/safety/spmd_unmasked_scatter_index_reject.tl" \
    --stdlib-root "$ROOT/stdlib" > "$WORKDIR/scatter-reject.stdout" 2> "$scatter_stderr"; then
    echo "perfbench_gathers: ordinary scatter unexpectedly typechecked" >&2
    exit 1
fi
grep -F -- "foreach does not support non-contiguous array-set! destination indexes" \
    "$scatter_stderr" >/dev/null || {
    echo "perfbench_gathers: ordinary scatter rejection diagnostic changed" >&2
    sed 's/^/  /' "$scatter_stderr" >&2 || true
    exit 1
}
echo "perfbench_gathers ordinary scatter rejection passed"

CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || {
    echo "perfbench_gathers: C compiler not found: $CC" >&2
    exit 1
}
"$CC" -O2 -DEXPECTED_GANG_WIDTH=1 "$CASE_DIR/driver.c" \
    -o "$WORKDIR/scalar-driver" > "$WORKDIR/scalar-cc.stdout" 2> "$WORKDIR/scalar-cc.stderr"
set +e
"$WORKDIR/scalar-driver" > "$WORKDIR/scalar-run.stdout" 2> "$WORKDIR/scalar-run.stderr"
status=$?
set -e
if [ "$status" -ne 42 ] || [ -s "$WORKDIR/scalar-run.stdout" ] ||
    [ -s "$WORKDIR/scalar-run.stderr" ]; then
    echo "perfbench_gathers: scalar C oracle failed (exit $status)" >&2
    exit 1
fi
echo "perfbench_gathers scalar C oracle passed"

ISPC=${ISPC_BIN:-}
if [ -z "$ISPC" ]; then ISPC=$(command -v ispc 2>/dev/null || true); fi
if [ -z "$ISPC" ]; then
    echo "perfbench_gathers optional ISPC comparison skipped (set ISPC_BIN to ISPC v1.31.0)"
    exit 0
fi
case "$("$ISPC" --version 2>&1 | sed -n '1p')" in
    *1.31.0*) ;;
    *) echo "perfbench_gathers: ISPC v1.31.0 required" >&2; exit 1 ;;
esac

run_ispc_target() {
    mode=$1
    target=$2
    width=$3
    outdir="$WORKDIR/ispc-$mode"
    mkdir -p "$outdir"
    "$ISPC" "$CASE_DIR/kernel.ispc" -O2 --arch=x86-64 --target="$target" \
        -o "$outdir/kernel.o" --header-outfile="$outdir/kernel_ispc.h" \
        > "$outdir/ispc.stdout" 2> "$outdir/ispc.stderr"
    "$CC" -O2 -DEXPECTED_GANG_WIDTH="$width" -I"$outdir" \
        "$CASE_DIR/driver.c" "$outdir/kernel.o" -o "$outdir/driver" \
        > "$outdir/cc.stdout" 2> "$outdir/cc.stderr"
    set +e
    "$outdir/driver" > "$outdir/run.stdout" 2> "$outdir/run.stderr"
    status=$?
    set -e
    if [ "$status" -ne 42 ] || [ -s "$outdir/run.stdout" ] ||
        [ -s "$outdir/run.stderr" ]; then
        echo "perfbench_gathers: ISPC $mode correctness failed (exit $status)" >&2
        sed 's/^/  /' "$outdir/run.stderr" >&2 || true
        exit 1
    fi
    echo "perfbench_gathers ISPC $mode correctness passed ($target)"
}

run_ispc_target generic-min-width generic-i32x4 4
if mode_runnable avx2; then
    run_ispc_target avx2 avx2-i32x8 8
else
    echo "perfbench_gathers optional ISPC AVX2 run skipped (host lacks AVX2)"
fi
if [ "${ISPC_PERFBENCH_GATHERS_AVX512:-0}" = 1 ]; then
    if mode_runnable avx512; then
        run_ispc_target avx512 avx512skx-x16 16
    else
        echo "perfbench_gathers: AVX-512 requested but host lacks runnable F+BW+DQ" >&2
        exit 1
    fi
fi

echo "perfbench_gathers verification passed"
