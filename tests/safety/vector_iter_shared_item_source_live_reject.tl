;: A generated shared Vec item retains the vector borrow after the iterator
;: local has gone out of scope.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (consume [value : (vec.IterNext source)]) : unit
  (match value
    [(vec.IterNext.Done) unit]
    [(vec.IterNext.Item _) unit]))

(define (main) : unit
  (let
    [values : vec.Vec (vec.new)]
    (begin
      (vec.push! values 7)
      (let
        [first : (vec.IterNext values)
          (let
            [iter : (vec.Iter values) (vec.iterator (& values))]
            (vec.next (&mut iter)))]
        (begin
          (vec.push! values 9)
          (consume first))))))