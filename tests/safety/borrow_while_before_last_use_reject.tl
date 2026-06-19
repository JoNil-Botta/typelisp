(define (take [n : (& n i64)]) : i64
  1)

(define (main [n : i64]) : i64
  (let
    [borrowed : (& n i64) (& n)]
    (begin
      (while (< n 3)
        (set! n 2))
      (take borrowed))))