#!/usr/bin/env bash
# Differential fuzz: generate diverse loop programs, compile with two compilers, diff output.
set -u
A="$1"; B="$2"; cd "$(dirname "$0")/.."; D=/tmp/dfuzz; mkdir -p "$D"; FAIL=0; N=0
gen() { # name  body-tl
  local name="$1"; shift; printf '%s\n' "$1" > "$D/$name.tl"
  "$A" build "$D/$name.tl" -o "$D/$name.a" --target linux-x86_64 --opt-level 2 --stdlib-root stdlib --stdlib-root src >"$D/$name.alog" 2>&1; local ra=$?
  "$B" build "$D/$name.tl" -o "$D/$name.b" --target linux-x86_64 --opt-level 2 --stdlib-root stdlib --stdlib-root src >"$D/$name.blog" 2>&1; local rb=$?
  N=$((N+1))
  if [ $ra -ne 0 ] && [ $rb -ne 0 ]; then return; fi
  if [ $ra -ne 0 ] || [ $rb -ne 0 ]; then echo "BUILD-DIFF $name (a=$ra b=$rb)"; FAIL=$((FAIL+1)); return; fi
  local oa ob; oa=$("$D/$name.a" 2>/dev/null); local ca=$?; ob=$("$D/$name.b" 2>/dev/null); local cb=$?
  if [ "$oa" = "$ob" ] && [ "$ca" = "$cb" ]; then :; else echo "*** MISMATCH $name: A=[$oa]($ca) B=[$ob]($cb)"; FAIL=$((FAIL+1)); fi
}
# nested loops, outer accumulates inner
gen nest1 '(import "stdlib/io.tl")
(define (main) : i64 (let [s : i64 0] [o : i64 0] (begin (while (< o 50) (begin (let [in : i64 0] [i : i64 0] (begin (while (< i 50) (begin (set! in (+ in (* o i))) (set! i (+ i 1)))) (set! s (+ s in)))) (set! o (+ o 1)))) (print s) (print-newline) 0)))'
# triple nest
gen nest2 '(import "stdlib/io.tl")
(define (main) : i64 (let [s : i64 0] [a : i64 0] (begin (while (< a 20) (begin (let [b : i64 0] (begin (while (< b 20) (begin (let [c : i64 0] (begin (while (< c 20) (begin (set! s (+ s (+ a (+ b c)))) (set! c (+ c 1)))))) (set! b (+ b 1)))))) (set! a (+ a 1)))) (print s) (print-newline) 0)))'
# 5 accumulators
gen acc5 '(import "stdlib/io.tl")
(define (main) : i64 (let [a : i64 0][b : i64 0][c : i64 0][d : i64 0][e : i64 0][i : i64 1] (begin (while (<= i 500) (begin (set! a (+ a i))(set! b (+ b (* i 2)))(set! c (+ c (* i 3)))(set! d (+ d (* i 5)))(set! e (+ e (* i 7)))(set! i (+ i 1)))) (print (+ a (+ b (+ c (+ d e))))) (print-newline) 0)))'
# 7-way rotation
gen rot7 '(import "stdlib/io.tl")
(define (main) : i64 (let [a : i64 1][b : i64 2][c : i64 3][d : i64 4][e : i64 5][f : i64 6][g : i64 7][i : i64 0] (begin (while (< i 300) (begin (let [t : i64 (+ a (+ b (+ c (+ d (+ e (+ f g))))))] (begin (set! a b)(set! b c)(set! c d)(set! d e)(set! e f)(set! f g)(set! g (bit-and t 1023)))) (set! i (+ i 1)))) (print g) (print-newline) 0)))'
# call in loop
gen call1 '(import "stdlib/io.tl")
(define (sq [x : i64]) : i64 (* x x))
(define (main) : i64 (let [s : i64 0][i : i64 0] (begin (while (< i 100) (begin (set! s (+ s (sq i))) (set! i (+ i 1)))) (print s) (print-newline) 0)))'
# call result feeds next iter
gen call2 '(import "stdlib/io.tl")
(define (step [x : i64]) : i64 (+ (* x 3) 1))
(define (main) : i64 (let [x : i64 1][i : i64 0][s : i64 0] (begin (while (< i 50) (begin (set! x (bit-and (step x) 65535)) (set! s (+ s x)) (set! i (+ i 1)))) (print s) (print-newline) 0)))'
# control flow: conditional accumulate
gen ctl1 '(import "stdlib/io.tl")
(define (main) : i64 (let [s : i64 0][i : i64 0] (begin (while (< i 200) (begin (if (= (% i 3) 0) (set! s (+ s i)) (set! s (+ s 1))) (set! i (+ i 1)))) (print s) (print-newline) 0)))'
# control flow: min/max tracking
gen ctl2 '(import "stdlib/io.tl")
(define (main) : i64 (let [mn : i64 999999][mx : i64 0][i : i64 1] (begin (while (<= i 100) (begin (let [v : i64 (% (* i 37) 101)] (begin (if (< v mn) (set! mn v) unit) (if (> v mx) (set! mx v) unit))) (set! i (+ i 1)))) (print (+ (* mn 1000) mx)) (print-newline) 0)))'
# div/mod in loop
gen div1 '(import "stdlib/io.tl")
(define (main) : i64 (let [h : i64 5381][i : i64 1] (begin (while (<= i 1000) (begin (set! h (bit-and (+ (* h 33) i) 1048575)) (set! h (% h 7919)) (set! i (+ i 1)))) (print h) (print-newline) 0)))'
# array rw with running index
gen arr1 '(import "stdlib/io.tl")
(define (main) : i64 (let [xs : (Array i64) (make-array i64 100)][i : i64 0][s : i64 0] (begin (while (< i 100) (begin (array-set! xs i (* i i)) (set! i (+ i 1)))) (set! i 0) (while (< i 100) (begin (set! s (+ s (array-ref xs i))) (set! i (+ i 1)))) (print s) (print-newline) 0)))'
# long body many temps
gen long1 '(import "stdlib/io.tl")
(define (main) : i64 (let [a : i64 1][b : i64 2][i : i64 0] (begin (while (< i 400) (begin (let [t1 : i64 (+ a b)][t2 : i64 (* a 3)][t3 : i64 (+ b 5)][t4 : i64 (* t1 2)][t5 : i64 (+ t2 t3)][t6 : i64 (+ t4 t5)] (begin (set! a (bit-and (+ t6 b) 262143)) (set! b (bit-and (+ t1 t2) 262143)))) (set! i (+ i 1)))) (print (+ a b)) (print-newline) 0)))'
# swap two
gen swap1 '(import "stdlib/io.tl")
(define (main) : i64 (let [a : i64 12345][b : i64 67890][i : i64 0] (begin (while (< i 1000) (begin (let [t : i64 a] (begin (set! a (bit-and (+ b i) 1048575)) (set! b t))) (set! i (+ i 1)))) (print (+ a b)) (print-newline) 0)))'
echo "=========================================="; echo "DIFF-FUZZ: $N programs, $FAIL mismatches"; [ "$FAIL" -eq 0 ]
