(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out 0)
      (if (< i 4)
        42
        43))))