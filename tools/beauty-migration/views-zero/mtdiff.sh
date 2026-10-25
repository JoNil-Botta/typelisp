#!/bin/sh
# usage: mtdiff.sh PR FILE: diff the merge of origin/main+PR against the merge of HEAD+PR for FILE;
# the hunks that carry conflict markers are conflicts HEAD adds.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
P=$1; F=$2
O=target/exp/zero/mtdiff
mkdir -p "$O"
tm=$(git merge-tree --write-tree origin/main "refs/pr/$P" 2>/dev/null | head -1)
th=$(git merge-tree --write-tree HEAD "refs/pr/$P" 2>/dev/null | head -1)
git show "$tm:$F" > "$O/main.txt"
git show "$th:$F" > "$O/head.txt"
sed -i "s/^<<<<<<< .*/<<<<<<< X/" "$O/main.txt" "$O/head.txt"
diff -U3 "$O/main.txt" "$O/head.txt" > "$O/diff.txt"
python3 - "$O/diff.txt" <<'EOF'
import sys
text = open(sys.argv[1]).read()
hunks = text.split("\n@@")
for h in hunks[1:]:
    if "<<<<<<<" in h or ">>>>>>>" in h or "=======" in h:
        print("@@" + h[:1500])
        print("-----")
EOF
