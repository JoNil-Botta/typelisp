;: SPEC SPMD contract: masked-if branches reject nested spmd-reduce.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (let
        [total : i64 (spmd-reduce sum ([j : i64 0 n]) 0 (array-ref xs j))]
        (array-set! out i total))
      (array-set! out i 0))))