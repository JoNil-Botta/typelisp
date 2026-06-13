#!/usr/bin/env sh
set -eu

# bench-cross.sh - cross-level self-compile benchmark for the register-allocation
# design. Opt levels: opt1 = cheap stack-only (the fast self-compile path); opt2
# = full optimizer + scalar register allocation + inlining (the high-quality
# "ship" build).
#
# Three checks, matching the owner's design:
#   1. CHEAP FIXPOINT  - cheap-built stage2 compiling at the cheap level is
#      byte-identical to itself (stage2.s == stage3.s).
#   2. QUALITY FIXPOINT - quality-built (register-allocated) stage2 compiling at
#      the quality level is byte-identical to itself, and is measured so its
#      time/size can be held under a 2x budget vs the target.
#   3. MAIN METRIC     - the quality-built (fast) stage2 compiling at the CHEAP
#      level: fast binary doing cheap work. This is the headline number. Its
#      output must equal the cheap-built stage2's cheap output (cross-fixpoint),
#      since both run identical cheap-level logic.
#
# Env: BENCH_REPS (default 5), CHEAP (default 2), QUALITY (default 3).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

REPS=${BENCH_REPS:-5}
CHEAP=${CHEAP:-1}
QUALITY=${QUALITY:-2}
W="$ROOT/target/bench-cross"
SEED="$ROOT/target/stage0/typelisp$NL_BIN_EXT"
rm -rf "$W"; mkdir -p "$W"

now_ms() { v=$(date +%s%3N 2>/dev/null||true); case "$v" in *[!0-9]*|"") perl -MTime::HiRes=time -e 'printf "%d\n",time()*1000';; *) printf '%s\n' "$v";; esac; }
compile() { c=$1; o=$2; lvl=$3; "$c" compile src/cli.tl -o "$o" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level "$lvl" >/dev/null 2>&1; }
link() { assemble_and_link "$1" "$2" "$3" "$4" >/dev/null 2>&1; }
fail() { echo "[bench-cross] FAIL: $*" >&2; exit 1; }

echo "[bench-cross] seed=$SEED reps=$REPS cheap=opt$CHEAP quality=opt$QUALITY"
s1="$W/s1.s"; s1b="$W/s1$NL_BIN_EXT"
t=$(now_ms); compile "$SEED" "$s1" "$CHEAP"; echo "[bench-cross] seed->stage1@cheap $(( $(now_ms)-t ))ms"
link s1 "$s1" "$W/s1.$NL_OBJ_EXT" "$s1b"

# cheap-built stage2
s2c="$W/s2_cheap.s"; s2cb="$W/s2_cheap$NL_BIN_EXT"
t=$(now_ms); compile "$s1b" "$s2c" "$CHEAP"; echo "[bench-cross] stage1->stage2@cheap $(( $(now_ms)-t ))ms"
link s2c "$s2c" "$W/s2_cheap.$NL_OBJ_EXT" "$s2cb"

# quality-built (register-allocated) stage2
s2q="$W/s2_quality.s"; s2qb="$W/s2_quality$NL_BIN_EXT"
t=$(now_ms); compile "$s1b" "$s2q" "$QUALITY"; q_build=$(( $(now_ms)-t )); echo "[bench-cross] stage1->stage2@quality ${q_build}ms (register-allocated)"
link s2q "$s2q" "$W/s2_quality.$NL_OBJ_EXT" "$s2qb"

measure() { bin=$1; out=$2; lvl=$3; min=; i=0
    while [ "$i" -lt "$REPS" ]; do t=$(now_ms); compile "$bin" "$out" "$lvl"; e=$(( $(now_ms)-t )); if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min=$e; fi; i=$(( i+1 )); done
    echo "$min"; }

# --- Check 1: cheap fixpoint ---
cheap_fp="$W/stage3_cheap.s"
min_cheap=$(measure "$s2cb" "$cheap_fp" "$CHEAP")
cmp -s "$s2c" "$cheap_fp" || fail "cheap fixpoint (stage2@cheap != stage3@cheap)"
echo "[bench-cross] CHEAP FIXPOINT OK   (stage2@cheap == stage3@cheap)   min=${min_cheap}ms"

# --- Check 2: quality fixpoint (+ measured for the 2x budget) ---
qual_fp="$W/stage3_quality.s"
min_qual=$(measure "$s2qb" "$qual_fp" "$QUALITY")
cmp -s "$s2q" "$qual_fp" || fail "quality fixpoint (stage2@quality != stage3@quality)"
echo "[bench-cross] QUALITY FIXPOINT OK (stage2@quality == stage3@quality) min=${min_qual}ms"

# --- Check 3: main metric (quality binary @ cheap) + cross-fixpoint ---
main_out="$W/stage3_main.s"
min_main=$(measure "$s2qb" "$main_out" "$CHEAP")
cmp -s "$main_out" "$s2c" || fail "cross-fixpoint (quality-stage2@cheap != cheap-stage2@cheap)"
echo "[bench-cross] CROSS-FIXPOINT OK  (quality-stage2@cheap == cheap-stage2@cheap)"

echo "[bench-cross] ------------------------------------------------------------"
echo "[bench-cross] MAIN METRIC (quality stage2 @cheap):  min=${min_main}ms   <-- target < 500ms"
echo "[bench-cross] cheap baseline (cheap stage2 @cheap): min=${min_cheap}ms"
if [ "$min_cheap" -gt 0 ]; then echo "[bench-cross] codegen speedup: $(( (min_cheap - min_main) * 100 / min_cheap ))%"; fi
echo "[bench-cross] quality compile @quality:             min=${min_qual}ms   <-- 2x budget vs target"
