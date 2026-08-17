(import stdlib.arena)

(defstruct ArenaPair
  (:lifetimes owner)
  (left (arena.Arena owner))
  (right (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [_pair (ArenaPair owner owner)]
    0))