#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-stage0.sh"
SEED=${TYPELISP_BIN:-$(stage0_compiler_path "$ROOT")}
[ -x "$SEED" ] || { echo "seed not executable: $SEED" >&2; exit 1; }
OPT=${1:-1}
OUT=${TYPELISP_FP_OUT:-target/fp-wholeprogram}
rm -rf "$OUT"; mkdir -p "$OUT"
configure_toolchain
s1="$OUT/s1.s"; o1="$OUT/s1.$NL_OBJ_EXT"; b1="$OUT/s1$NL_BIN_EXT"
s2="$OUT/s2.s"; o2="$OUT/s2.$NL_OBJ_EXT"; b2="$OUT/s2$NL_BIN_EXT"
s3="$OUT/s3.s"
CFGARG="--cfg compile-profile"
run(){ echo "[fp] $*"; "$@"; }
echo "[fp] stage1: seed -> s1.s (opt$OPT, compile-profile)"
run "$SEED" compile src/main.tl -o "$s1" --target "$NL_BOOTSTRAP_TARGET" \
  $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level "$OPT" $CFGARG
assemble_and_link "fp-s1" "$s1" "$o1" "$b1"
echo "[fp] stage2: s1.exe -> s2.s"
run "$b1" compile src/main.tl -o "$s2" --target "$NL_BOOTSTRAP_TARGET" \
  $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level "$OPT" $CFGARG
assemble_and_link "fp-s2" "$s2" "$o2" "$b2"
echo "[fp] stage3: s2.exe -> s3.s"
run "$b2" compile src/main.tl -o "$s3" --target "$NL_BOOTSTRAP_TARGET" \
  $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level "$OPT" $CFGARG
if cmp -s "$s2" "$s3"; then
  echo "[fp] FIXPOINT OK: s2.s == s3.s ($(wc -c <"$s2") bytes)"
else
  echo "[fp] FIXPOINT FAIL: s2.s != s3.s" >&2
  cmp "$s2" "$s3" | head -3 >&2 || true
  exit 1
fi
