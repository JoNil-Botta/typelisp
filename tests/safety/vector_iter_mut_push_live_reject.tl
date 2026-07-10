;: A live generated Vec mutable iterator prevents growth or append.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
    (vec.push (&mut values) 7)))