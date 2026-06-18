;: SPEC SPMD contract: scan bodies cannot mutate shared outer bindings.
(define (bad [xs : (Array i64)] [n : i64]) : i64
  (let
    [total : i64 0]
    (begin
      (spmd-scan
        sum
        ([i : i64 0 n] [prefix : i64 0])
        (array-ref xs i)
        (set! total prefix))
      total)))
