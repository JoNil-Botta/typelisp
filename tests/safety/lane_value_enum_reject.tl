;: lane-value yields a scalar lane type.
(defenum Color
  (Red)
  (Green))

(define (main) : i64
  (let
    [colors : (Array Color 4)
      (array Color.Red Color.Green Color.Red Color.Green)]
    [reds : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active
          [lane : i64]
          (match (lane-value (array-ref colors i))
            [(Color.Red) (set! reds (+ reds 1))]
            [(Color.Green) unit])))
      reds)))