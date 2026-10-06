;: A masked branch uses the same rank-2 destination rule.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach
    ([y : i64 0 h] [x : i64 0 w])
    (if (= x 0)
      (set! (array-ref out x) y)
      unit)))

(define (main) : i64
  0)