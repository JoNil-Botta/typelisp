;: A returned generated Vec shared item prevents moving its source after the
;: iterator local has gone out of scope.
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
        [first : (vec.IterNext values)
          (let
            [iter : (vec.Iter values) (vec.iterator (& values))]
            (vec.next (&mut iter)))]
        [moved : vec.Vec values]
        (begin
          (consume first)
          (vec.len (& moved)))))))