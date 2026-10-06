;: Early exits are not part of the SPMD surface in either rank.
(define (main) : i64
  (begin
    (foreach ([y : i64 0 2] [x : i64 0 3]) (return 1))
    0))