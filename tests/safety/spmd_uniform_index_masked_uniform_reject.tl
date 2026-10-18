(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 4)
      (set! (array-ref out 0) 42)
      unit)))