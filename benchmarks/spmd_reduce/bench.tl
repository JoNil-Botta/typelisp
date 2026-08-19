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
;# keeps each pass distinct (no hoisting) and the `base-reps + (io.arg-count)`
;# trip count (io.arg-count is 1 with no extra arguments, matching C `argc`) keeps
;# the result deterministic while preventing whole-loop constant folding.
; SPMD value operands use direct array-ref over a generated Vec's borrowed
; native Slice so the checker sees the compiler array-read AST.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as i64v)

(define array-len : i64
  4096)
(define base-reps : i64
  300000)

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

(define (init [a : (&mut a (Slice i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (+ i 1))
        (set! i (+ i 1))))))

(define (reduce-kernel [a : (& a (Slice i64))] [r : i64]) : i64
  (spmd-reduce sum ([i : i64 0 array-len]) 0 (+ (array-ref a i) r)))

(define (main) : i64
  (let
    [a : i64v.Vec (make-buffer array-len)]
    [reps : i64 (+ base-reps (io.arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (let
        [init-view : (&mut a (Slice i64)) (i64v.view-mut (&mut a))]
        (init init-view array-len))
      (let
        [a-view : (& a (Slice i64)) (i64v.view (& a))]
        ;; Keep the microkernel as a separately measured call. The binding
        ;; prevents whole-program inlining from folding it into the outer
        ;; repetition loop while retaining the native Slice ABI.
        [kernel : (-> (& a (Slice i64)) i64 i64) reduce-kernel]
        (begin
          (while (< r reps)
            (begin
              (set! acc (+ acc (kernel a-view r)))
              (set! r (+ r 1))))
          (bit-and acc 255))))))