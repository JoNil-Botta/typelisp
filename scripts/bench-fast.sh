#!/usr/bin/env sh
set -eu

# bench-fast.sh - fast inner-loop measurement of stage2 compiling cli.tl.
#
# Trimmed cousin of scripts/benchmark-compile-cli.sh for iterating on compiler
# performance changes. Builds stage1 and stage2 from the working-tree sources,
# then times the stage2 CLI compiling src/main.tl into stage3.s REPS times
# (default 5), reporting the minimum and median wall-clock milliseconds, and
# verifies stage3.s is byte-identical to stage2.s (fixpoint). No profile driver,
# no cache.
#
# Env:
#   TYPELISP_BIN     seed compiler (default target/stage0/typelisp[.exe])
#   BENCH_OPT_LEVEL  opt level (default 2)
#   BENCH_REPS       measured repetitions (default 5)
#   BENCH_OUT        work dir (default target/bench-fast)

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

OPT_LEVEL=${BENCH_OPT_LEVEL:-1}
REPS=${BENCH_REPS:-5}
WORKDIR=${BENCH_OUT:-"$ROOT/target/bench-fast"}

if [ -n "${TYPELISP_BIN:-}" ]; then
    SEED=$TYPELISP_BIN
else
    SEED="$ROOT/target/stage0/typelisp$NL_BIN_EXT"
fi
[ -x "$SEED" ] || { echo "seed not executable: $SEED" >&2; exit 1; }

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

now_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        *[!0-9]* | "") perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

compile() {
    _c=$1; _o=$2
    "$_c" compile src/main.tl -o "$_o" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib --stdlib-root src \
        --opt-level "$OPT_LEVEL"
}

echo "[bench-fast] opt$OPT_LEVEL seed=$SEED reps=$REPS"

s1="$WORKDIR/stage1.s"; s1o="$WORKDIR/stage1.$NL_OBJ_EXT"; s1b="$WORKDIR/stage1$NL_BIN_EXT"
s2="$WORKDIR/stage2.s"; s2o="$WORKDIR/stage2.$NL_OBJ_EXT"; s2b="$WORKDIR/stage2$NL_BIN_EXT"
s3="$WORKDIR/stage3.s"

t=$(now_ms); compile "$SEED" "$s1"; echo "[bench-fast] seed->stage1 $(( $(now_ms) - t )) ms"
assemble_and_link "stage1" "$s1" "$s1o" "$s1b" >/dev/null 2>&1
t=$(now_ms); compile "$s1b" "$s2"; echo "[bench-fast] stage1->stage2 $(( $(now_ms) - t )) ms"
assemble_and_link "stage2" "$s2" "$s2o" "$s2b" >/dev/null 2>&1

min=
sum=0
list=""
i=0
while [ "$i" -lt "$REPS" ]; do
    t=$(now_ms)
    compile "$s2b" "$s3"
    e=$(( $(now_ms) - t ))
    list="$list $e"
    sum=$(( sum + e ))
    if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min=$e; fi
    i=$(( i + 1 ))
done

median=$(printf '%s\n' $list | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
echo "[bench-fast] stage2->stage3 reps:$list"
echo "[bench-fast] stage2->stage3 min=${min}ms median=${median}ms avg=$(( sum / REPS ))ms"

if cmp -s "$s2" "$s3"; then
    echo "[bench-fast] FIXPOINT OK (stage2.s == stage3.s)"
else
    echo "[bench-fast] FIXPOINT MISMATCH stage2.s != stage3.s" >&2
    exit 1
fi
