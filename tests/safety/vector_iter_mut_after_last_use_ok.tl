;: A generated Vec mutable iterator releases its source after the state/item's
;: last use, so an ordinary mutation can follow.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (consume [value : (vec.IterMutNext source)]) : unit
  (match value
    [(vec.IterMutNext.Done) unit]
    [(vec.IterMutNext.Item _) unit]))

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    (begin
      (vec.push (&mut values) 7)
      (let
        [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
        [first : (vec.IterMutNext values) (vec.next-mut (&mut iter))]
        (begin
          (consume first)
          (vec.next-mut (&mut iter))))
      (vec.push (&mut values) 9))))