(define (main) : i64
  (let
    [cell : (Box i64) (box 1)]
    (let
      [borrowed : (& cell i64) (& (box-get cell))]
      (begin
        (set! (box-get cell) 2)
        0))))