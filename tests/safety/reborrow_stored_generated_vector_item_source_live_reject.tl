;: A generated mutable Vec iterator item retains the vector borrow through
;: the iterator while it is live.
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
      (vec.push! values 7)
      (let
        [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
        [first : (vec.IterMutNext iter) (vec.next-mut (&mut iter))]
        (begin
          (vec.push! values 9)
          (consume first))))))