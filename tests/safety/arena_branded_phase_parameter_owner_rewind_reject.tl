(import stdlib.arena)

(define (rewind [owner : (arena.Arena owner)]) : unit
  (let
    [phase (arena.phase owner)]
    (arena.rewind-safe! phase)))

(define (main) : i64
  42)