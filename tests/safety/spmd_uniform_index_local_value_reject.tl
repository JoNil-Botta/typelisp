(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [value : i64 0]
      (begin
        (if true
          (set! value i)
          unit)
        (set! (array-ref out 0) value)))))