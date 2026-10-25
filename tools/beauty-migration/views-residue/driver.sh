#!/bin/sh
# usage: driver.sh FIRST LAST: alternate flip and consumer rounds FIRST..LAST, committing WIP after
# each phase. Round k: flip all free seq-ref sites (state-fK), collect the by-value consumers from
# its revert log, convert them (cons-K.json seeded from the previous round's failures).
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
R=$W/target/exp/residue
cd "$W" || exit 1
k=$1
while [ "$k" -le "$2" ]; do
  python3 "$R/mysites.py" > "$R/sites-r$k.txt"
  awk -F'\t' '$4=="-" {print $1}' "$R/sites-r$k.txt" > "$R/free-r$k.txt"
  python3 "$R/flipLoop.py" "$R/state-f$k.txt" --flip "$R/free-r$k.txt" > "$R/flip-r$k.out" 2>&1
  tail -1 "$R/flip-r$k.out"
  grep -q "clean after" "$R/flip-r$k.out" || { echo "flip round $k did not finish clean"; exit 1; }
  git commit -qam "WIP residue: flips round $k"
  cut -f4 "$R/state-f$k.txt.log" | grep -oE 'call `[a-z][^`]*` argument [0-9]+ \(parameter `[^`]+`\) type mismatch: expected [^(][^,]*, found \(&' | sed -E 's/call `([^`]+)` argument [0-9]+ \(parameter `([^`]+)`\).*/\1\t\2/' | sort -u > "$R/cands-r$k.txt"
  grep "cannot move borrowed place" "$R/state-f$k.txt.log" | awk -F'\t' '{print $2"\t"$4}' | sed -E 's/^\(define \(([^ ]+).*cannot move borrowed place `([^`.]+)`.*/\1\t\2/' | grep -v "^(" | awk -F'\t' 'NF==2' >> "$R/cands-r$k.txt"
  cat "$R/cands-all.txt" >> "$R/cands-r$k.txt"
  sort -u -o "$R/cands-r$k.txt" "$R/cands-r$k.txt"
  prev=$((k - 1))
  python3 "$R/reseed.py" "$R/cons-r$prev.json" "$R/cons-r$k.json" > /dev/null
  python3 "$R/consLoop.py" "$R/cands-r$k.txt" "$R/cons-r$k.json" > "$R/cons-r$k.out" 2>&1
  tail -1 "$R/cons-r$k.out"
  grep -q "clean after" "$R/cons-r$k.out" || { echo "cons round $k did not finish clean"; exit 1; }
  conv=$(grep -c "^convert" "$R/cons-r$k.out")
  git commit -qam "WIP residue: consumer conversions round $k" || true
  k=$((k + 1))
done
