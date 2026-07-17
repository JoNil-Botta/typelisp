;: A live generated Vec shared iterator prevents append/growth through its source.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    [iter : (vec.Iter values) (vec.iterator (& values))]
    (vec.push! values 7)))