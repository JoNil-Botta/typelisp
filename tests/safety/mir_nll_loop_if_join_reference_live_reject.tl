;: The joined reference is used after the write, so the loan of the branch that
;: borrowed the written element is still live there.
(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [other : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [i : i64 0]
    [total : i64 0]
    (set! (array-ref other 0) 9)
    (while (< i 4)
      (let
        [joined
          (if (= (% i 2) 0)
            (& (array-ref other 0))
            (& (array-ref values i)))]
        (set! (array-ref values i) i)
        (set! total (+ total (deref joined))))
      (set! i (+ i 1)))
    total))