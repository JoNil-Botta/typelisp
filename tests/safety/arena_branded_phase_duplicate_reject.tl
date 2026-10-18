(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [_alias phase]
    (arena.rewind-safe! phase)
    42))