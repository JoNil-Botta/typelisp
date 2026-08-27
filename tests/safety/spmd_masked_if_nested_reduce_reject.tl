;: SPEC SPMD contract: masked-if branches reject nested spmd-reduce.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(define (main
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (let
        [total : i64 (spmd-reduce sum ([j : i64 0 n]) 0 (array-ref xs j))]
        (set! (array-ref out i) total))
      (set! (array-ref out i) 0))))