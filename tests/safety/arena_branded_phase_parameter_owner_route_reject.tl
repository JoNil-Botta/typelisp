(import stdlib.arena)
(import stdlib.string)

(define (allocate [owner : (arena.Arena r)] [_phase : (arena.ArenaPhase r g)]) : (in
    r
    String)
  (in-arena owner (string.append "owner" "-route")))

(define (main) : i64
  42)