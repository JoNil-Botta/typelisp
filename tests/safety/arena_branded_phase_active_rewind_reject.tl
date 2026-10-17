(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    (in-arena phase (arena.rewind-safe! phase))
    42))