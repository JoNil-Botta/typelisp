;: SPEC SPMD contract: masked branches still reject uniform while loops.
(import stdlib.array)

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array.array-ref xs i) 0)
      (while (> n 0)
        (array.array-set! out i 1))
      (array.array-set! out i 0))))