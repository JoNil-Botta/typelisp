;: A generated Vec mutable iterator cannot advance while its prior result is live.
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
          (vec.next-mut (&mut iter))
          (consume first))))))