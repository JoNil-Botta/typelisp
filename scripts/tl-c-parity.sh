#!/usr/bin/env bash
# TL-vs-C stdout+exit parity across all benchmarks. Usage: tl-c-parity.sh <tl-compiler>
set -u
CC="$1"
cd "$(dirname "$0")/.."
WORK=/tmp/parity; mkdir -p "$WORK"
PASS=0; FAIL=0
for d in benchmarks/*/; do
  name=$(basename "$d")
  bench="$d/bench.tl"; cbase="$d/baseline.c"
  [ -f "$bench" ] || continue
  [ -f "$cbase" ] || continue
  # args = text after the first '|' in optimization.tsv (skip comments), else empty
  args=""
  if [ -f "$d/optimization.tsv" ]; then
    line=$(grep -v '^#' "$d/optimization.tsv" | head -1)
    args="${line#*|}"
    [ "$args" = "$line" ] && args=""   # no pipe -> no args
  fi
  # build TL
  if ! "$CC" build "$bench" -o "$WORK/$name.tl" --target linux-x86_64 --opt-level 2 \
        --stdlib-root stdlib --stdlib-root src >"$WORK/$name.tlbuild.log" 2>&1; then
    echo "BUILD-FAIL(tl) $name"; tail -2 "$WORK/$name.tlbuild.log"; FAIL=$((FAIL+1)); continue
  fi
  # build C
  if ! clang -O2 "$cbase" -o "$WORK/$name.c" >"$WORK/$name.cbuild.log" 2>&1; then
    echo "BUILD-FAIL(c) $name"; FAIL=$((FAIL+1)); continue
  fi
  # run both
  tlout=$("$WORK/$name.tl" $args 2>/dev/null); tlrc=$?
  cout=$("$WORK/$name.c" $args 2>/dev/null); crc=$?
  if [ "$tlout" = "$cout" ] && [ "$tlrc" = "$crc" ]; then
    PASS=$((PASS+1)); printf "OK        %-26s args=[%s] exit=%s out=%s\n" "$name" "$args" "$tlrc" "${tlout:0:40}"
  else
    FAIL=$((FAIL+1)); printf "*** MISMATCH %-22s args=[%s]\n   TL: exit=%s out=[%s]\n    C: exit=%s out=[%s]\n" \
      "$name" "$args" "$tlrc" "$tlout" "$crc" "$cout"
  fi
done
echo "==========================================="
echo "PARITY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
