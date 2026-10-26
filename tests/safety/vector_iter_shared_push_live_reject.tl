;: A live generated Vec shared iterator prevents append/growth through its source.
;: The iterator is used after the mutation, so it is live there.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    [iter : (vec.Iter values) (vec.iterator (& values))]
    (begin
      (vec.push! values 7)
      (vec.next (&mut iter))
      unit)))