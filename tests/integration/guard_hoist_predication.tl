;; PRED-1's shape, and its own malformed twin: one source, two manifest rows.
;;
;; `gh-walk` counts DOWN from `count - 1`, so the FIRST index it checks is the
;; largest one it will ever check. That is the whole fact the clone-free hoist
;; needs: `data[count-1] <u data.len` decides every trip, and if it fails, it
;; fails on the very first one, before `gh-mix` has been called and before
;; anything has been written. So the check MOVES to the loop's preheader and the
;; body runs unchecked -- no clone, no guard block, no duplicated call site.
;;
;; `gh-mix` is a real call, and it is there on purpose: a call in the body is
;; what makes the loop VERSIONER refuse (it wants three derived checks per
;; duplicated call site and this loop offers one), so the check this fixture
;; watches is retired by the hoist or not at all.
;;
;; The twin is the SAME program with `bump` = 1: `gh-walk` is handed
;; `count = n + 1` while `gh-data` holds `n`, so the first access is `data[n]`
;; and the run aborts. The hoisted check is the one that fires -- it is the same
;; instruction, carrying its own ok-label, evaluated on the same index and the
;; same length the first iteration would have used -- so the abort site, the
;; index, the length and the exit status must be byte-identical to the base
;; compiler's at every optimization level. Nothing in the loop can have run
;; before it: the check is the header's first instruction.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define gh-data : i64vec.Vec
  (zero-vec 1))

(define (gh-mix [a : i64] [b : i64]) : i64
  (+ (* a 1000003) (* b 31)))

(define (gh-walk [data-vec : (& data i64vec.Vec)] [count : i64]) : i64
  (let
    [data (i64vec.slots data-vec)]
    [pos : i64 (- count 1)]
    [acc : i64 0]
    (begin
      (while (>= pos 0)
        (begin
          (set! acc (gh-mix acc (array-ref data pos)))
          (set! pos (- pos 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [i : i64 0]
    (begin
      (set! gh-data (zero-vec n))
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut gh-data)) i) (* i 7))
          (set! i (+ i 1))))
      (io.print-format "{}\n" (gh-walk (& gh-data) (+ n bump)))
      42)))