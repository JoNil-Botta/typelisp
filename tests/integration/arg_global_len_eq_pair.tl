;; GAP-1 runtime coverage: two module-global Vecs reset to ONE length in one
;; straight-line region, then handed to a helper as `(& ...)` parameters -- the
;; cfg/dominator helper shape. `pair-fold` names no global at all, so the
;; whole-program length-equality relation over the two cells is reachable
;; inside it only through the call-site fact that says which global each
;; parameter is; with it the second bounds check on the shared index is
;; retired on the first, and at opt2 the helper runs with one check. The sum
;; must come out the same either way and every index must stay in range.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define pair-left : i64vec.Vec
  (zero-vec 1))
(define pair-right : i64vec.Vec
  (zero-vec 1))

;; One index, two arrays, two bounds checks -- and both arrays arrive as
;; reference parameters.
(define (pair-fold
  [left-vec : (& left i64vec.Vec)]
  [right-vec : (& right i64vec.Vec)]
  [count : i64]
  [scale : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! acc (+ acc (* scale (array-ref (i64vec.slots left-vec) i))))
          (set! acc (+ acc (array-ref (i64vec.slots right-vec) i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [i : i64 0]
    (begin
      (set! pair-left (zero-vec n))
      (set! pair-right (zero-vec n))
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut pair-left)) i) (+ i 1))
          (set! (array-ref (i64vec.slots-mut (&mut pair-right)) i) (- n i))
          (set! i (+ i 1))))
      (io.print-format
        "{}\n"
        (+
          (pair-fold (& pair-left) (& pair-right) n 5)
          (+
            (pair-fold (& pair-left) (& pair-right) (- n 1) 7)
            (pair-fold (& pair-left) (& pair-right) (- n 2) 11))))
      42)))