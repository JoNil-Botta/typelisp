;: SPEC borrow contract: a borrow escaping through an if result remains live
;: until the bound reference value's last use.
(define (take [n : (& n i64)]) : i64
  1)

(define (main [n : i64] [flag : bool]) : i64
  (let
    [borrowed : (& n i64)
      (if flag
        (& n)
        (& n))]
    (begin
      (set! n 2)
      (take borrowed))))