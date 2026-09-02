;; The negative twin of content_bounds_induction: the SAME shape fed a corpus
;; that drives the loop counter's BOUND to the array length. With `bump` = 1 the
;; count handed to `ind-fill` is `n`, which is out of range for `ab-keys`, and
;; the `keys[count]` store -- the very check CB-2 reads to tie the loop bound to
;; the family -- is the one that fires. CB-2 changes nothing about that run: it
;; retires no store-side check, so the abort site and message must be
;; byte-identical to the base compiler's at every optimization level. The
;; load-side check CB-2 does retire could not have been the one to fire; the
;; program stops at the bound's own check before the counter is ever stored.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define ab-keys : i64vec.Vec
  (zero-vec 1))
(define ab-marks : i64vec.Vec
  (zero-vec 1))
(define ab-scatter : i64vec.Vec
  (zero-vec 1))
(define ab-slot : i64vec.Vec
  (zero-vec 1))

(define (ab-fill
  [scatter-vec : (&mut scatter i64vec.Vec)]
  [keys-vec : (&mut keys i64vec.Vec)]
  [slot-vec : (& slot i64vec.Vec)]
  [count : i64]) : i64
  (let
    [scatter (i64vec.slots-mut scatter-vec)]
    [keys (i64vec.slots-mut keys-vec)]
    [slot (i64vec.slots slot-vec)]
    [i : i64 0]
    (begin
      (set! (array-ref keys count) 0)
      (while (< i count)
        (begin
          (set! (array-ref scatter (array-ref slot i)) i)
          (set! i (+ i 1))))
      count)))

(define (ab-walk
  [scatter-vec : (& scatter i64vec.Vec)]
  [marks-vec : (&mut marks i64vec.Vec)]
  [total : i64]) : i64
  (let
    [scatter (i64vec.slots scatter-vec)]
    [marks (i64vec.slots-mut marks-vec)]
    [j : i64 0]
    [acc : i64 0]
    (begin
      (set! (array-ref marks 0) 1)
      (while (< j total)
        (let
          [e : i64 (array-ref scatter j)]
          (begin
            (set! (array-ref marks e) (+ (array-ref marks e) 1))
            (set! acc (+ acc (array-ref marks e)))
            (set! j (+ j 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [m : i64 (* n 2)]
    [i : i64 0]
    (begin
      (set! ab-keys (zero-vec n))
      (set! ab-marks (zero-vec n))
      (set! ab-scatter (zero-vec m))
      (set! ab-slot (zero-vec m))
      (while (< i m)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut ab-slot)) i) i)
          (set! i (+ i 1))))
      (ab-fill (&mut ab-scatter) (&mut ab-keys) (& ab-slot) (- (+ n bump) 1))
      (io.print-format "{}\n" (ab-walk (& ab-scatter) (&mut ab-marks) m))
      42)))