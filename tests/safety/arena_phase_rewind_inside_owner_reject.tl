(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    [phase : ArenaPhase (arena-phase owner)]
    (begin
      (in-arena owner (arena-rewind-safe! phase))
      42)))