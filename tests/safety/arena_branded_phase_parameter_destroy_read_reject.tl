(import stdlib.arena)
(import stdlib.string)

(define (destroy-and-read
  [owner : (arena.Arena r) (:invalidate r)]
  [_phase : (arena.ArenaPhase r g)]
  [text : (in g String)]) : i64
  (arena.destroy-safe! owner)
  (string.string-length text))

(define (main) : i64
  42)