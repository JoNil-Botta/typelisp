;# benchmarks/spmd_zip/bench.tl - SPMD fused-multiply-add micro-benchmark (#1125).
;#
;# Equivalent to benchmarks/spmd_zip/baseline.c. Both run `reps` passes of a
;# three-input zip `out[i] = a[i] * b[i] + c[i] + r` over a fixed-size array
;# using TypeLisp's data-parallel `foreach`, then fold one element of each pass
;# into an accumulator and return its low byte as the process exit code.
;# TypeLisp `+`/`*` wrap modulo 2^64 (SPEC), matching C `uint64_t`, so both
;# programs produce the identical exit code on a given host.
;#
;# Like spmd_map, the array is cache-resident and the work is made
;# runtime-dominant by an outer repetition loop; the per-pass `r` term blocks
;# kernel hoisting and the `base-reps + (arg-count)` trip count (arg-count is 1
;# with no extra arguments, matching C `argc`) keeps the result deterministic
;# while preventing whole-loop constant folding. It exercises a multi-input
;# multiply-add lane body, complementing spmd_map's two-input add.
(import "stdlib/io.tl")

(define array-len : i64
  4096)

(define base-reps : i64
  300000)

(define (init [a : (Array i64)] [b : (Array i64)] [c : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (+ i 1))
        (array-set! b i (* i 2))
        (array-set! c i (+ i 3))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 array-len)]
    [b : (Array i64) (make-array i64 array-len)]
    [c : (Array i64) (make-array i64 array-len)]
    [out : (Array i64) (make-array i64 array-len)]
    [reps : i64 (+ base-reps (arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (init a b c array-len)
      (while (< r reps)
        (begin
          (foreach
            ([i : i64 0 array-len])
            (array-set!
              out
              i
              (+ (+ (* (array-ref a i) (array-ref b i)) (array-ref c i)) r)))
          (set! acc (+ acc (array-ref out (bit-and r (- array-len 1)))))
          (set! r (+ r 1))))
      (bit-and acc 255))))
