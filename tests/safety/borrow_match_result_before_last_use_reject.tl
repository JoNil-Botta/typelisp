;: SPEC borrow contract: a borrow escaping through a match result remains live
;: until the bound reference value's last use.
(define (take [n : (& n i64)]) : i64
  1)

(defenum Flag
  (On)
  (Off))

(define (main [n : i64] [flag : Flag]) : i64
  (let
    [borrowed : (& n i64)
      (match flag
        [On (& n)]
        [Off (& n)])]
    (begin
      (set! n 2)
      (take borrowed))))