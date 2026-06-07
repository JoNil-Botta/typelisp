;: SPEC SPMD contract: masked-if branches reject nested spmd-reduce.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (let
        [total : i64 (spmd-reduce sum ([j : i64 0 n]) 0 (array-ref xs j))]
        (array-set! out i total))
      (array-set! out i 0))))