;: SPEC SPMD contract: masked-if branches reject varying calls.
(define (bump [x : i64]) : i64
  (+ x 1))

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (array-set! out i (bump (array-ref xs i)))
      (array-set! out i 0))))