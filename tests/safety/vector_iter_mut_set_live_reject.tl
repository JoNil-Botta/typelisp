;: A live generated Vec mutable iterator prevents replacing an element.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
    (vec.set (&mut values) 0 7)))