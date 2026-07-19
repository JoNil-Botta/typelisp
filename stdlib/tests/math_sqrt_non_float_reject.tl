;; Public generic sqrt accepts only f64 and f32 expressions.
(import stdlib.math)

(define (main) : i64
  (math.sqrt (cast 4 : i64)))