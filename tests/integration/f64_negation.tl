(define (negf [x : f64]) : f64
  (neg x))

(define (main) : i64
  (if (< (negf 3.5) 0.0)
    (if (< 0.0 (negf (negf 3.5)))
      42
      2)
    1))