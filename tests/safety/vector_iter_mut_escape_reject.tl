;: Generated mutable iterator state cannot outlive its vector owner.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (bad [outer : vec.Vec]) : (vec.IterMut outer)
  (let
    [inner : vec.Vec (vec.new)]
    (vec.iterator-mut (&mut inner))))

(define (main) : unit
  unit)