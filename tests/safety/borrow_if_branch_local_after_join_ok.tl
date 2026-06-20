;: SPEC borrow contract: branch-local immutable borrows end at their last
;: in-branch use and do not block owner mutation after the join.
(define (take [n : (& n i64)]) : i64
  1)

(define (main [n : i64] [flag : bool]) : i64
  (begin
    (if flag
      (let
        [borrowed : (& n i64) (& n)]
        (begin
          (take borrowed)
          unit))
      unit)
    (set! n 2)
    n))