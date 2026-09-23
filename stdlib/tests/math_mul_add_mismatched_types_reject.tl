;; Public generic mul-add requires all three operands to share one float type.
(import stdlib.math)

(define (main) : i64
  (let
    [a : f64 2.0]
    [b : f64 3.0]
    [c : f32 4.0]
    (if (= (math.mul-add a b c) 10.0)
      42
      1)))