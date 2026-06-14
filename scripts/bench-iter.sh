#!/usr/bin/env sh
# bench-iter.sh - fast inner-loop benchmark for stage2 compiling stage3.
#
# Builds stage1 and stage2 at OPT (default 2), then times the stage2 binary
# compiling src/main.tl into stage3.s (best of N runs) and verifies
# stage2.s == stage3.s. Skips the profile-driver build/run that the full
# benchmark does, so it is ~2x faster for iteration.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

OPT=${BENCH_ITER_OPT:-1}
RUNS=${BENCH_ITER_RUNS:-3}
WORKDIR=${BENCH_ITER_OUT:-"$ROOT/target/bench-iter"}

TYPELISP_WINDOWS_LINK_REPRO=${TYPELISP_WINDOWS_LINK_REPRO:-1}
export TYPELISP_WINDOWS_LINK_REPRO

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-stage0.sh"

fetch_stage0_compiler "$ROOT" >/dev/null 2>&1 || true
SEED=${TYPELISP_BIN:-$(stage0_compiler_path "$ROOT")}
if [ ! -x "$SEED" ]; then echo "seed missing: $SEED" >&2; exit 1; fi

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
configure_toolchain

now_ms() {
    v=$(date +%s%3N 2>/dev/null || true)
    case "$v" in *[!0-9]*|"") perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000';; *) printf '%s\n' "$v";; esac
}

compile() { # compiler out
    "$1" compile src/main.tl -o "$2" \
        --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
        --stdlib-root stdlib --stdlib-root src --opt-level "$OPT"
}

echo "[iter] opt$OPT seed->stage1"
compile "$SEED" "$WORKDIR/stage1.s"
assemble_and_link "stage1" "$WORKDIR/stage1.s" "$WORKDIR/stage1.$NL_OBJ_EXT" "$WORKDIR/stage1$NL_BIN_EXT"

echo "[iter] opt$OPT stage1->stage2"
compile "$WORKDIR/stage1$NL_BIN_EXT" "$WORKDIR/stage2.s"
assemble_and_link "stage2" "$WORKDIR/stage2.s" "$WORKDIR/stage2.$NL_OBJ_EXT" "$WORKDIR/stage2$NL_BIN_EXT"

best=0
i=0
while [ "$i" -lt "$RUNS" ]; do
    start=$(now_ms)
    compile "$WORKDIR/stage2$NL_BIN_EXT" "$WORKDIR/stage3.s"
    end=$(now_ms)
    ms=$((end - start))
    echo "[iter] run $i: ${ms}ms"
    if [ "$best" -eq 0 ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
    i=$((i + 1))
done

if ! cmp -s "$WORKDIR/stage2.s" "$WORKDIR/stage3.s"; then
    echo "[iter] FIXPOINT MISMATCH: stage2.s != stage3.s" >&2
    exit 1
fi
echo "[iter] fixpoint OK (stage2.s == stage3.s)"
echo "[iter] BEST opt$OPT stage2->stage3: ${best}ms"
