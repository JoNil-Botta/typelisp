#!/bin/sh
# peakrun.sh DRIVER INPUT_TREE LEVEL OUT: run a compile-profile DRIVER on
# INPUT_TREE's src/main.tl at LEVEL (the official profile workload command
# line), 6144 MiB cap; print OUT's name, the official profile_peak_live_delta
# and the output's sha.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
D=$1
T=$2
L=$3
O=$4
cd "$T" || exit 1
ROOT=$T
. "$T/scripts/lib-native-link.sh"
native_link_detect_host
"$W/scripts/run-memory-bounded.sh" --limit-mib 6144 --timeout-seconds 3600 \
    --report "$O.mem" -- "$D" compile src/main.tl -o "$O.s" \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root stdlib --stdlib-root src --opt-level "$L" > "$O.stdout" 2> "$O.stderr"
peak=$(awk -F'|' '$1 == "compile-profile" && $2 != "phase" {
        if ($2 ~ /^lower\.(ast_expr_pool|ast_type_pool|checked_program|ir\.|ir_arena\.)/) {
            next
        }
        if (($6 + 0) > peak) {
            peak = $6 + 0
        }
    }
    END { printf "%.0f\n", peak + 0 }' "$O.stderr")
echo "$(basename "$O") peak=$peak sha=$(sha256sum "$O.s" | cut -c1-16)"
