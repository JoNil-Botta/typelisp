;# benchmarks/spmd_map/bench.tl - SPMD elementwise-map micro-benchmark (#1125).
;#
;# Equivalent to benchmarks/spmd_map/baseline.c. Both run `reps` passes of an
;# elementwise map `out[i] = a[i] + b[i] + r` over a fixed-size array using
;# TypeLisp's data-parallel `foreach`, then fold one element of each pass into
;# an accumulator and return its low byte as the process exit code. TypeLisp
;# `+` wraps modulo 2^64 (SPEC), matching C `uint64_t`, so both programs
;# produce the identical exit code on a given host.
;#
;# The array is kept small (fits in cache, modest memory) and the work is made
;# runtime-dominant by an outer repetition loop. The per-pass `r` term makes
;# each pass distinct so the compiler cannot hoist the kernel out of the loop,
;# and the trip count `base-reps + (io.arg-count)` (io.arg-count is 1 with no extra
;# arguments, matching C `argc`) keeps the result deterministic while
;# preventing whole-loop constant folding.
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
          (set! acc (+ acc (array-ref out-view (bit-and r (- array-len 1)))))
          (set! r (+ r 1))))
      (bit-and acc 255))))