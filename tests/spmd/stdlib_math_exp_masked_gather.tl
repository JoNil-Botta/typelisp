(import stdlib.math)

(define (main) : i64
  (let
    [input : (Array f64 4) (array 1.0 2.0 3.0 4.0)]
    [out : (Array f64 4) (make-array f64 4)]
    (foreach
      ([i : i64 0 4])
      (set! (array-ref out i) (math.f64-exp (array-ref input i))))
    (cast (array-ref out 0) : i64)))