;# Straight degree-12 Taylor baseline for the stdlib exponential benchmark.
;# Inputs stay in [-0.5, 0.5], where this deliberately simple baseline is
;# useful for comparing implementation cost without range reduction.
(import stdlib.io)

(define (taylor-exp [x : f64]) : f64
  (let
    [sum : f64 1.0]
    [term : f64 1.0]
    [n : i64 1]
    (begin
      (while (<= n 12)
        (begin
          (set! term (/ (* term x) (cast n : f64)))
          (set! sum (+ sum term))
          (set! n (+ n 1))))
      sum)))

(define (main) : i64
  (let
    [iterations : i64 (+ 2000000 (io.arg-count))]
    [i : i64 0]
    [x : f64 -0.5]
    [sum : f64 0.0]
    (begin
      (while (< i iterations)
        (begin
          (set! sum (+ sum (taylor-exp x)))
          (set! x (+ x 0.000001))
          (if (> x 0.5)
            (set! x -0.5)
            unit)
          (set! i (+ i 1))))
      (if (> sum 0.0)
        42
        1))))