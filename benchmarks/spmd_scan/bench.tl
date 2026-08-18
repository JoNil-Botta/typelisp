;# benchmarks/spmd_scan/bench.tl - inclusive SPMD scan micro-benchmark (#5349).
;#
;# Equivalent to benchmarks/spmd_scan/baseline.c. Each pass writes the
;# inclusive prefix of a fixed i64 array, seeded by the pass number, then folds
;# a pass-varying prefix into an observable accumulator. The direct contiguous
;# array-ref/array-set! shape is the canonical AVX2/AVX-512 scan lowering.
;#
;# The i64 additions wrap modulo 2^64, matching the baseline's uint64_t
;# arithmetic. `base-reps + io.arg-count` prevents whole-program constant
;# folding while retaining a deterministic no-argument exit status.
; SPMD value operands and direct scan body writes use array helpers over native
; Slices so the checker sees compiler array ASTs.
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

(define (scan-kernel
  [a : (& a (Slice i64))]
  [out : (&mut out (Slice i64))]
  [r : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 array-len] [prefix : i64 r])
    (array-ref a i)
    (set! (array-ref out i) prefix)))

(define (main) : i64
  (let
    [a : i64v.Vec (make-buffer array-len)]
    [out : i64v.Vec (make-buffer array-len)]
    [reps : i64 (+ base-reps (io.arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (let
        [init-view : (&mut a (Slice i64)) (i64v.view-mut (&mut a))]
        (init init-view array-len))
      (let
        [a-view : (& a (Slice i64)) (i64v.view (& a))]
        [out-view : (&mut out (Slice i64)) (i64v.view-mut (&mut out))]
        [kernel : (-> (& a (Slice i64)) (&mut out (Slice i64)) i64 unit)
          scan-kernel]
        (begin
          (while (< r reps)
            (begin
              (kernel a-view out-view r)
              (set!
                acc
                (+ acc (array-ref out-view (bit-and r (- array-len 1)))))
              (set! r (+ r 1))))
          (bit-and acc 255))))))