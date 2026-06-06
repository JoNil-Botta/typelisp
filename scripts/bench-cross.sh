#!/usr/bin/env sh
set -eu

# bench-cross.sh - measure an opt3-built (register-allocated) stage2 compiling
# cli.tl at opt2 (cheap work, fast binary), vs a stack-only opt2-built stage2
# doing the same opt2 compile. Both run identical opt2 logic, so their opt2
# outputs must be byte-identical (the cross-level fixpoint). The delta is the
# pure register-allocation codegen benefit on the compiler binary.
#
# Env: BENCH_REPS (default 5).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

REPS=${BENCH_REPS:-5}
W="$ROOT/target/bench-cross"
SEED="$ROOT/target/stage0/typelisp$NL_BIN_EXT"
rm -rf "$W"; mkdir -p "$W"

now_ms() { v=$(date +%s%3N 2>/dev/null||true); case "$v" in *[!0-9]*|"") perl -MTime::HiRes=time -e 'printf "%d\n",time()*1000';; *) printf '%s\n' "$v";; esac; }
compile() { c=$1; o=$2; lvl=$3; "$c" compile selfhost/cli.tl -o "$o" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root selfhost --opt-level "$lvl" >/dev/null 2>&1; }
link() { assemble_and_link "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

echo "[bench-cross] seed=$SEED reps=$REPS"
s1="$W/s1.s"; s1b="$W/s1$NL_BIN_EXT"
t=$(now_ms); compile "$SEED" "$s1" 2; echo "[bench-cross] seed->stage1@opt2 $(( $(now_ms)-t ))ms"
link s1 "$s1" "$W/s1.$NL_OBJ_EXT" "$s1b"

# opt2 (stack-only) stage2
s2o2="$W/s2_o2.s"; s2o2b="$W/s2_o2$NL_BIN_EXT"
t=$(now_ms); compile "$s1b" "$s2o2" 2; echo "[bench-cross] stage1->stage2@opt2 $(( $(now_ms)-t ))ms"
link s2o2 "$s2o2" "$W/s2_o2.$NL_OBJ_EXT" "$s2o2b"

# opt3 (register-allocated) stage2
s2o3="$W/s2_o3.s"; s2o3b="$W/s2_o3$NL_BIN_EXT"
t=$(now_ms); compile "$s1b" "$s2o3" 3; echo "[bench-cross] stage1->stage2@opt3 $(( $(now_ms)-t ))ms (bootstrap, register-allocated)"
link s2o3 "$s2o3" "$W/s2_o3.$NL_OBJ_EXT" "$s2o3b"

measure() {
    bin=$1; out=$2; min=
    i=0
    while [ "$i" -lt "$REPS" ]; do
        t=$(now_ms); compile "$bin" "$out" 2; e=$(( $(now_ms)-t ))
        if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min=$e; fi
        i=$(( i+1 ))
    done
    echo "$min"
}

echo "[bench-cross] measuring opt2 compiles..."
a3="$W/stage3_from_o3.s"; a2="$W/stage3_from_o2.s"
min_o3=$(measure "$s2o3b" "$a3")
min_o2=$(measure "$s2o2b" "$a2")

echo "[bench-cross] stack-only(opt2) stage2 @opt2:        min=${min_o2}ms"
echo "[bench-cross] register(opt3)   stage2 @opt2:        min=${min_o3}ms  <-- new metric"
if [ "$min_o2" -gt 0 ]; then
    echo "[bench-cross] codegen speedup: $(( (min_o2 - min_o3) * 100 / min_o2 ))%"
fi
if cmp -s "$a3" "$a2"; then
    echo "[bench-cross] CROSS-FIXPOINT OK (opt3-stage2@opt2 == opt2-stage2@opt2)"
else
    echo "[bench-cross] CROSS-FIXPOINT MISMATCH" >&2; exit 1
fi
