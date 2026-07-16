#!/usr/bin/env sh
set -eu

# analyze-emergency-scavenge.sh - opt2 emergency-scavenge census.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

usage() {
    cat >&2 <<'EOF'
usage: scripts/analyze-emergency-scavenge.sh [typelisp-binary]

Builds a --cfg scavenge-census CLI, then compiles src/main.tl and every
benchmarks/*/bench.tl at opt2. Results are written to:
  target/emergency-scavenge-census/<host>/summary.tsv

Environment:
  TYPELISP_BIN                         seed compiler when no argument is given
  TYPELISP_EMERGENCY_SCAVENGE_OUT      output directory
  TYPELISP_EMERGENCY_SCAVENGE_CFG      optional additional cfg predicate
EOF
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
esac

if [ $# -gt 0 ]; then
    COMPILER=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR=${TYPELISP_EMERGENCY_SCAVENGE_OUT:-target/emergency-scavenge-census/$NL_HOST_OS}
EXTRA_CFG=${TYPELISP_EMERGENCY_SCAVENGE_CFG:-}
case "$EXTRA_CFG" in
    "") ;;
    *[!A-Za-z0-9_-]*)
        echo "invalid TYPELISP_EMERGENCY_SCAVENGE_CFG: $EXTRA_CFG" >&2
        exit 2
        ;;
esac

extra_cfg_args() {
    if [ -n "$EXTRA_CFG" ]; then
        printf '%s\n' --cfg "$EXTRA_CFG"
    fi
}

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/asm" "$WORKDIR/logs"

CENSUS_ASM="$WORKDIR/typelisp-scavenge-census.s"
CENSUS_OBJ="$WORKDIR/typelisp-scavenge-census.$NL_OBJ_EXT"
CENSUS_BIN="$WORKDIR/typelisp-scavenge-census$NL_BIN_EXT"
BUILD_STDOUT="$WORKDIR/build.stdout"
BUILD_STDERR="$WORKDIR/build.stderr"
SUMMARY="$WORKDIR/summary.tsv"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

show_logs() {
    _stdout=$1
    _stderr=$2
    echo "stdout:" >&2
    sed 's/^/  /' "$_stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$_stderr" >&2 || true
}

safe_name() {
    printf '%s\n' "$1" | tr '/\\ :' '____' | tr -c 'A-Za-z0-9_.-' '_'
}

append_census_row() {
    _case=$1
    _source=$2
    _row=$3
    printf '%s\n' "$_row" | awk -F'[|=]' -v case_name="$_case" -v source="$_source" '
    {
        total = 0
        fallback_free = 0
        occupied_candidate = 0
        fallback_last_resort = 0
        wrapped_instructions = 0
        wrapped_regs = 0
        max_pending = 0
        for (i = 2; i < NF; i += 2) {
            if ($i == "total") {
                total = $(i + 1)
            } else if ($i == "fallback-free") {
                fallback_free = $(i + 1)
            } else if ($i == "occupied-candidate") {
                occupied_candidate = $(i + 1)
            } else if ($i == "fallback-last-resort") {
                fallback_last_resort = $(i + 1)
            } else if ($i == "wrapped-instructions") {
                wrapped_instructions = $(i + 1)
            } else if ($i == "wrapped-regs") {
                wrapped_regs = $(i + 1)
            } else if ($i == "max-pending") {
                max_pending = $(i + 1)
            }
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
            case_name,
            source,
            total,
            fallback_free,
            occupied_candidate,
            fallback_last_resort,
            wrapped_instructions,
            wrapped_regs,
            max_pending
    }
    ' >> "$SUMMARY"
}

run_compile_case() {
    _case=$1
    _source=$2
    _safe=$(safe_name "$_case")
    _asm="$WORKDIR/asm/$_safe.s"
    _stdout="$WORKDIR/logs/$_safe.stdout"
    _stderr="$WORKDIR/logs/$_safe.stderr"

    echo "[emergency-scavenge] compile $_case ($_source)" >&2
    if ! "$CENSUS_BIN" compile "$_source" \
        -o "$_asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root src \
        --opt-level 2 \
        > "$_stdout" 2> "$_stderr"; then
        show_logs "$_stdout" "$_stderr"
        fail "opt2 compile failed for $_case"
    fi

    _row=$(grep '^emergency-scavenge-census|' "$_stderr" | tail -n 1 || true)
    if [ -z "$_row" ]; then
        show_logs "$_stdout" "$_stderr"
        fail "missing emergency-scavenge-census row for $_case"
    fi

    append_census_row "$_case" "$_source" "$_row"
}

commit=$(git rev-parse --short HEAD 2>/dev/null || printf '%s\n' unknown)
echo "[emergency-scavenge] source commit: $commit" >&2
echo "[emergency-scavenge] seed compiler: $COMPILER" >&2
echo "[emergency-scavenge] output: $WORKDIR" >&2

echo "[emergency-scavenge] compile census-enabled CLI" >&2
if ! "$COMPILER" compile src/main.tl \
    -o "$CENSUS_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg scavenge-census \
    $(extra_cfg_args) \
    > "$BUILD_STDOUT" 2> "$BUILD_STDERR"; then
    show_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "census-enabled CLI compile failed"
fi

echo "[emergency-scavenge] link census-enabled CLI" >&2
if ! assemble_and_link emergency-scavenge-census "$CENSUS_ASM" "$CENSUS_OBJ" "$CENSUS_BIN" \
    >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
    show_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "census-enabled CLI link failed"
fi

printf 'case\tsource\ttotal\tfallback_free\toccupied_candidate\tfallback_last_resort\twrapped_instructions\twrapped_regs\tmax_pending\n' > "$SUMMARY"

run_compile_case self_compile_opt2 src/main.tl
for bench_tl in benchmarks/*/bench.tl; do
    [ -e "$bench_tl" ] || continue
    bench_name=$(basename "$(dirname "$bench_tl")")
    run_compile_case "benchmark_opt2/$bench_name" "$bench_tl"
done

echo "[emergency-scavenge] summary: $SUMMARY" >&2
cat "$SUMMARY"
