;: A rank-2 foreach body is unit, like a rank-1 body.
(define (main) : i64
  (begin
    (foreach ([y : i64 0 2] [x : i64 0 3]) 7)
    0))