;: Non-lexical lifetimes through the liveness of the reference's holder: a
;: reference joined from two branches inside a loop carries only the loan of
;: the branch that assigned it. After its last use in the iteration the
;: borrowed element is written, although the next iteration may take the
;: other branch and use the joined reference again.
(define (bump [value : (& value i64)]) : i64
  (+ (deref value) 1))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [other : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [i : i64 0]
    [total : i64 0]
    (set! (array-ref other 0) 17)
    (while (< i 4)
      (set! (array-ref values i) i)
      (set!
        (array-ref values i)
        (bump
          (if (= (% i 2) 0)
            (& (array-ref other 0))
            (& (array-ref values i)))))
      (set! total (+ total (array-ref values i)))
      (set! i (+ i 1)))
    total))