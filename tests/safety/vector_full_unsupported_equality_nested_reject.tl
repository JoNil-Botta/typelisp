;: Full vectors reject aggregates whose fields do not support equality.
(import stdlib.vector)

(defstruct VectorFullUnsupportedEqHolder
  (ptr (MutPtr i64)))

(import (vector.vector VectorFullUnsupportedEqHolder) as holders)

(define (main) : unit
  (let
    [values : holders.Vec (holders.new)]
    (begin
      (holders.pop (&mut values))
      unit)))