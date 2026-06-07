;: SPEC SPMD contract: masked-if branches reject allocations that can escape.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (let
        [tmp : (Array i64) (make-array i64 1)]
        (array-set! out i (array-ref xs i)))
      (array-set! out i 0))))