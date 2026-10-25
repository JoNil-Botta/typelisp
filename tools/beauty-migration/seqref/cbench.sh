#!/bin/sh
# cbench.sh TREE SEED: the official scripts/benchmark-compile-cli.sh in TREE
# from SEED under a 6144 MiB cap (the allocator-peak gate's cap). Output root
# TREE/target/cbench; its summary is TREE/target/cbench/summary.tsv. Appends
# "TREE cbench rc=N" to tools/done.txt.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
cd "$T" || exit 1
rm -rf "$T/target/cbench"
env -u TYPELISP_BIN TYPELISP_COMPILE_BENCH_OUT="$T/target/cbench" \
    "$W/scripts/run-memory-bounded.sh" --limit-mib 6144 --timeout-seconds 7200 \
    --report "$T/target/cbench.mem" -- sh scripts/benchmark-compile-cli.sh "$2" \
    > "$T/target/cbench.log" 2>&1
echo "$T cbench rc=$?" >> "$W/target/exp/tools/done.txt"
