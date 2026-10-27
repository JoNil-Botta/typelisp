(define (make-fixed-array [depth : i64]) : (Array i64 3)
  (if (> depth 0)
    (make-fixed-array (- depth 1))
    (array 10 11 21)))

(define (main) : i64
  (let
    [value : (Array i64 3) (make-fixed-array 2)]
    (+ (array-ref value 0) (array-ref value 1) (array-ref value 2))))