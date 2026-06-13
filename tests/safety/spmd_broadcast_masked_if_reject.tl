;: SPEC SPMD contract: masked branches do not support spmd-broadcast yet.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (array-set! out i (spmd-broadcast (array-ref xs i) 0))
      (array-set! out i (array-ref xs i)))))