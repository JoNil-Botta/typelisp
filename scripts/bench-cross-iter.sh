#!/usr/bin/env sh
# bench-cross-iter.sh - fast inner-loop for the MAIN METRIC: an opt2-built
# stage2 compiling cli.tl at opt1 (cheap codegen). Mirrors the cross metric in
# benchmark-compile-cli.sh but takes best-of-N and skips profile drivers.
#
# Builds:
#   stage1/stage2 at opt2 (the fast "quality" binary), and
#   stage1/stage2 at opt1 (to produce the opt1 reference stage3).
# Then times the opt2 stage2 compiling cli.tl at opt1 (best of N) and verifies
# the output equals the opt1 reference (cross fixpoint).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RUNS=${BENCH_ITER_RUNS:-3}
WORKDIR=${BENCH_ITER_OUT:-"$ROOT/target/bench-cross-iter"}

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

compile() { # compiler out opt
    "$1" compile selfhost/cli.tl -o "$2" \
        --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
        --stdlib-root stdlib --stdlib-root selfhost --opt-level "$3"
}

build_chain() { # opt prefix
    opt=$1; pfx=$2
    echo "[cross] opt$opt seed->stage1"
    compile "$SEED" "$WORKDIR/$pfx-stage1.s" "$opt"
    assemble_and_link "$pfx-stage1" "$WORKDIR/$pfx-stage1.s" "$WORKDIR/$pfx-stage1.$NL_OBJ_EXT" "$WORKDIR/$pfx-stage1$NL_BIN_EXT"
    echo "[cross] opt$opt stage1->stage2"
    compile "$WORKDIR/$pfx-stage1$NL_BIN_EXT" "$WORKDIR/$pfx-stage2.s" "$opt"
    assemble_and_link "$pfx-stage2" "$WORKDIR/$pfx-stage2.s" "$WORKDIR/$pfx-stage2.$NL_OBJ_EXT" "$WORKDIR/$pfx-stage2$NL_BIN_EXT"
}

build_chain 2 q
build_chain 1 c

echo "[cross] opt1 reference stage3 (opt1-built stage2)"
compile "$WORKDIR/c-stage2$NL_BIN_EXT" "$WORKDIR/ref-stage3.s" 1

best=0
i=0
while [ "$i" -lt "$RUNS" ]; do
    start=$(now_ms)
    compile "$WORKDIR/q-stage2$NL_BIN_EXT" "$WORKDIR/cross-stage3.s" 1
    end=$(now_ms)
    ms=$((end - start))
    echo "[cross] run $i: ${ms}ms"
    if [ "$best" -eq 0 ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
    i=$((i + 1))
done

if ! cmp -s "$WORKDIR/ref-stage3.s" "$WORKDIR/cross-stage3.s"; then
    echo "[cross] CROSS FIXPOINT MISMATCH: opt2-built @opt1 != opt1 reference" >&2
    exit 1
fi
echo "[cross] cross fixpoint OK"
echo "[cross] BEST opt2-built stage2 @opt1: ${best}ms   (goal < 1000ms)"
