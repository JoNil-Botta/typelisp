(import stdlib.arena)

(define (rewind [phase : (arena.ArenaPhase owner generation)]) : unit
  (arena.rewind-safe! phase))

(define (main) : i64
  42)