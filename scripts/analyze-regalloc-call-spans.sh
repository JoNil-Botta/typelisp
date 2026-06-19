#!/usr/bin/env sh
set -eu

# analyze-regalloc-call-spans.sh - deterministic opt2 regalloc call-span census.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "usage: scripts/analyze-regalloc-call-spans.sh [typelisp-binary]" >&2
    echo "  TYPELISP_REGALLOC_CALL_SPAN_OUT   output directory (default target/regalloc-call-spans)" >&2
    exit 0
fi

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

WORKDIR=${TYPELISP_REGALLOC_CALL_SPAN_OUT:-target/regalloc-call-spans}
mkdir -p "$WORKDIR"

CENSUS_ASM="$WORKDIR/typelisp-regalloc-census.s"
CENSUS_OBJ="$WORKDIR/typelisp-regalloc-census.$NL_OBJ_EXT"
CENSUS_BIN="$WORKDIR/typelisp-regalloc-census$NL_BIN_EXT"
SELF_ASM="$WORKDIR/self-compile-opt2.s"
BUILD_STDOUT="$WORKDIR/build.stdout"
BUILD_STDERR="$WORKDIR/build.stderr"
RUN_STDOUT="$WORKDIR/self-compile.stdout"
RUN_STDERR="$WORKDIR/self-compile.stderr"

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

echo "[regalloc-call-spans] compile census-enabled CLI" >&2
if ! "$COMPILER" compile src/main.tl \
    -o "$CENSUS_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg regalloc-census \
    > "$BUILD_STDOUT" 2> "$BUILD_STDERR"; then
    show_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "census-enabled CLI compile failed"
fi

echo "[regalloc-call-spans] link census-enabled CLI" >&2
if ! assemble_and_link regalloc-call-span-census "$CENSUS_ASM" "$CENSUS_OBJ" "$CENSUS_BIN" \
    >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
    show_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "census-enabled CLI link failed"
fi

echo "[regalloc-call-spans] opt2 self-compile census" >&2
if ! "$CENSUS_BIN" compile src/main.tl \
    -o "$SELF_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level 2 \
    > "$RUN_STDOUT" 2> "$RUN_STDERR"; then
    show_logs "$RUN_STDOUT" "$RUN_STDERR"
    fail "opt2 self-compile failed"
fi

if ! grep '^regalloc-call-span-census|' "$RUN_STDERR" >/dev/null 2>&1; then
    show_logs "$RUN_STDOUT" "$RUN_STDERR"
    fail "census rows missing"
fi

grep '^regalloc-call-span-census|' "$RUN_STDERR"
