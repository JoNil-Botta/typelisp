(define (main) : i64
  (let
    [cell : (Box i64) (box 42)]
    (match (& cell)
      [(box value) value]
      [_ 0])))