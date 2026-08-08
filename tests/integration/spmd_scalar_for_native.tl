;; Scalar SPMD uses the same fixed-array `for` ownership modes as ordinary
;; scalar code. The array values stay uniform; the foreach lane remains varying.
(define (fill
  [slice-items : (& slice (Slice i64))]
  [out : (Array i64)]
  [n : i64]) : unit
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
        (array-set! out lane (+ total lane))))))

(define (main) : i64
  (let
    [out : (Array i64) (make-array i64 4)]
    [slice-items : (Array i64 3) (array 6 7 100)]
    (begin
      (fill (slice-view (& slice-items) 0 2) out 4)
      (if (and
        (= (array-ref out 0) 30)
        (= (array-ref out 1) 31)
        (= (array-ref out 2) 32)
        (= (array-ref out 3) 33))
        42
        1))))