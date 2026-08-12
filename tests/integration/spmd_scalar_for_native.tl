;; Scalar SPMD uses the same fixed-array `for` ownership modes as ordinary
;; scalar code. The array values stay uniform; the foreach lane remains varying.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (fill
  [slice-items : (& slice (Slice i64))]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [out-slots (i64v.slots-mut out)]
    (foreach
      ([lane : i64 0 n])
      (let
        [items : (Array i64 2) (array 1 2)]
        [shared-items : (Array i64 2) (array 4 5)]
        [mut-items : (Array i64 2) (array 1 2)]
        [total : i64 0]
        (begin
          (for [item items] (set! total (+ total item)))
          (for [item (& shared-items)] (set! total (+ total (deref item))))
          (for
            [item (&mut mut-items)]
            (set! (deref item) (+ (deref item) 1))
            (set! total (+ total (deref item))))
          (for [item slice-items] (set! total (+ total (deref item))))
          (set! (array-ref out-slots lane) (+ total lane)))))))

(define (main) : i64
  (let
    [out : i64v.Vec (i64z.make 4)]
    [slice-items : (Array i64 3) (array 6 7 100)]
    (begin
      (fill (slice-view (& slice-items) 0 2) (&mut out) 4)
      (let
        [out-slots (i64v.slots (& out))]
        (if (and
          (= (array-ref out-slots 0) 30)
          (= (array-ref out-slots 1) 31)
          (= (array-ref out-slots 2) 32)
          (= (array-ref out-slots 3) 33))
          42
          1)))))