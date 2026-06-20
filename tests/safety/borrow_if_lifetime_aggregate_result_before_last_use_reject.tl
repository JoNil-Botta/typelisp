;: SPEC borrow contract: lifetime-parameterized aggregate results keep their
;: owner borrow live across if joins until the aggregate's last use.
(defstruct RefBox
  (:lifetimes owner)
  (value (& owner i64)))

(define (read-box [box : (RefBox owner)]) : i64
  1)

(define (main [n : i64] [flag : bool]) : i64
  (let
    [box : (RefBox n)
      (if flag
        (RefBox n)
        (RefBox n))]
    (begin
      (set! n 2)
      (read-box box))))