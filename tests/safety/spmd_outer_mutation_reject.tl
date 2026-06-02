;: SPEC safe-code contract: SPMD bodies cannot mutate shared outer bindings.
(define (main [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n]) (set! sum (+ sum (array-ref xs i))))
      sum)))