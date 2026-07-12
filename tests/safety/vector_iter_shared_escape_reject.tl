;: Generated shared iterator state cannot outlive its vector owner.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (bad [outer : vec.Vec]) : (vec.Iter outer)
  (let
    [inner : vec.Vec (vec.new)]
    (vec.iterator (& inner))))

(define (main) : unit
  unit)