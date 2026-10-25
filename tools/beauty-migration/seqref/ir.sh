#!/bin/sh
# ir.sh TREE COMPILER TAG: cachegrind COMPILER self-compiling TREE's src/main.tl
# (measure-instruction-counts.sh --self-compile-only, 1 run), 8 GiB cap. One
# line "TAG rc=N <self_compile row>" to tools/ir-done.txt.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
cd "$T" || exit 1
rm -rf "$T/target/ir-$3"
env -u TYPELISP_BIN "$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 7200 \
    --report "$T/target/ir-$3.mem" -- sh scripts/measure-instruction-counts.sh --self-compile-only --runs 1 \
    --output "$T/target/ir-$3" "$2" > "$T/target/ir-$3.log" 2>&1
echo "$3 rc=$? $(grep '^self_compile' "$T/target/ir-$3.log" | tail -1)" >> "$W/target/exp/tools/ir-done.txt"
