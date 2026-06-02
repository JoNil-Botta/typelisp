;# benchmarks/spmd_reduce/bench.tl - SPMD sum-reduction micro-benchmark (#1125).
;#
;# Equivalent to benchmarks/spmd_reduce/baseline.c. Both run `reps` passes of a
;# sum reduction `sum_i (a[i] + r)` over a fixed-size array and fold each pass
;# sum into an accumulator, returning its low byte as the process exit code.
;# This kernel uses TypeLisp's `spmd-reduce` form (the data-parallel reduction
;# that #937's SIMD work will vectorize); the C baseline is the equivalent
;# scalar accumulation loop. TypeLisp `+` wraps modulo 2^64 (SPEC), matching C
;# `uint64_t`, so both programs produce the identical exit code on a given host.
;#
;# As with the other kernels the array is cache-resident and the outer
;# repetition loop makes the reduction runtime-dominant; the per-pass `r` term
;# keeps each pass distinct (no hoisting) and the `base-reps + (arg-count)`
;# trip count (arg-count is 1 with no extra arguments, matching C `argc`) keeps
;# the result deterministic while preventing whole-loop constant folding.
(define array-len : i64
  4096)

(define base-reps : i64
  300000)

(define (init [a : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (+ i 1))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 array-len)]
    [reps : i64 (+ base-reps (arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (init a array-len)
      (while (< r reps)
        (begin
          (set!
            acc
            (+
              acc
              (spmd-reduce sum ([i : i64 0 array-len]) 0 (+ (array-ref a i) r))))
          (set! r (+ r 1))))
      (bit-and acc 255))))