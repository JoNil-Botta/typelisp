(import stdlib.arena)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.current)]
    [phase : arena.ArenaPhase (arena.phase owner)]
    (begin
      (arena.rewind-safe! phase)
      42)))