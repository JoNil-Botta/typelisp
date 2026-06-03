;# benchmarks/arith_loop/bench.tl - arithmetic-loop micro-benchmark (#1097).
;#
;# Equivalent to benchmarks/arith_loop/baseline.c. Both run an LCG recurrence
;# for `iterations` steps over wrapping 64-bit integer arithmetic and return
;# the low byte of the accumulator as the process exit code. TypeLisp `+`/`*`
;# wrap modulo 2^64 (SPEC), matching C `uint64_t`, so both programs produce
;# the identical exit code on a given host.
;#
;# The trip count is `base-iterations + (arg-count)`, where `arg-count` is 1
;# with no extra arguments (matching C `argc`). Deriving it from a runtime
;# value keeps the result deterministic while preventing the compiler from
;# constant-folding the whole loop away.
(import "stdlib/io.tl")

(define base-iterations : i64
  1000000000)

(define (main) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    [iterations : i64 (+ base-iterations (arg-count))]
    (begin
      (while (< i iterations)
        (begin
          (set! acc (+ (* acc 1664525) 1013904223))
          (set! i (+ i 1))))
      (bit-and acc 255))))
