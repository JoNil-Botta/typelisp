;; A lambda created outside `with-arena` and called inside it returns a borrow
;; of its capture (#9297).
(define (main) : i64
  (let
    [n : i64 42]
    ; Must fail: `(& n)` borrows the lambda's copy of `n`.
    [g
      (lambda () : (& n i64)
        (& n))]
    [r : (& n i64) (with-arena tmp (g))]
    [junk : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    (set! (array-ref junk 0) 7)
    (deref r)))