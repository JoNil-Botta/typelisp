;: Ownership still applies: the body runs once per active lane, so it cannot move an owner declared outside it.
(define (consume [xs : (__tl_dyn-array i64)]) : i64
  (array-length xs))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active [lane : i64] (set! total (consume items))))
      total)))