;# benchmarks/spmd_scan/bench.tl - inclusive SPMD scan micro-benchmark (#5349).
;#
;# Equivalent to benchmarks/spmd_scan/baseline.c. Each pass writes the
;# inclusive prefix of a fixed i64 array, seeded by the pass number, then folds
;# a pass-varying prefix into an observable accumulator. The direct contiguous
;# array-ref/array-set! shape is the canonical AVX2 scan lowering.
;#
;# The i64 additions wrap modulo 2^64, matching the baseline's uint64_t
;# arithmetic. `base-reps + io.arg-count` prevents whole-program constant
;# folding while retaining a deterministic no-argument exit status.
; Compatibility exception for #3772: SPMD value operands and direct scan body
; writes use bare array helpers so the checker sees compiler array ASTs.
(import stdlib.array)
(import stdlib.io)

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
    [a : (Array i64) (array.make-array i64 array-len)]
    [out : (Array i64) (array.make-array i64 array-len)]
    [reps : i64 (+ base-reps (io.arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (init a array-len)
      (while (< r reps)
        (begin
          (spmd-scan
            sum
            ([i : i64 0 array-len] [prefix : i64 r])
            (array-ref a i)
            (array-set! out i prefix))
          (set! acc (+ acc (array-ref out (bit-and r (- array-len 1)))))
          (set! r (+ r 1))))
      (bit-and acc 255))))