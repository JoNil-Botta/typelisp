#!/bin/sh
# usage: consround.sh K: the consumer half of round K (after flip round K produced state-fK).
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
R=$W/target/exp/residue
k=$1
cd "$W" || exit 1
cut -f4 "$R/state-f$k.txt.log" | grep -oE 'call `[a-z][^`]*` argument [0-9]+ \(parameter `[^`]+`\) type mismatch: expected [^(][^,]*, found \(&' | sed -E 's/call `([^`]+)` argument [0-9]+ \(parameter `([^`]+)`\).*/\1\t\2/' | sort -u > "$R/cands-r$k.txt"
grep "cannot move borrowed place" "$R/state-f$k.txt.log" | awk -F'\t' '{print $2"\t"$4}' | sed -E 's/^\(define \(([^ ]+).*cannot move borrowed place `([^`.]+)`.*/\1\t\2/' | grep -v "^(" | awk -F'\t' 'NF==2' >> "$R/cands-r$k.txt"
cat "$R/cands-all.txt" >> "$R/cands-r$k.txt"
sort -u -o "$R/cands-r$k.txt" "$R/cands-r$k.txt"
cp "$R/cands-r$k.txt" "$R/cands-all.txt"
prev=$((k - 1))
python3 "$R/reseed.py" "$R/cons-r$prev.json" "$R/cons-r$k.json" > /dev/null
python3 "$R/consLoop.py" "$R/cands-r$k.txt" "$R/cons-r$k.json" > "$R/cons-r$k.out" 2>&1
tail -1 "$R/cons-r$k.out"
grep -q "clean after" "$R/cons-r$k.out" || { echo "cons round $k did not finish clean"; exit 1; }
git commit -qam "WIP residue: consumer conversions round $k" || true
