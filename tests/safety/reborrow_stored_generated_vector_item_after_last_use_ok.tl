;: A generated mutable Vec iterator item releases its source after the item's
;: final use, while the iterator local is still in scope.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (consume [value : (vec.IterMutNext source)]) : unit
  (match value
    [(vec.IterMutNext.Done) unit]
    [(vec.IterMutNext.Item _) unit]))

(define (main) : i64
  (let
    [values : vec.Vec (vec.new)]
    (begin
      (vec.push! values 7)
      (let
        [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
        [first : (vec.IterMutNext iter) (vec.next-mut (&mut iter))]
        (begin
          (consume first)
          (vec.push! values 9)
          (vec.len (& values)))))))