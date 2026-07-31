;; Scalar lane identity semantics for foreach and spmd-reduce (#2761).
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (foreach-checksum [n : i64]) : i64
  (let
    [out : i64v.Vec (i64z.make n)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (let
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([lane : i64 0 n])
          (array-set! out-slots lane (+ (* (program-count) 10) (program-index)))))
      (while (< i n)
        (begin
          (set! acc (+ acc (i64v.get (& out) i 0)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-checksum [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (program-count) (program-index))))

(define (main) : i64
  (if (and (= (foreach-checksum 5) 50) (= (reduce-checksum 7) 7))
    42
    1))