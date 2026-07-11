;: A live generated Vec mutable iterator prevents removing an element.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
    (begin
      (vec.pop (&mut values))
      (vec.next-mut (&mut iter))
      unit)))