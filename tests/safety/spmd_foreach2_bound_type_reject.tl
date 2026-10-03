;: Rank-2 bounds are checked i64 values.
(define (main [n : i32]) : i64
  (begin
    (foreach ([y : i64 0 2] [x : i64 0 n]) unit)
    0))