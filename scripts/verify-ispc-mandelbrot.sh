#!/usr/bin/env sh
set -eu

# Required TypeLisp correctness and optional ISPC v1.31.0 correctness for the
# Mandelbrot varying-loop comparison corpus (#4976).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

CASE_DIR="$ROOT/benchmarks/ispc/mandelbrot"
METADATA="$CASE_DIR/case.tsv"
WORKDIR="$ROOT/target/ispc-mandelbrot-verify"
STATIC="$WORKDIR/static.tsv"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

for required in bench.tl kernel.ispc driver.c case.tsv README.md LICENSE.BSD-3-Clause; do
    [ -f "$CASE_DIR/$required" ] || {
        echo "mandelbrot: missing $required" >&2
        exit 1
    }
done

awk -F '\t' '
BEGIN {
    header = "schema\tcase\tmode\ttypelisp_status\ttypelisp_diagnostic\tispc_status\tispc_diagnostic\tispc_target\tgang_width\tlane_type\ttypelisp_source\ttypelisp_symbol\tispc_source\tispc_symbol\tdriver\targuments\trepetitions\texpected_exit\tupstream_tag\tupstream_commit\tupstream_path\tupstream_function\tlicense"
    scalar_diag = "ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4"
    avx2_diag = "lower: SPMD varying while is not supported in AVX2 backend mode; use scalar or avx512"
    args = "x0:f32;y0:f32;x1:f32;y1:f32;width:i32;height:i32;maxIterations:i32;output:i32[]"
    commit = "c6adb4f86f5678ce6c41951b1e2b59f727455697"
}
NR == 1 { if ($0 != header) exit 1; next }
{
    if (NF != 23 || $1 != "typelisp-ispc-case-v1" || $2 != "mandelbrot" ||
        $10 != "f32" || $11 != "bench.tl" || $12 != "mandelbrot-row" ||
        $13 != "kernel.ispc" || $14 != "mandelbrot_ispc" ||
        $15 != "driver.c" || $16 != args || $17 != "1" || $18 != "42" ||
        $19 != "v1.31.0" || $20 != commit ||
        $21 != "examples/cpu/mandelbrot/mandelbrot.ispc" ||
        $22 != "mandelbrot_ispc" || $23 != "BSD-3-Clause") exit 1
    if ($3 == "scalar" && ($4 != "supported" || $5 != "" ||
        $6 != "unsupported" || $7 != scalar_diag || $8 != "none" || $9 != "1")) exit 1
    if ($3 == "avx2" && ($4 != "unsupported" || $5 != avx2_diag ||
        $6 != "supported" || $7 != "" || $8 != "avx2-i32x8" || $9 != "8")) exit 1
    if ($3 == "avx512" && ($4 != "supported" || $5 != "" ||
        $6 != "supported" || $7 != "" || $8 != "avx512skx-x16" || $9 != "16")) exit 1
    seen[$3]++
}
END {
    if (NR != 4 || seen["scalar"] != 1 || seen["avx2"] != 1 || seen["avx512"] != 1) exit 1
}
' "$METADATA" || {
    echo "mandelbrot: invalid case.tsv metadata" >&2
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
    echo "mandelbrot: TypeLisp compiler is not executable: $COMPILER" >&2
    exit 1
}

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) echo "mandelbrot: unsupported host" >&2; exit 1 ;;
esac
if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || { echo "mandelbrot: missing as" >&2; exit 1; }
    command -v ld >/dev/null 2>&1 || { echo "mandelbrot: missing ld" >&2; exit 1; }
fi

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")
has_isa() { printf '%s\n' "$SIMD_ISAS" | grep -qx "$1"; }

printf 'implementation\tmode\tsymbol\tasm_sha256\tbytes\tinstructions\tmasks\tbranches\tcalls\tvector_instructions\tregisters\tstack_accesses\tstack_moves\thelper\n' > "$STATIC"

extract_symbol() {
    _asm=$1
    _symbol=$2
    _out=$3
    awk -v symbol="$_symbol" '
        $0 ~ ("^" symbol ":($|[[:space:]])") { active = 1; current = 1 }
        active && !current && $0 ~ /^[A-Za-z_][A-Za-z0-9_.$]*:/ { exit }
        active { print }
        { current = 0 }
    ' "$_asm" > "$_out"
    [ -s "$_out" ]
}

append_static() {
    _impl=$1
    _mode=$2
    _symbol=$3
    _asm=$4
    _obj=$5
    _body="$WORKDIR/body-$_impl-$_mode.s"
    extract_symbol "$_asm" "$_symbol" "$_body" || {
        echo "mandelbrot: missing $_impl $_mode symbol $_symbol" >&2
        exit 1
    }
    _hash=$(sha256sum "$_body" | awk '{print $1}')
    set -- $(nm -n --defined-only "$_obj" 2>/dev/null | awk -v s="$_symbol" '
        $3 == s { start = $1; found = 1; next }
        found && $2 ~ /^[Tt]$/ { print start, $1; exit }
    ')
    if [ "$#" -eq 2 ]; then _bytes=$((0x$2 - 0x$1)); else _bytes=0; fi
    _instructions=$(awk '/^[[:space:]]+[A-Za-z][A-Za-z0-9.]*/ { n++ } END { print n+0 }' "$_body")
    _masks=$(grep -E -c '%k[0-7]|\{ *%k[0-7]' "$_body" || true)
    _branches=$(grep -E -c '^[[:space:]]+j[a-z]+' "$_body" || true)
    _calls=$(grep -E -c '^[[:space:]]+call' "$_body" || true)
    _vectors=$(grep -E -c '^[[:space:]]+v[a-z0-9]+' "$_body" || true)
    _registers=$(grep -Eo '%[A-Za-z][A-Za-z0-9]*' "$_body" | sort -u | wc -l | tr -d ' ')
    _stack=$(grep -E -c '\(%(rsp|rbp)\)' "$_body" || true)
    _stack_moves=$(grep -E -c '^[[:space:]]+(v?mov)[A-Za-z0-9]* .*\(%(rsp|rbp)\)' "$_body" || true)
    _helper=inlined
    if grep -E '^[[:space:]]+call.*mandel' "$_body" >/dev/null 2>&1; then _helper=called; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_impl" "$_mode" "$_symbol" "$_hash" "$_bytes" "$_instructions" \
        "$_masks" "$_branches" "$_calls" "$_vectors" "$_registers" \
        "$_stack" "$_stack_moves" "$_helper" >> "$STATIC"
}

compile_typelisp() {
    _mode=$1
    _asm="$WORKDIR/typelisp-$_mode.s"
    _obj="$WORKDIR/typelisp-$_mode.o"
    "$COMPILER" compile "$CASE_DIR/bench.tl" --backend-mode "$_mode" \
        --opt-level 2 --stdlib-root "$ROOT/stdlib" -o "$_asm" \
        > "$WORKDIR/typelisp-$_mode.stdout" 2> "$WORKDIR/typelisp-$_mode.stderr"
    if [ "$HOST_OS" = linux ]; then
        as "$_asm" -o "$_obj"
        append_static typelisp "$_mode" _tl_bench_mandelbrot_row "$_asm" "$_obj"
    fi
    if [ "$_mode" = avx512 ]; then
        grep -q 'vmulps' "$_asm" && grep -q 'vsubps' "$_asm" &&
            grep -q 'vcmpps' "$_asm" && grep -Eq '%k[0-7]' "$_asm" || {
            echo "mandelbrot: AVX-512 assembly lacks recurrence/mask shape" >&2
            exit 1
        }
    fi
    if [ "$_mode" = avx512 ] && ! has_isa avx512; then
        echo "mandelbrot TypeLisp avx512 execution skipped (host lacks F+BW+DQ; compile shape passed)"
        return
    fi
    if [ "$HOST_OS" = linux ]; then
        _bin="$WORKDIR/typelisp-$_mode"
        ld "$_obj" -o "$_bin" -static -e "$(linux_entry_symbol_for_asm "$_asm")"
        set +e; "$_bin" > "$WORKDIR/typelisp-$_mode.run.stdout" 2> "$WORKDIR/typelisp-$_mode.run.stderr"; _status=$?; set -e
    else
        set +e; "$COMPILER" run "$CASE_DIR/bench.tl" --backend-mode "$_mode" --opt-level 2 --stdlib-root "$ROOT/stdlib" > "$WORKDIR/typelisp-$_mode.run.stdout" 2> "$WORKDIR/typelisp-$_mode.run.stderr"; _status=$?; set -e
    fi
    if [ "$_status" -ne 42 ] || [ -s "$WORKDIR/typelisp-$_mode.run.stdout" ] || [ -s "$WORKDIR/typelisp-$_mode.run.stderr" ]; then
        echo "mandelbrot: TypeLisp $_mode correctness failed (exit $_status)" >&2
        sed 's/^/  /' "$WORKDIR/typelisp-$_mode.run.stderr" >&2 || true
        exit 1
    fi
    echo "mandelbrot TypeLisp $_mode correctness passed"
}

compile_typelisp scalar

set +e
"$COMPILER" compile "$CASE_DIR/bench.tl" --backend-mode avx2 --opt-level 2 \
    --stdlib-root "$ROOT/stdlib" -o "$WORKDIR/typelisp-avx2.s" \
    > "$WORKDIR/typelisp-avx2.stdout" 2> "$WORKDIR/typelisp-avx2.stderr"
avx2_status=$?
set -e
avx2_diag='lower: SPMD varying while is not supported in AVX2 backend mode; use scalar or avx512'
if [ "$avx2_status" -eq 0 ] || ! grep -F "$avx2_diag" "$WORKDIR/typelisp-avx2.stderr" >/dev/null; then
    echo "mandelbrot: TypeLisp AVX2 diagnostic mismatch" >&2
    sed 's/^/  /' "$WORKDIR/typelisp-avx2.stderr" >&2 || true
    exit 1
fi
echo "mandelbrot TypeLisp avx2 expected diagnostic passed"

compile_typelisp avx512

ISPC=${ISPC_BIN:-}
if [ -z "$ISPC" ]; then ISPC=$(command -v ispc 2>/dev/null || true); fi
if [ -z "$ISPC" ]; then
    echo "mandelbrot optional ISPC correctness skipped (set ISPC_BIN to ISPC v1.31.0)"
    echo "mandelbrot static report: $STATIC"
    exit 0
fi
case "$("$ISPC" --version 2>&1 | sed -n '1p')" in
    *1.31.0*) ;;
    *) echo "mandelbrot: ISPC v1.31.0 required" >&2; exit 1 ;;
esac
CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || { echo "mandelbrot: C compiler not found: $CC" >&2; exit 1; }

run_ispc_target() {
    _mode=$1
    _target=$2
    _out="$WORKDIR/ispc-$_mode"
    mkdir -p "$_out"
    "$ISPC" "$CASE_DIR/kernel.ispc" -O2 --arch=x86-64 --target="$_target" \
        -o "$_out/kernel.o" --header-outfile="$_out/kernel_ispc.h" \
        > "$_out/ispc.stdout" 2> "$_out/ispc.stderr"
    "$ISPC" "$CASE_DIR/kernel.ispc" -O2 --arch=x86-64 --target="$_target" \
        --emit-asm -o "$_out/kernel.s" > "$_out/ispc-s.stdout" 2> "$_out/ispc-s.stderr"
    "$CC" -O2 -ffp-contract=off -I"$_out" "$CASE_DIR/driver.c" "$_out/kernel.o" \
        -o "$_out/driver" > "$_out/cc.stdout" 2> "$_out/cc.stderr"
    set +e; "$_out/driver" > "$_out/run.stdout" 2> "$_out/run.stderr"; _status=$?; set -e
    if [ "$_status" -ne 42 ] || [ -s "$_out/run.stdout" ] || [ -s "$_out/run.stderr" ]; then
        echo "mandelbrot: ISPC $_mode correctness failed (exit $_status)" >&2
        sed 's/^/  /' "$_out/run.stderr" >&2 || true
        exit 1
    fi
    _kernel_symbol=$(nm --defined-only "$_out/kernel.o" | awk '$3 ~ /^mandelbrot_ispc___/ { print $3; exit }')
    [ -n "$_kernel_symbol" ] || { echo "mandelbrot: ISPC internal kernel symbol missing" >&2; exit 1; }
    append_static ispc "$_mode" "$_kernel_symbol" "$_out/kernel.s" "$_out/kernel.o"
    echo "mandelbrot ISPC $_mode correctness passed ($_target)"
}

run_ispc_target generic-min-width generic-i32x4
if has_isa avx2; then run_ispc_target avx2 avx2-i32x8; fi
if [ "${ISPC_MANDELBROT_AVX512:-0}" = 1 ]; then
    has_isa avx512 || { echo "mandelbrot: AVX-512 requested but unavailable" >&2; exit 1; }
    run_ispc_target avx512 avx512skx-x16
fi
echo "mandelbrot static report: $STATIC"
