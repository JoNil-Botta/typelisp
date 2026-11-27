(import stdlib.math)

(define (zero) : i64
  (cast (math.f64-sqrt 0.0) : i64))

(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    (foreach
      ([i : i64 0 8])
      (set! (array-ref out i) (+ (program-count) (zero))))
    (array-ref out 7)))