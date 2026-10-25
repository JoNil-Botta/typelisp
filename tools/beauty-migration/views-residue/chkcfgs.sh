#!/bin/sh
# usage: chkcfgs.sh: typecheck src/main.tl under the extra cfgs CI builds use (one at a time and
# the tlci stress pair), with this worktree's stage0, 8 GiB cap.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
T=$W/target/stage0/typelisp
cd "$W" || exit 1
for c in "--cfg fs-rooted-linux-test-hooks" "--cfg compiler-arena-debug" "--cfg selfhost-compile-manifest" \
    "--cfg tlci-native-route-stress --cfg embedded-stdlib-tlci" "--cfg tlci-bootstrap-mutation-witness --cfg embedded-stdlib-tlci" \
    "--cfg stage0-build-version" "--cfg dependency-tlci-verification" "--cfg compile-startup-profile" \
    "--cfg compiler-surface-selftest" "--cfg test"; do
  sh "$W/target/exp/borrows/bounded.sh" chkcfg 8192 900 -- "$T" check src/main.tl --stdlib-root stdlib --stdlib-root src $c > "$W/target/exp/residue/chkcfg.log" 2>&1
  if grep -q "Type checking passed" "$W/target/exp/residue/chkcfg.log"; then
    echo "[$c] ok"
  else
    echo "[$c] FAILED"
    grep -m2 -A6 "^error" "$W/target/exp/residue/chkcfg.log"
  fi
done
