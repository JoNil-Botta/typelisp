#!/usr/bin/env sh
# measure-intern-counts.sh - deterministic per-compile interning counters.
#
# Builds a --cfg compile-profile compiler from the CURRENT source with a seed
# compiler, links it, runs it compiling src/main.tl, and prints the
# `compile-profile|intern.*` counter rows (hash_words / intern_calls /
# slice_calls / lookup_calls). These counts are deterministic for a given
# (compiler, input), so they isolate redundant-interning changes from wall-clock
# noise. Not a CI gate -- a local iteration metric.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-stage0.sh"

SEED=${TYPELISP_BIN:-$(stage0_compiler_path "$ROOT")}
[ -x "$SEED" ] || { echo "seed not executable: $SEED" >&2; exit 1; }

OUT=${TYPELISP_INTERN_OUT:-target/intern-counts}
OPT=${TYPELISP_INTERN_OPT:-1}
rm -rf "$OUT"
mkdir -p "$OUT"
configure_toolchain

ASM="$OUT/profile.s"
OBJ="$OUT/profile.$NL_OBJ_EXT"
BIN="$OUT/profile$NL_BIN_EXT"

echo "[intern-counts] building --cfg compile-profile compiler (opt$OPT) with seed"
# shellcheck disable=SC2046
"$SEED" compile src/main.tl -o "$ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level "$OPT" \
    --cfg compile-profile
assemble_and_link "intern-profile" "$ASM" "$OBJ" "$BIN"

echo "[intern-counts] running profile compiler on src/main.tl"
# shellcheck disable=SC2046
"$BIN" compile src/main.tl -o "$OUT/out.s" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level "$OPT" \
    2>"$OUT/profile.stderr" >/dev/null

echo "[intern-counts] intern counters:"
grep '^compile-profile|intern\.' "$OUT/profile.stderr" \
    | awk -F'|' '{ printf "  %-14s %s\n", $2, $3 }'
