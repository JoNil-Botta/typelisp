;; Public generic mul-add accepts only f64 and f32 expressions.
(import stdlib.math)

(define (main) : i64
  (math.mul-add (cast 2 : i64) (cast 3 : i64) (cast 4 : i64)))