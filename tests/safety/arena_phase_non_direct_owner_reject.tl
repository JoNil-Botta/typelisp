(import "stdlib/arena.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-current)]
    [phase : ArenaPhase (arena-phase owner)]
    (begin
      (arena-rewind-safe! phase)
      42)))