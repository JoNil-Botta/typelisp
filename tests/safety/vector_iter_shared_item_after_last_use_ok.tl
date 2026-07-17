;: A returned generated Vec shared item releases its source after its final use,
;: even when the iterator local has already left scope.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (consume [value : (vec.IterNext source)]) : unit
  (match value
    [(vec.IterNext.Done) unit]
    [(vec.IterNext.Item _) unit]))

(define (main) : i64
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
          (consume first)
          (vec.push! values 9)
          (vec.len (& values)))))))