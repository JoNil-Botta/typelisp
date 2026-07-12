;: A generated Vec shared iterator releases both its state and yielded result
;: after their final use, so an ordinary mutation can follow in the same scope.
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
      (vec.push (&mut values) 7)
      (let
        [iter : (vec.Iter values) (vec.iterator (& values))]
        [first : (vec.IterNext values) (vec.next (&mut iter))]
        (begin
          (consume first)
          (vec.push (&mut values) 9)))
      (vec.len (& values)))))