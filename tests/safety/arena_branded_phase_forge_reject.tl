(import stdlib.arena)

(define (forge
  [witness : (arena.ArenaPhase owner generation)]
  [mark : arena.ArenaMark]) : (arena.ArenaPhase owner generation)
  (arena.ArenaPhase witness.arena mark))

(define (main) : i64
  42)