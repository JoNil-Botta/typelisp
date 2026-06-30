(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase owner)]
    [text : String (in-arena owner (string.append "temp" "-text"))]
    (begin
      (length text)
      (arena.rewind-safe! phase)
      (arena.rewind-safe! phase)
      42)))