(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase owner)]
    [text : String (in-arena owner (string.append "stale" "-text"))]
    (begin
      (arena.rewind-safe! phase)
      (length text))))