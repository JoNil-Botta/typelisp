;: SPEC SPMD contract: scan bodies cannot mutate shared outer bindings.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

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