;; The negative twin of content_bounds_csr: the SAME shape fed a malformed
;; corpus. `cb-src` carries the raw values, and with `bump` = 1 the last one is
;; `n`, which is out of range for `cb-keys`. CB-1 changes nothing about that
;; run: the store-side check is the one that fires, it is never retired, and the
;; abort site and message must be byte-identical to the base compiler's. The
;; load-side check CB-1 does retire could not have been the one to fire -- the
;; program stops at the store side before anything reads `cb-edges`.
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
(define ab-edges : i64vec.Vec
  (zero-vec 1))
(define ab-src : i64vec.Vec
  (zero-vec 1))

(define (ab-fill
  [edges-vec : (&mut edges i64vec.Vec)]
  [keys-vec : (&mut keys i64vec.Vec)]
  [src-vec : (& src i64vec.Vec)]
  [total : i64]) : i64
  (let
    [edges (i64vec.slots-mut edges-vec)]
    [keys (i64vec.slots-mut keys-vec)]
    [src (i64vec.slots src-vec)]
    [i : i64 0]
    (begin
      (while (< i total)
        (let
          [v : i64 (array-ref src i)]
          (begin
            (set! (array-ref keys v) (+ (array-ref keys v) 1))
            (set! (array-ref edges i) v)
            (set! i (+ i 1)))))
      total)))

(define (ab-walk
  [edges-vec : (& edges i64vec.Vec)]
  [marks-vec : (&mut marks i64vec.Vec)]
  [total : i64]) : i64
  (let
    [edges (i64vec.slots edges-vec)]
    [marks (i64vec.slots-mut marks-vec)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (set! (array-ref marks 0) 1)
      (while (< i total)
        (let
          [e : i64 (array-ref edges i)]
          (begin
            (set! (array-ref marks e) (+ (array-ref marks e) 1))
            (set! acc (+ acc (array-ref marks e)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [i : i64 0]
    (begin
      (set! ab-keys (zero-vec n))
      (set! ab-marks (zero-vec n))
      (set! ab-edges (zero-vec n))
      (set! ab-src (zero-vec n))
      (while (< i n)
        (begin
          (set!
            (array-ref (i64vec.slots-mut (&mut ab-src)) i)
            (if (= i (- n 1))
              (+ i bump)
              i))
          (set! i (+ i 1))))
      (ab-fill (&mut ab-edges) (&mut ab-keys) (& ab-src) n)
      (io.print-format "{}\n" (ab-walk (& ab-edges) (&mut ab-marks) n))
      42)))