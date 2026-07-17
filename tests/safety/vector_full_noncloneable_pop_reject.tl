;: Full vectors preserve the clear clone diagnostic for noncloneable elements.
(import stdlib.vector)

(defstruct VectorFullRawHolder
  (ptr (MutPtr i64)))

(import (vector.vector VectorFullRawHolder) as holders)

(define (main) : unit
  (let
    [values : holders.Vec (holders.new)]
    (begin
      (holders.pop! values)
      unit)))