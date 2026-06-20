;: SPEC borrow contract: match-arm-local borrows end inside their arm and do
;: not block owner mutation after the match join.
(define (take [n : (& n i64)]) : i64
  1)

(defenum Flag
  (On)
  (Off))

(define (main [n : i64] [flag : Flag]) : i64
  (begin
    (match flag
      [On
        (let
          [borrowed : (& n i64) (& n)]
          (begin
            (take borrowed)
            unit))]
      [Off unit])
    (set! n 2)
    n))