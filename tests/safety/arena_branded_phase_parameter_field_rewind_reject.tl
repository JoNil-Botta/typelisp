(import stdlib.arena)

(defstruct StoredPhase
  (:lifetimes owner generation)
  (phase (arena.ArenaPhase owner generation)))

(define (rewind [state : (StoredPhase owner generation)]) : unit
  (arena.rewind-safe! state.phase))

(define (main) : i64
  42)