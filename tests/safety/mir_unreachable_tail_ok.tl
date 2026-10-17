;: Code after a diverging form never runs: it is typed but carries no ownership
;: effect (as in Rust), so a use after a move there is not an error.
(define (consume [items : (__tl_dyn-array i64)]) : i64
  (array-length items))

(define (early [items : (__tl_dyn-array i64)] [flag : bool]) : i64
  (begin
    (consume items)
    (return 7)
    (consume items)))

(define (main) : i64
  (early (__tl_make-array i64 1) true))