;# benchmarks/spmd_shuffle/bench.tl - checked SPMD shuffle benchmark (#5351).
;#
;# Equivalent to baseline.c. Each pass maps `out[i] = a[i] + r`; the TypeLisp
;# spelling routes that value through an identity intra-gang `spmd-shuffle`.
;# Identity keeps scalar, AVX2, AVX-512, and C observables identical. SIMD
;# lowering recognizes this compile-time selector and forwards the source
;# vector without selector validation or a native permutation.
;# The selected output element is folded into an accumulator after every pass.
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
        (set! (array-ref a i) (+ (* i 3) 1))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [a : i64v.Vec (make-buffer array-len)]
    [out : i64v.Vec (make-buffer array-len)]
    [a-view : (&mut a (Slice i64)) (i64v.view-mut (&mut a))]
    [out-view : (&mut out (Slice i64)) (i64v.view-mut (&mut out))]
    [reps : i64 (+ base-reps (io.arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (init a-view array-len)
      (while (< r reps)
        (begin
          (foreach
            ([i : i64 0 array-len])
            (set!
              (array-ref out-view i)
              (spmd-shuffle (+ (array-ref a-view i) r) (program-index))))
          (set! acc (+ acc (array-ref out-view (bit-and r (- array-len 1)))))
          (set! r (+ r 1))))
      (bit-and acc 255))))