;: SPEC SPMD contract: masked-if branches reject varying match forms.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (match (> (array-ref xs i) 1)
        [true (array-set! out i 1)]
        [false (array-set! out i 2)])
      (array-set! out i 0))))