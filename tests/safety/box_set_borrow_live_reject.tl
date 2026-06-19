(define (take [_value : (& cell i64)]) : i64
  1)

(define (main) : i64
  (let
    [cell : (Box i64) (box 1)]
    [borrowed : (& cell i64) (& (box-get cell))]
    (begin
      (set! (box-get cell) 2)
      (take borrowed))))