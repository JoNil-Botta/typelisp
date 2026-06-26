;: SPEC safe-code contract: SPMD bodies cannot mutate shared outer bindings.
(import stdlib.array)

(define (main [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n]) (set! sum (+ sum (array.array-ref xs i))))
      sum)))