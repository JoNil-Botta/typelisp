;: Every bound is evaluated before the domain runs, outside both coordinates.
(define (main) : i64
  (begin
    (foreach ([y : i64 0 2] [x : i64 0 y]) unit)
    0))