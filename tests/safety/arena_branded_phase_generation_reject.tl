(import stdlib.arena)

(defstruct StoredPhase
  (:lifetimes owner generation)
  (phase (arena.ArenaPhase owner generation)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [state (StoredPhase phase)]
    (arena.rewind-safe! state.phase)
    (set! state.phase (arena.phase owner))
    42))