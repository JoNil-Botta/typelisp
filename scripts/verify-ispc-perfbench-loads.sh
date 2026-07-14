#!/usr/bin/env sh
set -eu

# Required TypeLisp corpus correctness and optional real ISPC correctness for
# benchmarks/ispc/perfbench_loads (#4973). The generic reporting harness is
# tracked separately by #4968.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

CASE_DIR="$ROOT/benchmarks/ispc/perfbench_loads"
METADATA="$CASE_DIR/case.tsv"
WORKDIR="$ROOT/target/ispc-perfbench-loads-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

for required in bench.tl kernel.ispc driver.c case.tsv LICENSE.BSD-3-Clause; do
    [ -f "$CASE_DIR/$required" ] || {
        echo "perfbench_loads: missing $required" >&2
        exit 1
    }
done

awk -F '\t' '
BEGIN {
    expected_header = "schema\tcase\tmode\ttypelisp_status\ttypelisp_diagnostic\tispc_status\tispc_diagnostic\tispc_target\tgang_width\tlane_type\ttypelisp_source\ttypelisp_symbol\tispc_source\tispc_symbol\tdriver\targuments\trepetitions\texpected_exit\tupstream_tag\tupstream_commit\tupstream_path\tupstream_function\tlicense"
    scalar_ispc_diag = "ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4"
    commit = "c6adb4f86f5678ce6c41951b1e2b59f727455697"
}
NR == 1 {
    if ($0 != expected_header) {
        print "perfbench_loads: invalid case.tsv header" > "/dev/stderr"
        exit 1
    }
    next
}
{
    if (NF != 23 || $1 != "typelisp-ispc-case-v1" ||
        $2 != "perfbench_loads" || $4 != "supported" || $5 != "" ||
        $10 != "f32" || $11 != "bench.tl" ||
        $12 != "loads" || $13 != "kernel.ispc" || $14 != "loads" ||
        $15 != "driver.c" ||
        $16 != "array:f32[];count:i32;zeros:f32[];result:f32[1]" ||
        $17 != "100" || $18 != "42" ||
        $19 != "v1.31.0" || $20 != commit ||
        $21 != "examples/cpu/perfbench/perfbench.ispc" ||
        $22 != "loads" || $23 != "BSD-3-Clause") {
        print "perfbench_loads: invalid metadata row " NR > "/dev/stderr"
        exit 1
    }
    if ($3 == "scalar" && ($6 != "unsupported" ||
        $7 != scalar_ispc_diag || $8 != "none" || $9 != "1")) exit 1
    if ($3 == "avx2" && ($6 != "supported" || $7 != "" ||
        $8 != "avx2-i32x8" || $9 != "8")) exit 1
    if ($3 == "avx512" && ($6 != "supported" || $7 != "" ||
        $8 != "avx512skx-x16" || $9 != "16")) exit 1
    seen[$3]++
}
END {
    if (NR != 4 || seen["scalar"] != 1 || seen["avx2"] != 1 ||
        seen["avx512"] != 1) {
        print "perfbench_loads: expected scalar/avx2/avx512 metadata rows" > "/dev/stderr"
        exit 1
    }
}
' "$METADATA"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || {
    echo "perfbench_loads: TypeLisp compiler is not executable: $COMPILER" >&2
    exit 1
}

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "perfbench_loads: unsupported host" >&2
        exit 1
        ;;
esac

if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || {
        echo "perfbench_loads: missing assembler: as" >&2
        exit 1
    }
    command -v ld >/dev/null 2>&1 || {
        echo "perfbench_loads: missing linker: ld" >&2
        exit 1
    }
fi

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")
typelisp_mode_runnable() {
    case "$1" in
        scalar) return 0 ;;
        avx2) printf '%s\n' "$SIMD_ISAS" | grep -qx avx2 ;;
        avx512) printf '%s\n' "$SIMD_ISAS" | grep -qx avx512bw ;;
        *) return 1 ;;
    esac
}

for mode in scalar avx2 avx512; do
    stdout="$WORKDIR/typelisp-$mode.stdout"
    stderr="$WORKDIR/typelisp-$mode.stderr"
    asm="$WORKDIR/typelisp-$mode.s"
    if ! "$COMPILER" compile "$CASE_DIR/bench.tl" \
        --backend-mode "$mode" --opt-level 2 --stdlib-root "$ROOT/stdlib" \
        -o "$asm" > "$stdout" 2> "$stderr"; then
        echo "perfbench_loads: TypeLisp $mode compile failed" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
    [ -s "$asm" ] || {
        echo "perfbench_loads: TypeLisp $mode emitted no assembly" >&2
        exit 1
    }
    case "$mode" in
        scalar)
            grep -q 'addss' "$asm" || {
                echo "perfbench_loads: TypeLisp scalar assembly lacks f32 add" >&2
                exit 1
            }
            ;;
        avx2)
            grep -q 'vaddps' "$asm" || {
                echo "perfbench_loads: TypeLisp AVX2 assembly lacks packed f32 add" >&2
                exit 1
            }
            ;;
        avx512)
            grep -q 'vextractf32x8' "$asm" || {
                echo "perfbench_loads: TypeLisp AVX-512 assembly lacks f32 horizontal extract" >&2
                exit 1
            }
            ;;
    esac

    if typelisp_mode_runnable "$mode"; then
        run_stdout="$WORKDIR/typelisp-$mode.run.stdout"
        run_stderr="$WORKDIR/typelisp-$mode.run.stderr"
        if [ "$HOST_OS" = linux ]; then
            obj="$WORKDIR/typelisp-$mode.o"
            bin="$WORKDIR/typelisp-$mode"
            as "$asm" -o "$obj"
            ld "$obj" -o "$bin" -static -e "$(linux_entry_symbol_for_asm "$asm")"
            set +e
            "$bin" > "$run_stdout" 2> "$run_stderr"
            status=$?
            set -e
        else
            set +e
            "$COMPILER" run "$CASE_DIR/bench.tl" \
                --backend-mode "$mode" --opt-level 2 --stdlib-root "$ROOT/stdlib" \
                > "$run_stdout" 2> "$run_stderr"
            status=$?
            set -e
        fi
        if [ "$status" -ne 42 ] || [ -s "$run_stdout" ] || [ -s "$run_stderr" ]; then
            echo "perfbench_loads: TypeLisp $mode correctness failed (exit $status)" >&2
            sed 's/^/  /' "$run_stdout" >&2 || true
            sed 's/^/  /' "$run_stderr" >&2 || true
            exit 1
        fi
        echo "perfbench_loads TypeLisp $mode correctness passed"
    else
        echo "perfbench_loads TypeLisp $mode execution skipped (host ISA unavailable; compile shape passed)"
    fi
done

ISPC=${ISPC_BIN:-}
if [ -z "$ISPC" ]; then
    ISPC=$(command -v ispc 2>/dev/null || true)
fi
if [ -z "$ISPC" ]; then
    echo "perfbench_loads optional ISPC correctness skipped (set ISPC_BIN to ISPC v1.31.0)"
    exit 0
fi

ISPC_VERSION=$("$ISPC" --version 2>&1 | sed -n '1p')
case "$ISPC_VERSION" in
    *1.31.0*) ;;
    *)
        echo "perfbench_loads: ISPC v1.31.0 required, got: $ISPC_VERSION" >&2
        exit 1
        ;;
esac

CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || {
    echo "perfbench_loads: C compiler not found: $CC" >&2
    exit 1
}

run_ispc_target() {
    mode=$1
    target=$2
    outdir="$WORKDIR/ispc-$mode"
    mkdir -p "$outdir"
    "$ISPC" "$CASE_DIR/kernel.ispc" -O2 --arch=x86-64 --target="$target" \
        -o "$outdir/kernel.o" --header-outfile="$outdir/kernel_ispc.h" \
        > "$outdir/ispc.stdout" 2> "$outdir/ispc.stderr"
    "$CC" -O2 -I"$outdir" "$CASE_DIR/driver.c" "$outdir/kernel.o" \
        -o "$outdir/driver" > "$outdir/cc.stdout" 2> "$outdir/cc.stderr"
    set +e
    "$outdir/driver" > "$outdir/run.stdout" 2> "$outdir/run.stderr"
    status=$?
    set -e
    if [ "$status" -ne 42 ] || [ -s "$outdir/run.stdout" ] || [ -s "$outdir/run.stderr" ]; then
        echo "perfbench_loads: ISPC $mode correctness failed (exit $status)" >&2
        sed 's/^/  /' "$outdir/run.stdout" >&2 || true
        sed 's/^/  /' "$outdir/run.stderr" >&2 || true
        exit 1
    fi
    echo "perfbench_loads ISPC $mode correctness passed ($target)"
}

# v1.31.0 has no width-1 CPU target. Run its smallest generic target only to
# validate the derived kernel/oracle; never report it as a scalar comparison.
run_ispc_target generic-min-width generic-i32x4
if printf '%s\n' "$SIMD_ISAS" | grep -qx avx2; then
    run_ispc_target avx2 avx2-i32x8
else
    echo "perfbench_loads optional ISPC AVX2 run skipped (host lacks AVX2)"
fi
if [ "${ISPC_PERFBENCH_LOADS_AVX512:-0}" = 1 ]; then
    if printf '%s\n' "$SIMD_ISAS" | grep -qx avx512bw; then
        run_ispc_target avx512 avx512skx-x16
    else
        echo "perfbench_loads: AVX-512 requested but host lacks AVX-512BW" >&2
        exit 1
    fi
fi
