;: Full vectors reject aggregates whose fields do not support equality.
(import stdlib.eq)
(import stdlib.vector)

(defstruct VectorFullUnsupportedEqHolder
  (ptr (MutPtr i64)))

(eq.gen VectorFullUnsupportedEqHolder)

(import (vector.vector VectorFullUnsupportedEqHolder) as holders)

(define (main) : unit
  (let
    [values : holders.Vec (holders.new)]
    (begin
      (holders.pop! values)
      unit)))