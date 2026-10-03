;: Rank-2 coordinates are read-only: assigning one would change the domain.
(define (main) : i64
  (begin
    (foreach ([y : i64 0 2] [x : i64 0 3]) (set! x 3))
    0))