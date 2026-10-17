(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [first (arena.phase owner)]
    [second (arena.phase owner)]
    (arena.rewind-safe! second)
    42))