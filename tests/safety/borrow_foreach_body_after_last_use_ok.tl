;: SPEC borrow contract: foreach body-local immutable borrows can end at
;: their last in-iteration use before a later non-conflicting body mutation.
(define (take [n : (& n i64)]) : i64
  1)

(define (main [n : i64] [out : (Array i64)] [limit : i64]) : unit
  (foreach
    ([i : i64 0 limit])
    (let
      [borrowed : (& n i64) (& n)]
      (begin
        (take borrowed)
        (array-set! out i n)))))