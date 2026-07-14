#!/usr/bin/env sh
set -eu

# Required TypeLisp/C-oracle correctness plus optional real ISPC comparison
# for benchmarks/ispc/perfbench_stores (#4972).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

CASE_DIR="$ROOT/benchmarks/ispc/perfbench_stores"
METADATA="$CASE_DIR/case.tsv"
WORKDIR="$ROOT/target/ispc-perfbench-stores-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

for required in bench.tl kernel.ispc driver.c case.tsv README.md LICENSE.BSD-3-Clause; do
    [ -f "$CASE_DIR/$required" ] || {
        echo "perfbench_stores: missing $required" >&2
        exit 1
    }
done

awk -F '\t' '
BEGIN {
    header = "schema\tcase\tmode\ttypelisp_status\ttypelisp_diagnostic\tispc_status\tispc_diagnostic\tispc_target\tgang_width\tlane_type\ttypelisp_source\ttypelisp_symbol\tispc_source\tispc_symbol\tdriver\targuments\trepetitions\texpected_exit\tupstream_tag\tupstream_commit\tupstream_path\tupstream_function\tlicense"
    scalar_diag = "ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4"
    commit = "c6adb4f86f5678ce6c41951b1e2b59f727455697"
}
NR == 1 { if ($0 != header) exit 1; next }
{
    if (NF != 23 || $1 != "typelisp-ispc-case-v1" ||
        $2 != "perfbench_stores" || $4 != "supported" || $5 != "" ||
        $10 != "f32" || $11 != "bench.tl" || $12 != "stores" ||
        $13 != "kernel.ispc" || $14 != "stores" || $15 != "driver.c" ||
        $16 != "array:f32[];count:i32;zeros:f32[];result:f32[1]" ||
        $17 != "100" || $19 != "v1.31.0" || $20 != commit ||
        $21 != "examples/cpu/perfbench/perfbench.ispc" ||
        $22 != "stores" || $23 != "BSD-3-Clause") exit 1
    if ($3 == "scalar" && ($6 != "unsupported" || $7 != scalar_diag ||
        $8 != "none" || $9 != "1" || $18 != "42")) exit 1
    if ($3 == "avx2" && ($6 != "supported" || $7 != "" ||
        $8 != "avx2-i32x8" || $9 != "8" || $18 != "49")) exit 1
    if ($3 == "avx512" && ($6 != "supported" || $7 != "" ||
        $8 != "avx512skx-x16" || $9 != "16" || $18 != "57")) exit 1
    seen[$3]++
}
END {
    if (NR != 4 || seen["scalar"] != 1 || seen["avx2"] != 1 ||
        seen["avx512"] != 1) exit 1
}
' "$METADATA" || {
    echo "perfbench_stores: invalid case.tsv" >&2
    exit 1
}

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
    echo "perfbench_stores: TypeLisp compiler is not executable: $COMPILER" >&2
    exit 1
}

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) echo "perfbench_stores: unsupported host" >&2; exit 1 ;;
esac
SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")
isa_available() { printf '%s\n' "$SIMD_ISAS" | grep -qx "$1"; }

STATIC_TSV="$WORKDIR/static.tsv"
printf 'implementation\tmode\tsymbol\tasm_sha256\tbytes\tinstructions\tbranches\tcalls\tvector_instructions\tstack_accesses\n' > "$STATIC_TSV"
record_static() {
    implementation=$1 mode=$2 asm=$3 symbol=$4
    body="$WORKDIR/$implementation-$mode.kernel.s"
    awk -v label="$symbol:" '
        index($0, label) == 1 { inside = 1 }
        inside && index($0, label) != 1 && /^[[:space:]]*\.globl[[:space:]]/ { exit }
        inside { print }
    ' "$asm" > "$body"
    [ -s "$body" ] || {
        echo "perfbench_stores: symbol not found in $asm: $symbol" >&2
        exit 1
    }
    hash=$(sha256sum "$body" | awk '{print $1}')
    bytes=$(wc -c < "$body" | tr -d ' ')
    instructions=$(awk '/^[[:space:]]+[A-Za-z][A-Za-z0-9.]*/ { n++ } END { print n+0 }' "$body")
    branches=$(awk '/^[[:space:]]+j[A-Za-z]+[[:space:]]/ { n++ } END { print n+0 }' "$body")
    calls=$(awk '/^[[:space:]]+call[A-Za-z]*[[:space:]]/ { n++ } END { print n+0 }' "$body")
    vectors=$(awk '
        /^[[:space:]]+[A-Za-z][A-Za-z0-9.]*/ && /%[xyz]mm[0-9]+/ { n++ }
        END { print n+0 }
    ' "$body")
    stack=$(awk '/\(%r(bp|sp)\)/ { n++ } END { print n+0 }' "$body")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$implementation" "$mode" "$symbol" "$hash" "$bytes" \
        "$instructions" "$branches" "$calls" "$vectors" "$stack" >> "$STATIC_TSV"
}

run_typelisp_mode() {
    mode=$1 expected=$2 runnable=$3
    asm="$WORKDIR/typelisp-$mode.s"
    "$COMPILER" compile "$CASE_DIR/bench.tl" --backend-mode "$mode" \
        --opt-level 2 --stdlib-root "$ROOT/stdlib" -o "$asm" \
        > "$WORKDIR/typelisp-$mode.compile.stdout" \
        2> "$WORKDIR/typelisp-$mode.compile.stderr"
    record_static typelisp "$mode" "$asm" _tl_bench_stores
    if [ "$runnable" != 1 ]; then
        echo "perfbench_stores TypeLisp $mode compile passed (host cannot run mode)"
        return
    fi
    set +e
    "$COMPILER" run "$CASE_DIR/bench.tl" --backend-mode "$mode" \
        --opt-level 2 --stdlib-root "$ROOT/stdlib" \
        > "$WORKDIR/typelisp-$mode.run.stdout" \
        2> "$WORKDIR/typelisp-$mode.run.stderr"
    status=$?
    set -e
    if [ "$status" -ne "$expected" ] ||
       [ -s "$WORKDIR/typelisp-$mode.run.stdout" ] ||
       [ -s "$WORKDIR/typelisp-$mode.run.stderr" ]; then
        echo "perfbench_stores: TypeLisp $mode correctness failed (exit $status, expected $expected)" >&2
        sed 's/^/  /' "$WORKDIR/typelisp-$mode.run.stdout" >&2 || true
        sed 's/^/  /' "$WORKDIR/typelisp-$mode.run.stderr" >&2 || true
        exit 1
    fi
    echo "perfbench_stores TypeLisp $mode correctness passed"
}

run_typelisp_mode scalar 42 1
if isa_available avx2; then run_typelisp_mode avx2 49 1; else run_typelisp_mode avx2 49 0; fi
if isa_available avx512; then run_typelisp_mode avx512 57 1; else run_typelisp_mode avx512 57 0; fi

CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || {
    echo "perfbench_stores: C compiler not found: $CC" >&2
    exit 1
}
"$CC" -O2 -DEXPECTED_GANG_WIDTH=1 "$CASE_DIR/driver.c" \
    -o "$WORKDIR/scalar-oracle" > "$WORKDIR/scalar-cc.stdout" 2> "$WORKDIR/scalar-cc.stderr"
set +e
"$WORKDIR/scalar-oracle" > "$WORKDIR/scalar-run.stdout" 2> "$WORKDIR/scalar-run.stderr"
status=$?
set -e
if [ "$status" -ne 42 ] || [ -s "$WORKDIR/scalar-run.stdout" ] || [ -s "$WORKDIR/scalar-run.stderr" ]; then
    echo "perfbench_stores: scalar C oracle failed (exit $status)" >&2
    exit 1
fi
echo "perfbench_stores scalar C oracle passed"

ISPC=${ISPC_BIN:-}
if [ -z "$ISPC" ]; then ISPC=$(command -v ispc 2>/dev/null || true); fi
if [ -z "$ISPC" ]; then
    echo "perfbench_stores optional ISPC comparison skipped (set ISPC_BIN to ISPC v1.31.0)"
    exit 0
fi
ISPC_VERSION=$("$ISPC" --version 2>&1 | sed -n '1p')
case "$ISPC_VERSION" in
    *1.31.0*) ;;
    *) echo "perfbench_stores: ISPC v1.31.0 required, got: $ISPC_VERSION" >&2; exit 1 ;;
esac

run_ispc_target() {
    mode=$1 target=$2 width=$3 expected=$4
    outdir="$WORKDIR/ispc-$mode"
    mkdir -p "$outdir"
    "$ISPC" "$CASE_DIR/kernel.ispc" -O2 --arch=x86-64 --target="$target" \
        --emit-asm -o "$outdir/kernel.s" \
        > "$outdir/ispc-s.stdout" 2> "$outdir/ispc-s.stderr"
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
    if [ "$status" -ne "$expected" ] || [ -s "$outdir/run.stdout" ] || [ -s "$outdir/run.stderr" ]; then
        echo "perfbench_stores: ISPC $mode correctness failed (exit $status, expected $expected)" >&2
        sed 's/^/  /' "$outdir/run.stderr" >&2 || true
        exit 1
    fi
    ispc_symbol=$(awk '
        /^stores___[A-Za-z0-9_]*:/ { sub(/:.*/, ""); print; exit }
    ' "$outdir/kernel.s")
    [ -n "$ispc_symbol" ] || {
        echo "perfbench_stores: ISPC internal kernel symbol not found" >&2
        exit 1
    }
    record_static ispc "$mode" "$outdir/kernel.s" "$ispc_symbol"
    echo "perfbench_stores ISPC $mode correctness passed ($target)"
}

# Generic x4 validates the isolated upstream kernel but is never a scalar pair.
run_ispc_target generic-min-width generic-i32x4 4 45
if isa_available avx2; then
    run_ispc_target avx2 avx2-i32x8 8 49
else
    echo "perfbench_stores optional ISPC AVX2 run skipped (host lacks AVX2)"
fi
if [ "${ISPC_PERFBENCH_STORES_AVX512:-0}" = 1 ]; then
    if isa_available avx512; then
        run_ispc_target avx512 avx512skx-x16 16 57
    else
        echo "perfbench_stores: AVX-512 requested but host lacks runnable F+BW+DQ" >&2
        exit 1
    fi
fi

echo "perfbench_stores verification passed; static report: $STATIC_TSV"
