;# benchmarks/spmd_shuffle/bench.tl - checked SPMD shuffle benchmark (#5351).
;#
;# Equivalent to baseline.c. Each pass maps `out[i] = a[i] + r`; the TypeLisp
;# spelling routes that value through an identity intra-gang `spmd-shuffle`.
;# Identity keeps scalar, AVX2, AVX-512, and C observables identical while still
;# requiring ordered selector validation and a native permutation in SIMD modes.
;# The selected output element is folded into an accumulator after every pass.
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
        (array-set! a i (+ (* i 3) 1))
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
          (foreach
            ([i : i64 0 array-len])
            (array-set!
              out
              i
              (spmd-shuffle (+ (array-ref a i) r) (program-index))))
          (set! acc (+ acc (array-ref out (bit-and r (- array-len 1)))))
          (set! r (+ r 1))))
      (bit-and acc 255))))