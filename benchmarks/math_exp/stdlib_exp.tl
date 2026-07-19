;# Freestanding stdlib exponential benchmark for issue #5227.
(import stdlib.io)
(import stdlib.math)

(define (main) : i64
  (let
    [iterations : i64 (+ 2000000 (io.arg-count))]
    [i : i64 0]
    [x : f64 -0.5]
    [sum : f64 0.0]
    (begin
      (while (< i iterations)
        (begin
          (set! sum (+ sum (math.f64-exp x)))
          (set! x (+ x 0.000001))
          (if (> x 0.5)
            (set! x -0.5)
            unit)
          (set! i (+ i 1))))
      (if (> sum 0.0)
        42
        1))))