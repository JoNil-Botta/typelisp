(import stdlib.arena)

(define (open-again [owner : (arena.Arena r)] [_phase : (arena.ArenaPhase r g)]) : unit
  (let
    [_other (arena.phase owner)]
    unit))

(define (main) : i64
  42)