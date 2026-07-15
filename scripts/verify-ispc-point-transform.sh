#!/usr/bin/env sh
set -eu

# Required TypeLisp/C-oracle correctness plus optional real ISPC v1.31.0
# comparison for benchmarks/ispc/point_transform (#4975).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

CASE_DIR="$ROOT/benchmarks/ispc/point_transform"
METADATA="$CASE_DIR/case.tsv"
WORKDIR="$ROOT/target/ispc-point-transform-verify"
STATIC="$WORKDIR/static.tsv"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

for required in bench.tl kernel.ispc driver.c case.tsv README.md LICENSE.BSD-3-Clause; do
    [ -f "$CASE_DIR/$required" ] || {
        echo "point_transform: missing $required" >&2
        exit 1
    }
done

awk -F '\t' '
BEGIN {
    header = "schema\tcase\tmode\ttypelisp_status\ttypelisp_diagnostic\tispc_status\tispc_diagnostic\tispc_target\tgang_width\tlane_type\ttypelisp_source\ttypelisp_symbol\tispc_source\tispc_symbol\tdriver\targuments\trepetitions\texpected_exit\tupstream_tag\tupstream_commit\tupstream_path\tupstream_function\tlicense"
    scalar_diag = "ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4"
    args = "points_x:f32[];points_y:f32[];result_x:f32[];result_y:f32[];scale_x:f32;scale_y:f32;translate_x:f32;translate_y:f32;sin_theta:f32;cos_theta:f32;strength:f32;count:i32"
    commit = "c6adb4f86f5678ce6c41951b1e2b59f727455697"
}
NR == 1 { if ($0 != header) exit 1; next }
{
    if (NF != 23 || $1 != "typelisp-ispc-case-v1" ||
        $2 != "point_transform" || $4 != "supported" || $5 != "" ||
        $10 != "f32" || $11 != "bench.tl" || $12 != "transform-points" ||
        $13 != "kernel.ispc" || $14 != "transform_points" ||
        $15 != "driver.c" || $16 != args || $17 != "100" || $18 != "42" ||
        $19 != "v1.31.0" || $20 != commit ||
        $21 != "examples/cpu/point_transform_ctypes/point_transform.ispc" ||
        $22 != "transform_points" || $23 != "BSD-3-Clause") exit 1
    if ($3 == "scalar" && ($6 != "unsupported" || $7 != scalar_diag ||
        $8 != "none" || $9 != "1")) exit 1
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
    echo "point_transform: invalid case.tsv metadata" >&2
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
    echo "point_transform: TypeLisp compiler is not executable: $COMPILER" >&2
    exit 1
}

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) echo "point_transform: unsupported host" >&2; exit 1 ;;
esac
if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || { echo "point_transform: missing as" >&2; exit 1; }
    command -v ld >/dev/null 2>&1 || { echo "point_transform: missing ld" >&2; exit 1; }
fi

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")
has_isa() { printf '%s\n' "$SIMD_ISAS" | grep -qx "$1"; }

printf 'implementation\tmode\tsymbol\tasm_sha256\tasm_bytes\tinstructions\tbranches\tcalls\tpacked_f32_ops\tfma_ops\tregisters\tgpr_registers\tvector_registers\tmask_registers\tstack_accesses\tspill_candidates\n' > "$STATIC"

extract_symbol() {
    _asm=$1
    _symbol=$2
    _out=$3
    awk -v label="$_symbol:" '
        index($0, label) == 1 { active = 1 }
        active && index($0, label) != 1 && /^[[:space:]]*\.globl[[:space:]]/ { exit }
        active { print }
        active && /^[[:space:]]*\.size[[:space:]]/ { exit }
    ' "$_asm" > "$_out"
    [ -s "$_out" ]
}

count_unique_registers() {
    _pattern=$1
    _body=$2
    { grep -Eo "$_pattern" "$_body" || true; } | sort -u | awk 'NF { n++ } END { print n+0 }'
}

record_static() {
    _impl=$1
    _mode=$2
    _asm=$3
    _symbol=$4
    _body="$WORKDIR/$_impl-$_mode.kernel.s"
    extract_symbol "$_asm" "$_symbol" "$_body" || {
        echo "point_transform: missing $_impl $_mode symbol $_symbol" >&2
        exit 1
    }
    _hash=$(sha256sum "$_body" | awk '{print $1}')
    _bytes=$(wc -c < "$_body" | tr -d ' ')
    _instructions=$(awk '/^[[:space:]]+[A-Za-z][A-Za-z0-9.]*/ { n++ } END { print n+0 }' "$_body")
    _branches=$(grep -E -c '^[[:space:]]+j[a-z]+' "$_body" || true)
    _calls=$(grep -E -c '^[[:space:]]+call' "$_body" || true)
    _packed=$(grep -E -c '^[[:space:]]+v?(add|sub|mul)ps[[:space:]]' "$_body" || true)
    _fma=$(grep -E -c '^[[:space:]]+v?fm(add|sub)' "$_body" || true)
    _registers=$(count_unique_registers '%[A-Za-z][A-Za-z0-9]*' "$_body")
    _gprs=$(count_unique_registers '%(r(ax|bx|cx|dx|si|di|sp|bp)|r(8|9|1[0-5])|e(ax|bx|cx|dx|si|di|sp|bp)|r(8|9|1[0-5])d)' "$_body")
    _vectors=$(count_unique_registers '%[xyz]mm[0-9]+' "$_body")
    _masks=$(count_unique_registers '%k[0-7]' "$_body")
    _stack=$(grep -E -c '\(%(rsp|rbp)\)' "$_body" || true)
    _spills=$(grep -E -c '^[[:space:]]+(v?mov)[A-Za-z0-9]* .*\(%(rsp|rbp)\)' "$_body" || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_impl" "$_mode" "$_symbol" "$_hash" "$_bytes" \
        "$_instructions" "$_branches" "$_calls" "$_packed" "$_fma" \
        "$_registers" "$_gprs" "$_vectors" "$_masks" "$_stack" "$_spills" >> "$STATIC"
}

run_typelisp_mode() {
    _mode=$1
    _asm="$WORKDIR/typelisp-$_mode.s"
    "$COMPILER" compile "$CASE_DIR/bench.tl" --backend-mode "$_mode" \
        --opt-level 2 --stdlib-root "$ROOT/stdlib" -o "$_asm" \
        > "$WORKDIR/typelisp-$_mode.compile.stdout" \
        2> "$WORKDIR/typelisp-$_mode.compile.stderr"
    record_static typelisp "$_mode" "$_asm" _tl_bench_transform_points
    case "$_mode" in
        scalar)
            grep -q 'mulss' "$_asm" && grep -Eq '(addss|subss)' "$_asm" || {
                echo "point_transform: TypeLisp scalar assembly lacks f32 transform shape" >&2
                exit 1
            }
            ;;
        avx2)
            grep -q '%ymm' "$_asm" && grep -q 'vmulps' "$_asm" &&
                grep -Eq 'v(add|sub)ps' "$_asm" || {
                echo "point_transform: TypeLisp AVX2 assembly lacks packed-f32 x8 shape" >&2
                exit 1
            }
            ;;
        avx512)
            grep -q '%zmm' "$_asm" && grep -q 'vmulps' "$_asm" &&
                grep -Eq 'v(add|sub)ps' "$_asm" || {
                echo "point_transform: TypeLisp AVX-512 assembly lacks packed-f32 x16 shape" >&2
                exit 1
            }
            ;;
    esac
    if [ "$_mode" != scalar ] && ! has_isa "$_mode"; then
        echo "point_transform TypeLisp $_mode execution skipped (host ISA unavailable; compile shape passed)"
        return
    fi
    if [ "$HOST_OS" = linux ]; then
        _obj="$WORKDIR/typelisp-$_mode.o"
        _bin="$WORKDIR/typelisp-$_mode"
        as "$_asm" -o "$_obj"
        ld "$_obj" -o "$_bin" -static -e "$(linux_entry_symbol_for_asm "$_asm")"
        set +e
        "$_bin" > "$WORKDIR/typelisp-$_mode.run.stdout" 2> "$WORKDIR/typelisp-$_mode.run.stderr"
        _status=$?
        set -e
    else
        set +e
        "$COMPILER" run "$CASE_DIR/bench.tl" --backend-mode "$_mode" \
            --opt-level 2 --stdlib-root "$ROOT/stdlib" \
            > "$WORKDIR/typelisp-$_mode.run.stdout" 2> "$WORKDIR/typelisp-$_mode.run.stderr"
        _status=$?
        set -e
    fi
    if [ "$_status" -ne 42 ] ||
       [ -s "$WORKDIR/typelisp-$_mode.run.stdout" ] ||
       [ -s "$WORKDIR/typelisp-$_mode.run.stderr" ]; then
        echo "point_transform: TypeLisp $_mode correctness failed (exit $_status)" >&2
        sed 's/^/  /' "$WORKDIR/typelisp-$_mode.run.stderr" >&2 || true
        exit 1
    fi
    echo "point_transform TypeLisp $_mode correctness passed"
}

run_typelisp_mode scalar
run_typelisp_mode avx2
run_typelisp_mode avx512

CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || {
    echo "point_transform: C compiler not found: $CC" >&2
    exit 1
}
"$CC" -O2 -ffp-contract=off "$CASE_DIR/driver.c" -o "$WORKDIR/scalar-oracle" \
    > "$WORKDIR/scalar-cc.stdout" 2> "$WORKDIR/scalar-cc.stderr"
set +e
"$WORKDIR/scalar-oracle" > "$WORKDIR/scalar-run.stdout" 2> "$WORKDIR/scalar-run.stderr"
_status=$?
set -e
if [ "$_status" -ne 42 ] || [ -s "$WORKDIR/scalar-run.stdout" ] ||
   [ -s "$WORKDIR/scalar-run.stderr" ]; then
    echo "point_transform: scalar C oracle failed (exit $_status)" >&2
    sed 's/^/  /' "$WORKDIR/scalar-run.stderr" >&2 || true
    exit 1
fi
echo "point_transform scalar C oracle passed"

ISPC=${ISPC_BIN:-}
if [ -z "$ISPC" ]; then ISPC=$(command -v ispc 2>/dev/null || true); fi
if [ -z "$ISPC" ]; then
    echo "point_transform optional ISPC comparison skipped (set ISPC_BIN to ISPC v1.31.0)"
    echo "point_transform static report: $STATIC"
    exit 0
fi
case "$("$ISPC" --version 2>&1 | sed -n '1p')" in
    *1.31.0*) ;;
    *) echo "point_transform: ISPC v1.31.0 required" >&2; exit 1 ;;
esac

run_ispc_target() {
    _mode=$1
    _target=$2
    _out="$WORKDIR/ispc-$_mode"
    mkdir -p "$_out"
    "$ISPC" "$CASE_DIR/kernel.ispc" -O2 --arch=x86-64 --target="$_target" \
        -o "$_out/kernel.o" --header-outfile="$_out/kernel_ispc.h" \
        > "$_out/ispc.stdout" 2> "$_out/ispc.stderr"
    "$ISPC" "$CASE_DIR/kernel.ispc" -O2 --arch=x86-64 --target="$_target" \
        --emit-asm -o "$_out/kernel.s" \
        > "$_out/ispc-s.stdout" 2> "$_out/ispc-s.stderr"
    "$CC" -O2 -ffp-contract=off -DUSE_ISPC -I"$_out" \
        "$CASE_DIR/driver.c" "$_out/kernel.o" -o "$_out/driver" \
        > "$_out/cc.stdout" 2> "$_out/cc.stderr"
    set +e
    "$_out/driver" > "$_out/run.stdout" 2> "$_out/run.stderr"
    _status=$?
    set -e
    if [ "$_status" -ne 42 ] || [ -s "$_out/run.stdout" ] || [ -s "$_out/run.stderr" ]; then
        echo "point_transform: ISPC $_mode correctness failed (exit $_status)" >&2
        sed 's/^/  /' "$_out/run.stderr" >&2 || true
        exit 1
    fi
    _symbol=$(nm --defined-only "$_out/kernel.o" | awk '$3 ~ /^transform_points___/ { print $3; exit }')
    [ -n "$_symbol" ] || {
        echo "point_transform: ISPC $_mode internal kernel symbol missing" >&2
        exit 1
    }
    record_static ispc "$_mode" "$_out/kernel.s" "$_symbol"
    echo "point_transform ISPC $_mode correctness passed ($_target)"
}

# v1.31.0 has no width-1 CPU target. Generic x4 validates the derived source
# and oracle only; it is never reported as a scalar codegen pair.
run_ispc_target generic-min-width generic-i32x4
if has_isa avx2; then
    run_ispc_target avx2 avx2-i32x8
else
    echo "point_transform optional ISPC AVX2 run skipped (host lacks AVX2)"
fi
if [ "${ISPC_POINT_TRANSFORM_AVX512:-0}" = 1 ]; then
    has_isa avx512 || {
        echo "point_transform: AVX-512 requested but host lacks runnable F+BW+DQ" >&2
        exit 1
    }
    run_ispc_target avx512 avx512skx-x16
fi

echo "point_transform verification passed; static report: $STATIC"
