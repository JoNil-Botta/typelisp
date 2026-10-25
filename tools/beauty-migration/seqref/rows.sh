#!/bin/sh
# rows.sh TREE COMPILER TAG: the two exact benchmark-row gates (main and heavy,
# benchmarks only) with COMPILER, 8 GiB cap, as ci-verify runs them. One
# summary line to tools/done.txt.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
C=$2
TAG=$3
cd "$T" || exit 1
TYPELISP_IR_CHECK_COMPILER=$C "$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 7200 \
    --report "$T/target/rows-$TAG.mem" -- sh scripts/check-instruction-counts.sh --benchmarks-only \
    --output "$T/target/rows-$TAG" > "$T/target/rows-$TAG.log" 2>&1
r1=$?
HEAVY=$(sh -c ". scripts/lib-benchmark.sh; benchmark_ci_case_csv '$T' instruction-heavy")
TYPELISP_IR_CHECK_COMPILER=$C "$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 7200 \
    --report "$T/target/rows-heavy-$TAG.mem" -- sh scripts/check-instruction-counts.sh \
    --baseline perf/insn-exec-heavy-baseline.tsv --benchmarks "$HEAVY" --benchmarks-only --runs 1 \
    --output "$T/target/rows-heavy-$TAG" > "$T/target/rows-heavy-$TAG.log" 2>&1
r2=$?
m_ok=$(grep -c '^benchmark/typelisp/.*| ok$' "$T/target/rows-$TAG.log")
m_bad=$(grep '^benchmark/typelisp/' "$T/target/rows-$TAG.log" | grep -vc '| ok$')
h_ok=$(grep -c '^benchmark/typelisp/.*| ok$' "$T/target/rows-heavy-$TAG.log")
h_bad=$(grep '^benchmark/typelisp/' "$T/target/rows-heavy-$TAG.log" | grep -vc '| ok$')
echo "rows $TAG main rc=$r1 $m_ok ok $m_bad not-ok; heavy rc=$r2 $h_ok ok $h_bad not-ok" >> "$W/target/exp/tools/done.txt"
