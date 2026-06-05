;# benchmarks/array_sum/bench.tl - array-sum micro-benchmark (#1098).
;#
;# Equivalent to benchmarks/array_sum/baseline.c. Both fill an `(Array i64)`
;# with a deterministic pattern, then sum it `rounds` times into a wrapping
;# 64-bit accumulator and return the low byte as the process exit code.
;# TypeLisp `+`/`*` wrap modulo 2^64 (SPEC), matching C `uint64_t`, so both
;# programs produce the identical exit code on a given host.
;#
;# The array length and round count are `base + (arg-count)` (`arg-count` is 1
;# with no extra arguments, matching C `argc`), so neither trip count is a
;# compile-time constant. The running accumulator is stored back into the
;# array each round (`xs[r] = acc`), creating a cross-round data dependency:
;# without it the per-round sum would be loop-invariant and the optimizer
;# could collapse every round into a single pass times `rounds`.
(import "stdlib/io.tl")

(define base-size : i64
  200003)

(define base-rounds : i64
  6000)

(define (fill [xs : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (+ (* i 2654435761) 1013904223))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [n : i64 (+ base-size (arg-count))]
    [rounds : i64 (+ base-rounds (arg-count))]
    [xs : (Array i64) (make-array i64 (+ base-size (arg-count)))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (fill xs n)
      (while (< r rounds)
        (begin
          (let
            [i : i64 0]
            (while (< i n)
              (begin
                (set! acc (+ acc (array-ref xs i)))
                (set! i (+ i 1)))))
          (array-set! xs r acc)
          (set! r (+ r 1))))
      (bit-and acc 255))))