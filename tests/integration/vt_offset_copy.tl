;; VT-1. The copy loop whose TEST reads `src + i`, not `i`: the shape
;; ssa_construct's `ssa-materialize` inner copy runs
;; (`out[dst + i] = in[src + i]` under `while (< (+ src i) stop)`), and the one
;; the multi-block counter recovery used to refuse outright -- its compare's
;; left operand is an Add of a loop-invariant value and the counter, so no
;; counter was recovered and both checks stayed for the whole trip count.
;;
;; With the offset recovery the counter's limit is `stop - src`, which the
;; guard computes with one subtraction behind `src >= 0` and `stop >= src`, and
;; the fast clone carries neither check.
;;
;; `bump` moves the loop's stop past the vector: at 0 every access is in range
;; and the printed fold pins the result; at 2 the write at `dst + i` is exactly
;; at `length`, so the run must still abort there with the same located message
;; the base compiler produced -- the versioning guard fails and the original,
;; still-checked loop runs.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (vt-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define vt-vec : i64vec.Vec
  (vt-zero-vec 1))

(define (vt-ref [index : i64]) : i64
  (array-ref (i64vec.slots (& vt-vec)) index))

(define (vt-set! [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut (&mut vt-vec)) index) value))

(define (vt-fill! [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (vt-set! index (+ (* index 7) 1))
        (set! index (+ index 1))))))

(define (vt-copy! [src : i64] [dst : i64] [stop : i64]) : unit
  (let
    [index : i64 0]
    (while (< (+ src index) stop)
      (begin
        (vt-set! (+ dst index) (+ (vt-ref (+ src index)) 1))
        (set! index (+ index 1))))))

(define (vt-fold [count : i64]) : i64
  (let
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! acc (+ (* acc 31) (vt-ref index)))
          (set! index (+ index 1))))
      acc)))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [len : i64 (+ (* count 2) 2)]
    (begin
      (set! vt-vec (vt-zero-vec len))
      (vt-fill! count)
      ;; `src` is READ back out of the vector so the compare's left operand
      ;; stays an Add of a runtime-invariant value and the counter: a literal
      ;; source folds the offset away and the loop is an ordinary counted one.
      (vt-copy! (vt-ref 0) (+ count 2) (+ (vt-ref 0) (+ count bump)))
      (io.print-format "{}\n" (vt-fold len))
      42)))