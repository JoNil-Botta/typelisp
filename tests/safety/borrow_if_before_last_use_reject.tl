(define (take [n : (& n i64)]) : i64
  1)

(define (main [n : i64] [flag : bool]) : i64
  (let
    [borrowed : (& n i64) (& n)]
    (begin
      (if flag
        (set! n 2)
        unit)
      (take borrowed))))