(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase owner)]
    (begin
      (in-arena owner (arena.rewind-safe! phase))
      42)))