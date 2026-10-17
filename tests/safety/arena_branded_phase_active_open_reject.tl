(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    (in-arena owner (arena.phase owner))
    42))