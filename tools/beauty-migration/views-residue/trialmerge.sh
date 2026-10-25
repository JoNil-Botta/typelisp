#!/bin/sh
# usage: trialmerge.sh BRANCH PR...: for each PR, merge BRANCH into the PR head on a throwaway branch,
# typecheck src/main.tl and the typecheck test roots, then go back to BRANCH and delete the branch.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
cd "$W" || exit 1
B=$1
shift
for p in "$@"; do
  git checkout -q -B "trial-merge-$p" "pr/$p" || exit 1
  if git merge -q --no-edit "$B" > "$W/target/exp/residue/trial-$p.merge.log" 2>&1; then
    echo "#$p merge clean"
    sh "$W/target/exp/residue/checkmany.sh" src/main.tl src/tests/compiler_typecheck_core_tests.tl src/tests/compiler_typecheck_smoke.tl 2>&1 | grep -v "^ *|\|^ *$"
  else
    echo "#$p merge conflicts:"
    git diff --name-only --diff-filter=U
    git merge --abort
  fi
  git checkout -q "$B"
  git branch -q -D "trial-merge-$p"
done
