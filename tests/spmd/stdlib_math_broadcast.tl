(import stdlib.math)

(define (fill
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (+ (spmd-broadcast (array-ref xs i) 1) (cast (math.f64-sqrt 0.0) : i64)))))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    (set! (array-ref xs 5) 42)
    (fill (& xs) (&mut out) 8)
    (array-ref out 7)))