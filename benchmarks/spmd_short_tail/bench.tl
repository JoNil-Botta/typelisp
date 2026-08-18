;# benchmarks/spmd_short_tail/bench.tl - SPMD short-tail micro-benchmark (#1125).
;#
;# Equivalent to benchmarks/spmd_short_tail/baseline.c. Both run `reps` passes
;# of an elementwise map `out[i] = a[i] + b[i] + r` over an array whose length
;# (1003) is deliberately not a multiple of the i64 AVX2 or AVX-512 lane widths
;# (4 and 8), so a vectorized lowering must execute a remainder/tail. On the
;# scalar backend it is a plain loop; the point is the trip-count shape that
;# SIMD work must get right at the tail. TypeLisp `+` wraps modulo 2^64 (SPEC),
;# matching C `uint64_t`, so both programs produce the identical exit code.
;#
;# The array is cache-resident and the outer repetition loop makes the work
;# runtime-dominant; the per-pass `r` term blocks kernel hoisting and the
;# `base-reps + (io.arg-count)` trip count (io.arg-count is 1 with no extra
;# arguments, matching C `argc`) keeps the result deterministic while
;# preventing whole-loop constant folding. The folded index `r % array-len`
;# (modulo, since the length is not a power of two) reads a different element
;# each pass so the stored array cannot be eliminated.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as i64v)

(define array-len : i64
  1003)
(define base-reps : i64
  1000000)

(define (make-buffer [capacity : i64]) : i64v.Vec
  (let
    [out : i64v.Vec (i64v.with-capacity capacity)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (i64v.push-ref! (&mut out) 0)
          (set! i (+ i 1))))
      out)))

(define (init [a : (&mut a (Slice i64))] [b : (&mut b (Slice i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (+ i 1))
        (set! (array-ref b i) (* i 2))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [a : i64v.Vec (make-buffer array-len)]
    [b : i64v.Vec (make-buffer array-len)]
    [out : i64v.Vec (make-buffer array-len)]
    [a-view : (&mut a (Slice i64)) (i64v.view-mut (&mut a))]
    [b-view : (&mut b (Slice i64)) (i64v.view-mut (&mut b))]
    [out-view : (&mut out (Slice i64)) (i64v.view-mut (&mut out))]
    [reps : i64 (+ base-reps (io.arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (init a-view b-view array-len)
      (while (< r reps)
        (begin
          (foreach
            ([i : i64 0 array-len])
            (set!
              (array-ref out-view i)
              (+ (+ (array-ref a-view i) (array-ref b-view i)) r)))
          (set! acc (+ acc (array-ref out-view (% r array-len))))
          (set! r (+ r 1))))
      (bit-and acc 255))))