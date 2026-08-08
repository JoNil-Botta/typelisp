;: Fixed-array take checks the index before loading or resetting the slot.
(define (main) : i64
  (let
    [items : (Array i64 1) (array 7)]
    (array-take! items 1)))