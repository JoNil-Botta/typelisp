;: A very large fixed-array take index traps before addressing the slot.
(define (main) : i64
  (let
    [items : (Array i64 1) (array 7)]
    (array-take! items 9223372036854775807)))