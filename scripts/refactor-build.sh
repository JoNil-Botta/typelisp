#!/usr/bin/env sh
# refactor-build.sh - build a one-stage compiler from this checkout for refactor checks.
#
# usage: scripts/refactor-build.sh [--fixpoint] <seed-compiler> <output-binary>
#
# --fixpoint then has the new compiler compile src/main.tl again and requires
# the assembly to equal the seed's byte for byte. For a pure refactor built
# from a seed of the base commit this proves the new compiler generates the
# same code for its own source as the base did.
#
# The seed compiles src/main.tl at --opt-level 2 (the same flags as the
# build-stage0 stage1, without the build-version stamp or the embedded stdlib
# TLCI image) and the result is assembled and linked. Build the base and the
# head of a refactor with the same seed, then compare them with
# scripts/refactor-oracle.sh. Release and publication builds still use
# scripts/build-stage0.sh. The run holds a scripts/refactor-capped.sh slot and
# each compile is capped at 6G and 20 minutes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -n "${TL_REFACTOR_CAPPED:-}" ] || exec "$ROOT/scripts/refactor-capped.sh" "$0" "$@"
capped() { "$ROOT/scripts/refactor-capped.sh" --mem 6G --timeout 1200 "$@"; }
cd "$ROOT"
FIXPOINT=0
if [ "${1:-}" = "--fixpoint" ]; then FIXPOINT=1; shift; fi
[ "$#" -eq 2 ] || { echo "usage: $0 [--fixpoint] <seed-compiler> <output-binary>" >&2; exit 2; }
SEED=$1 OUT=$2
case "$SEED" in /*) ;; *) SEED="$ROOT/$SEED" ;; esac
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
mkdir -p "$(dirname -- "$OUT")"
ASM="$OUT.s"
OBJ="$OUT.$NL_OBJ_EXT"
capped "$SEED" compile src/main.tl -o "$ASM" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level 2
assemble_and_link refactor "$ASM" "$OBJ" "$OUT"
rm -f "$OBJ"
if [ "$FIXPOINT" -eq 1 ]; then
    capped "$OUT" compile src/main.tl -o "$OUT.self.s" --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level 2
    if cmp -s "$ASM" "$OUT.self.s"; then
        echo "[refactor-build] fixpoint: self-compile matches the seed's assembly"
    else
        echo "[refactor-build] FIXPOINT FAIL: $OUT.self.s differs from $ASM" >&2
        exit 1
    fi
fi
