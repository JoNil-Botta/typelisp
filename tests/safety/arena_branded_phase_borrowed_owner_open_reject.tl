(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [borrowed (& owner)]
    [phase (arena.phase owner)]
    [handle : i64 borrowed.handle]
    (arena.rewind-safe! phase)
    (arena.destroy-safe! owner)
    handle))