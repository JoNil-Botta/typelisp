;: A live generated Vec mutable iterator prevents replacing an element.
;: The iterator is used after the mutation, so it is live there.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
    (begin
      (vec.set! values 0 7)
      (vec.next-mut (&mut iter))
      unit)))