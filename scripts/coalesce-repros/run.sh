#!/usr/bin/env bash
# #3489 loop-carried coalescing soundness repros (this-session findings).
# Each program below is MISCOMPILED by the M2 (segmented-interference phi
# coalescing) design but CORRECT on clean main. Usage: run.sh <tl-compiler>
# Run with BOTH a known-good compiler (expect all PASS) and any candidate fix.
set -u
CC="$1"; cd "$(dirname "$0")"; D=/tmp/coalrepro; mkdir -p "$D"; FAIL=0
check() { # name expected file [args...]
  local name="$1" exp="$2" f="$3"; shift 3
  if ! "$CC" build "$f" -o "$D/$name" --target linux-x86_64 --opt-level 2 \
        --stdlib-root stdlib --stdlib-root src >"$D/$name.log" 2>&1; then
    echo "BUILD-FAIL $name"; FAIL=1; return; fi
  local out; out=$("$D/$name" "$@" 2>/dev/null); local rc=$?
  if [ "$out" = "$exp" ] && [ "$rc" = 0 ]; then echo "PASS  $name -> $out"
  else echo "*** FAIL $name: got [$out] exit=$rc, expected [$exp] exit=0"; FAIL=1; fi
}
check fibonacci 17711 fibonacci.tl
check four_acc  5005000 four_acc.tl
check bce_sum   150 bce_sum.tl
echo "======"; [ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit $FAIL
