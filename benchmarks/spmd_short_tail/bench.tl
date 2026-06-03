;# benchmarks/spmd_short_tail/bench.tl - SPMD short-tail micro-benchmark (#1125).
;#
;# Equivalent to benchmarks/spmd_short_tail/baseline.c. Both run `reps` passes
;# of an elementwise map `out[i] = a[i] + b[i] + r` over an array whose length
;# (1000) is deliberately NOT a multiple of any SIMD lane width (4/8/16), so a
;# vectorized lowering must handle a remainder/tail. On the current scalar
;# backend it is a plain loop; the point is the trip-count shape that #937's
;# SIMD work must get right at the tail. TypeLisp `+` wraps modulo 2^64 (SPEC),
;# matching C `uint64_t`, so both programs produce the identical exit code.
;#
;# The array is cache-resident and the outer repetition loop makes the work
;# runtime-dominant; the per-pass `r` term blocks kernel hoisting and the
;# `base-reps + (arg-count)` trip count (arg-count is 1 with no extra
;# arguments, matching C `argc`) keeps the result deterministic while
;# preventing whole-loop constant folding. The folded index `r % array-len`
;# (modulo, since the length is not a power of two) reads a different element
;# each pass so the stored array cannot be eliminated.
(import "stdlib/io.tl")

(define array-len : i64
  1000)

(define base-reps : i64
  1000000)

(define (init [a : (Array i64)] [b : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (+ i 1))
        (array-set! b i (* i 2))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 array-len)]
    [b : (Array i64) (make-array i64 array-len)]
    [out : (Array i64) (make-array i64 array-len)]
    [reps : i64 (+ base-reps (arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (init a b array-len)
      (while (< r reps)
        (begin
          (foreach
            ([i : i64 0 array-len])
            (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r)))
          (set! acc (+ acc (array-ref out (% r array-len))))
          (set! r (+ r 1))))
      (bit-and acc 255))))
