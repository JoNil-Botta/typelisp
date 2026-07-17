;: A live generated Vec shared iterator prevents replacing an element.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    [iter : (vec.Iter values) (vec.iterator (& values))]
    (vec.set! values 0 7)))