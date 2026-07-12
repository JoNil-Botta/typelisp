;: A generated mutable Vec iterator item releases its source after the item's
;: final use, even when the iterator local has gone out of scope.
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
      (vec.push (&mut values) 7)
      (let
        [first : (vec.IterMutNext values)
          (let
            [iter : (vec.IterMut values) (vec.iterator-mut (&mut values))]
            (vec.next-mut (&mut iter)))]
        (begin
          (consume first)
          (vec.push (&mut values) 9)
          (vec.len (& values)))))))