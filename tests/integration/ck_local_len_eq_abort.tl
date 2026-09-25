;; The negative twin of ck_local_len_eq: the same body fed a malformed cursor.
;; With `bump` = 1 the last cursor is `n`, out of range for every twin array,
;; so the run must stop at the FIRST check -- the `xs` read -- with the same
;; site and message at every optimization level.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (ck-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (ck-run [n : i64] [bump : i64]) : i64
  (let
    [xs : i64vec.Vec (ck-zero-vec n)]
    [ys : i64vec.Vec (ck-zero-vec n)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut xs)) i) (* i 3))
          (set! (array-ref (i64vec.slots-mut (&mut ys)) i) (+ i 1))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i n)
        (let
          [cursor : i64 (+ i bump)]
          (begin
            (set! acc (+ acc (array-ref (i64vec.slots (& xs)) cursor)))
            (set! acc (+ acc (array-ref (i64vec.slots (& ys)) cursor)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    (begin
      (io.print-format "{}\n" (ck-run n bump))
      42)))