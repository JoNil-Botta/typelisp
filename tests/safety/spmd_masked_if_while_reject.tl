;: SPEC SPMD contract: masked-if branches reject varying while loops.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (while (> (array-ref xs i) 1)
        (array-set! out i 1))
      (array-set! out i 0))))