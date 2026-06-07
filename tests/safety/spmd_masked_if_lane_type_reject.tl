;: SPEC SPMD contract: masked-if branches reject unsupported lane result types.
(define (main [xs : (Array String)] [out : (Array String)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> i 0)
      (array-set! out i (array-ref xs i))
      (array-set! out i ""))))