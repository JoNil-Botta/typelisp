;: Rank-2 bounds nested in a gang must be uniform.
(define (main) : i64
  (begin
    (foreach ([i : i64 0 3]) (foreach ([y : i64 0 i] [x : i64 0 3]) unit))
    0))