#!/usr/bin/env bash
set -u
CC="$1"; cd "$(dirname "$0")/.."; D=/tmp/ofuzz; mkdir -p "$D"; FAIL=0; N=0
chk() { local name="$1" exp="$2" src="$3"; printf '%s\n' "$src" > "$D/$name.tl"
  "$CC" build "$D/$name.tl" -o "$D/$name" --target linux-x86_64 --opt-level 2 --stdlib-root stdlib --stdlib-root src >"$D/$name.log" 2>&1 || { echo "BUILD-FAIL $name"; FAIL=$((FAIL+1)); return; }
  local o; o=$("$D/$name" 2>/dev/null); N=$((N+1))
  [ "$o" = "$exp" ] && : || { echo "*** WRONG $name: got [$o] expected [$exp]"; FAIL=$((FAIL+1)); }
}
# 8-way heptanacci-ish, high pressure
chk hept "$(python3 -c 'a=[1,2,3,4,5,6,7,8]
for _ in range(400):
 t=sum(a)&2047; a=a[1:]+[t]
print(a[-1])')" '(import "stdlib/io.tl")
(define (main) : i64 (let [a : i64 1][b : i64 2][c : i64 3][d : i64 4][e : i64 5][f : i64 6][g : i64 7][h : i64 8][i : i64 0] (begin (while (< i 400) (begin (let [t : i64 (bit-and (+ a (+ b (+ c (+ d (+ e (+ f (+ g h))))))) 2047)] (begin (set! a b)(set! b c)(set! c d)(set! d e)(set! e f)(set! f g)(set! g h)(set! h t))) (set! i (+ i 1)))) (print h) (print-newline) 0)))'
# nested with 4 outer carried
chk nest4 "$(python3 -c 's=p=q=r=0
for o in range(40):
 inn=0
 for i in range(40):
  inn=(inn+o*i)&1048575
 s=(s+inn)&1048575; p=(p+o)&1048575; q=(q*2+1)&1048575; r=(r+inn-o)&1048575
print((s+p+q+r)&1048575)')" '(import "stdlib/io.tl")
(define (main) : i64 (let [s : i64 0][p : i64 0][q : i64 0][r : i64 0][o : i64 0] (begin (while (< o 40) (begin (let [in : i64 0][i : i64 0] (begin (while (< i 40) (begin (set! in (bit-and (+ in (* o i)) 1048575)) (set! i (+ i 1)))) (set! s (bit-and (+ s in) 1048575)) (set! p (bit-and (+ p o) 1048575)) (set! q (bit-and (+ (* q 2) 1) 1048575)) (set! r (bit-and (+ r (- in o)) 1048575)))) (set! o (+ o 1)))) (print (bit-and (+ s (+ p (+ q r))) 1048575)) (print-newline) 0)))'
# polynomial horner with 6 coeffs carried
chk horner "$(python3 -c 'acc=0
for x in range(1,200):
 v=0
 for c in [3,1,4,1,5,9]:
  v=(v*x+c)&16777215
 acc=(acc+v)&16777215
print(acc)')" '(import "stdlib/io.tl")
(define (poly [x : i64]) : i64 (let [v : i64 0][c0 : i64 3][c1 : i64 1][c2 : i64 4][c3 : i64 1][c4 : i64 5][c5 : i64 9] (begin (set! v (bit-and (+ (* v x) c0) 16777215)) (set! v (bit-and (+ (* v x) c1) 16777215)) (set! v (bit-and (+ (* v x) c2) 16777215)) (set! v (bit-and (+ (* v x) c3) 16777215)) (set! v (bit-and (+ (* v x) c4) 16777215)) (set! v (bit-and (+ (* v x) c5) 16777215)) v))
(define (main) : i64 (let [acc : i64 0][x : i64 1] (begin (while (< x 200) (begin (set! acc (bit-and (+ acc (poly x)) 16777215)) (set! x (+ x 1)))) (print acc) (print-newline) 0)))'
echo "ORACLE-FUZZ: $N programs, $FAIL wrong"; [ "$FAIL" -eq 0 ]
