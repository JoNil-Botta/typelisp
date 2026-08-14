;: A generated mutable Vec iterator item retains the vector borrow after the
;: iterator local has gone out of scope.
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
        [first : (vec.IterMutNext values)
          (let
            [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
            (vec.next-mut (&mut iter)))]
        (begin
          (vec.push! values 9)
          (consume first))))))