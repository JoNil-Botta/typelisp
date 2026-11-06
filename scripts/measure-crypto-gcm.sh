#!/usr/bin/env sh
set -eu
# Both hosted native targets report setup, one-block and 16 KiB observations.
# Local owners invoke this under the 6144 MiB process-tree measurement cap.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
work=${GCM_BENCH_WORKDIR:-target/exp/crypto-gcm-bench}
mkdir -p "$work"
work=$(mktemp -d "$work/run.XXXXXX")
for opt in 1 2; do
    stem="$work/opt$opt"
    "$COMPILER" compile tools/crypto-gcm-bench/main.tl --stdlib-root "$ROOT/stdlib" \
        --target "$NL_BOOTSTRAP_TARGET" --opt-level "$opt" --cfg compile-profile -o "$stem.s"
    assemble_and_link crypto-gcm-bench "$stem.s" "$stem.$NL_OBJ_EXT" "$stem$NL_BIN_EXT"
    printf '[gcm-bench] target=%s opt=%s compiler=%s\n' "$NL_BOOTSTRAP_TARGET" "$opt" "$COMPILER"
    "$stem$NL_BIN_EXT"
    if command -v llvm-readobj >/dev/null 2>&1; then
        llvm-readobj --sections "$stem.$NL_OBJ_EXT"
    elif command -v objdump >/dev/null 2>&1; then
        objdump -h "$stem.$NL_OBJ_EXT"
    else
        echo 'missing section reader for GCM text-size report' >&2
        exit 1
    fi
done
stem="$work/work-counts"
"$COMPILER" compile tools/crypto-gcm-bench/main.tl --stdlib-root "$ROOT/stdlib" \
    --target "$NL_BOOTSTRAP_TARGET" --opt-level 2 --cfg compile-profile --cfg test -o "$stem.s"
assemble_and_link crypto-gcm-work "$stem.s" "$stem.$NL_OBJ_EXT" "$stem$NL_BIN_EXT"
"$stem$NL_BIN_EXT" work
